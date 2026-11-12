/// 脚本全局对象 `tsumugi`（docs/source-spec.md §4.2）的组装方式。
///
/// | 部分 | 执行位置 | 脚本侧形态 |
/// |---|---|---|
/// | [asyncHostPaths]（http / storage / cookies / ui.openWebView） | 主 isolate | 返回 Promise |
/// | [notificationPaths]（log.* / ui.toast） | 主 isolate，发出即忘 | 同步返回 `undefined` |
/// | `crypto.*`、`html.*`（[tsumugiWorkerHost]） | worker isolate | 同步 |
/// | `tsumugi.source` | 嵌入 prelude 的常量 | 冻结的对象 |
///
/// 主 isolate 一侧的实现见 `lib/sources/script/script_host.dart`。
library;

import 'dart:convert';

import '../isolate_script_runtime.dart';
import 'crypto_host.dart';
import 'html_handles.dart';

/// 在主 isolate 执行、脚本侧得到 Promise 的宿主 API。
const asyncHostPaths = {
  'http.request',
  'http.get',
  'http.getJson',
  'storage.get',
  'storage.set',
  'storage.remove',
  'cookies.get',
  'cookies.set',
  'ui.openWebView',
};

/// 发出即忘的宿主 API。
const notificationPaths = {'log.debug', 'log.info', 'log.error', 'ui.toast'};

/// [IsolateScriptRuntime.workerHost] 的标准实现。
///
/// [config] 为 `{'baseUrl': String}`（`HtmlNode.absUrl` 的默认基准地址）。
WorkerHost tsumugiWorkerHost(Object? config) {
  final baseUrl = switch (config) {
    {'baseUrl': final String b} => Uri.parse(b),
    _ => Uri.parse('about:blank'),
  };
  final handles = HtmlHandles();
  return WorkerHost({
    ...cryptoHostFunctions(),
    ...handles.functions(defaultBase: baseUrl),
  }, onCallEnd: handles.reset);
}

/// 生成 prelude：把冻结的原始宿主对象包装成公开的 `tsumugi`。
///
/// - `html.*` 原始函数只经由 `HtmlNode` 方法与 `tsumugi.html.parse` 访问，不直接暴露。
/// - [source] 为 `tsumugi.source` 的值（JSON 兼容），被深度冻结。
String buildTsumugiPrelude(Map<String, Object?> source) =>
    '''
(function (raw) {
  'use strict';
  const SOURCE = ${jsonEncode(source)};
$_preludeBody
})
''';

const _preludeBody = r'''
  const freeze = Object.freeze;
  const keys = Object.keys;
  const token = freeze({});
  const H = raw.html;

  function wrap(h) {
    return h == null ? null : new HtmlNode(token, h);
  }
  function wrapAll(hs) {
    const out = [];
    for (let i = 0; i < hs.length; i++) out.push(wrap(hs[i]));
    return out;
  }

  class HtmlNode {
    #h;
    constructor(t, h) {
      if (t !== token) {
        throw new TypeError('HtmlNode cannot be constructed; use tsumugi.html.parse');
      }
      this.#h = h;
    }
    select(css) { return wrapAll(H.select(this.#h, String(css))); }
    selectFirst(css) { return wrap(H.selectFirst(this.#h, String(css))); }
    xpath(expr) { return wrapAll(H.xpath(this.#h, String(expr))); }
    text() { return H.text(this.#h); }
    html() { return H.html(this.#h); }
    outerHtml() { return H.outerHtml(this.#h); }
    attr(name) { return H.attr(this.#h, String(name)); }
    absUrl(name) { return H.absUrl(this.#h, String(name)); }
    toJSON() { return H.outerHtml(this.#h); }
  }
  freeze(HtmlNode.prototype);
  freeze(HtmlNode);

  function deepFreeze(v) {
    if (v !== null && typeof v === 'object') {
      const ks = keys(v);
      for (let i = 0; i < ks.length; i++) deepFreeze(v[ks[i]]);
      freeze(v);
    }
    return v;
  }

  const api = { source: deepFreeze(SOURCE) };
  const passthrough = ['http', 'crypto', 'storage', 'cookies', 'ui', 'log'];
  for (let i = 0; i < passthrough.length; i++) {
    const ns = passthrough[i];
    if (raw[ns] !== undefined) api[ns] = raw[ns];
  }
  if (H !== undefined) {
    api.html = freeze({
      parse(text, baseUrl) {
        return wrap(H.parse(String(text), baseUrl == null ? null : String(baseUrl)));
      },
    });
  }
  return freeze(api);
''';
