import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/encoding/charset_sniffing.dart';

/// "中文" 的 GBK 字节。
const gbkZhongWen = [0xD6, 0xD0, 0xCE, 0xC4];

List<int> page(String head, [List<int> body = gbkZhongWen]) => [
  ...latin1.encode('<!doctype html><html><head>$head</head><body>'),
  ...body,
  ...latin1.encode('</body></html>'),
];

void main() {
  late List<String> logs;
  setUp(() => logs = []);

  CharsetDetection detect(
    List<int> bytes, {
    String? contentType,
    String? override,
  }) => detectCharset(
    bytes,
    contentType: contentType,
    override: override,
    log: logs.add,
  );

  group('识别顺序', () {
    test('显式指定 > BOM > Content-Type > <meta> > utf-8', () {
      final bom = [0xEF, 0xBB, 0xBF, ...page('<meta charset="big5">')];
      expect(
        detect(bom, contentType: 'text/html; charset=gbk', override: 'euc-kr'),
        _is('euc-kr', CharsetSource.override),
      );
      expect(
        detect(bom, contentType: 'text/html; charset=gbk'),
        _is('utf-8', CharsetSource.bom),
      );
      final noBom = page('<meta charset="big5">');
      expect(
        detect(noBom, contentType: 'text/html; charset=gbk'),
        _is('gb18030', CharsetSource.header),
      );
      expect(
        detect(noBom, contentType: 'text/html'),
        _is('big5', CharsetSource.meta),
      );
      expect(
        detect(page(''), contentType: 'text/html'),
        _is('utf-8', CharsetSource.fallback),
      );
      expect(logs, isEmpty);
    });

    test('UTF-16 BOM', () {
      expect(
        detect([0xFF, 0xFE, 0x41, 0x00]),
        _is('utf-16le', CharsetSource.bom),
      );
      expect(
        detect([0xFE, 0xFF, 0x00, 0x41]),
        _is('utf-16be', CharsetSource.bom),
      );
    });

    test('Content-Type 的 charset：引号、大小写、参数顺序', () {
      for (final ct in [
        'text/html; charset="GB2312"',
        "text/html;charset='gbk'",
        'TEXT/HTML; boundary=x; Charset = GBK',
      ]) {
        expect(
          detect(page(''), contentType: ct).encoding,
          'gb18030',
          reason: ct,
        );
      }
    });

    test('未知 charset 跳过并记录日志，继续下一步', () {
      expect(
        detect(
          page('<meta charset="gbk">'),
          contentType: 'text/html; charset=x-nope',
        ),
        _is('gb18030', CharsetSource.meta),
      );
      expect(logs.single, contains('x-nope'));
      logs.clear();
      expect(
        detect(page('<meta charset="foo"><meta charset="big5">')),
        _is('big5', CharsetSource.meta),
      );
      expect(logs.single, contains('foo'));
      logs.clear();
      expect(
        detect(page(''), contentType: 'text/plain; charset=euc-jp'),
        _is('utf-8', CharsetSource.fallback),
      );
      expect(logs.single, contains('euc-jp'));
      logs.clear();
      expect(
        detect(page(''), override: 'nope'),
        _is('utf-8', CharsetSource.fallback),
      );
      expect(logs.single, contains('nope'));
    });
  });

  group('<meta> 预扫描', () {
    test('http-equiv 形式（属性顺序、大小写、单引号）', () {
      for (final head in [
        '<meta http-equiv="Content-Type" content="text/html; charset=gb2312">',
        "<META CONTENT='text/html; charset=GBK' HTTP-EQUIV='content-type' />",
        '<meta http-equiv=content-type content="text/html;charset=gbk">',
      ]) {
        expect(detect(page(head)).encoding, 'gb18030', reason: head);
      }
    });

    test('没有 http-equiv 的 content 不算', () {
      expect(
        detect(page('<meta name="x" content="charset=gbk">')).source,
        CharsetSource.fallback,
      );
    });

    test('属性值中的 > 与 <meta 不影响扫描（按引号解析）', () {
      expect(
        detect(page('<meta name="description" content="a > b" charset="gbk">'))
            .encoding,
        'gb18030',
      );
      expect(
        detect(
          page(
            '<link title="<meta charset=big5>" rel="alternate">'
            '<meta charset="gbk">',
          ),
        ).encoding,
        'gb18030',
      );
      expect(
        detect(page("<script src='x>y'></script><meta charset=big5>")).encoding,
        'big5',
      );
    });

    test('<!doctype>、<?…?> 与结束标签被跳过', () {
      expect(
        detect(page('<?php "<meta charset=big5>" ?></title><meta charset=gbk>'))
            .encoding,
        'gb18030',
      );
    });

    test('注释中的 meta 被忽略', () {
      expect(
        detect(page('<!-- <meta charset="big5"> --><meta charset="gbk">'))
            .encoding,
        'gb18030',
      );
    });

    test('只看前 4 KB', () {
      final late = [
        ...latin1.encode(
          '<html><head><title>${'x' * metaPrescanBytes}</title>',
        ),
        ...latin1.encode('<meta charset="gbk">'),
      ];
      expect(detect(late).source, CharsetSource.fallback);
    });

    test('<meta> 声明 utf-16 时按 utf-8', () {
      expect(
        detect(page('<meta charset="utf-16">')),
        _is('utf-8', CharsetSource.meta),
      );
    });

    test('XML 声明', () {
      final xml = latin1.encode('<?xml version="1.0" encoding="GBK"?><r/>');
      expect(
        detect(xml, contentType: 'application/xml'),
        _is('gb18030', CharsetSource.meta),
      );
    });

    test('非 HTML / XML 的 Content-Type 不做预扫描', () {
      expect(
        detect(page('<meta charset="gbk">'), contentType: 'application/json'),
        _is('utf-8', CharsetSource.fallback),
      );
      expect(
        detect(page('<meta charset="gbk">'), contentType: 'text/plain'),
        _is('utf-8', CharsetSource.fallback),
      );
    });
  });

  test('decodeText 识别后解码', () {
    expect(
      decodeText(page('<meta charset="gb2312">')),
      contains('<body>中文</body>'),
    );
    expect(
      decodeText(gbkZhongWen, contentType: 'text/plain; charset=gbk'),
      '中文',
    );
  });
}

Matcher _is(String encoding, CharsetSource source) => isA<CharsetDetection>()
    .having((d) => d.encoding, 'encoding', encoding)
    .having((d) => d.source, 'source', source);
