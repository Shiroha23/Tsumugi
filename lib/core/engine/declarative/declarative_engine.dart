import '../../network/host_policy.dart';
import '../expression/expression_engine.dart';
import 'fetcher.dart';
import 'rules.dart';
import 'template.dart';

/// 声明式引擎的失败。[code] 取自 source-spec §6。
class DeclarativeException implements Exception {
  const DeclarativeException(this.code, [this.message, this.status]);

  static const network = 'E_NETWORK';
  static const http = 'E_HTTP';
  static const hostNotAllowed = 'E_HOST_NOT_ALLOWED';
  static const unsupported = 'E_UNSUPPORTED';

  final String code;
  final String? message;
  final int? status;

  @override
  String toString() =>
      'DeclarativeException($code${status != null ? ' $status' : ''}'
      '${message != null ? ': $message' : ''})';
}

/// 声明式规则执行器（source-spec §3）。
///
/// 产出与 source-spec §2 同构的 JSON 值（`Map<String, Object?>`），由
/// `lib/sources/` 中的适配层转换为模型类型——`core` 不依赖 `sources`。
///
/// - 请求 URL 先做模板替换（§3.2），再基于 `baseUrl` 解析；不在白名单内的主机
///   直接拒绝（`E_HOST_NOT_ALLOWED`），网络层还会再检查一次。
/// - 结果中的 URL 字段（`cover`、图片、流）同样基于 `baseUrl` 解析为绝对地址；
///   `id` 类字段（条目 id、unit id、`nextPageId`）保持原样，留给下一次请求解析。
/// - 源的默认 headers 会附在封面、图片和流上（§5），供加载器 / 播放器使用。
class DeclarativeEngine {
  DeclarativeEngine({
    required this.baseUrl,
    required this.mediaType,
    required this.rules,
    required this.fetcher,
    ExpressionEngine? expressions,
    this.headers = const {},
    this.settings = const {},
    HostPolicy? hostPolicy,
    DebugLog? log,
  }) : _log = log ?? _noLog,
       _hosts = hostPolicy ?? HostPolicy(baseUrl: baseUrl),
       expressions = expressions ?? ExpressionEngine(log: log);

  /// 清单中的 `baseUrl`。
  final Uri baseUrl;

  /// `comic` / `novel` / `video` / `music`，决定 `content` 的形状。
  final String mediaType;
  final DeclarativeRules rules;
  final Fetcher fetcher;
  final ExpressionEngine expressions;

  /// 源的默认请求 headers。
  final Map<String, String> headers;

  /// 用户设置（已合并默认值），对应模板变量 `{{setting.<key>}}`。
  final Map<String, String> settings;

  final HostPolicy _hosts;
  final DebugLog _log;

  static const _searchFields = {'id', 'title', 'cover', 'subtitle', 'tags'};
  static const _detailFields = {
    'title',
    'cover',
    'author',
    'description',
    'tags',
    'status',
    'updatedAt',
  };
  static const _unitFields = {'id', 'title', 'updatedAt'};
  static const _contentFields = {
    'comic': {'images'},
    'novel': {'text', 'nextPageId'},
    'video': {'streams'},
    'music': {'streams', 'lyrics'},
  };

  Future<Map<String, Object?>> search(String keyword, int page) {
    final rule = rules.search ?? _unsupported('search');
    return _list(rule, {
      'keyword': Uri.encodeComponent(keyword),
      'page': '$page',
    });
  }

  /// 发现页分类；分类 id 为其在 `rules.explore` 中的下标。
  List<Map<String, Object?>> explore() {
    if (rules.explore.isEmpty) _unsupported('explore');
    return [
      for (final (i, e) in rules.explore.indexed) {'id': '$i', 'name': e.name},
    ];
  }

  Future<Map<String, Object?>> exploreList(String categoryId, int page) {
    final i = int.tryParse(categoryId);
    if (i == null || i < 0 || i >= rules.explore.length) {
      throw DeclarativeException(
        DeclarativeException.unsupported,
        '不存在的发现页分类: $categoryId',
      );
    }
    return _list(rules.explore[i], {'page': '$page'});
  }

  Future<Map<String, Object?>> detail(String id) async {
    final rule = rules.detail ?? _unsupported('detail');
    final doc = await _fetch(rule.request, {'id': id});
    _warnUnknown('detail.fields', rule.fields.keys, _detailFields);
    final f = rule.fields;
    final e = expressions;

    final title = await e.string(f['title'], doc);
    if (title == null) _log('detail($id): title 为空');
    final cover = _url(await e.string(f['cover'], doc));

    final units = <Map<String, Object?>>[];
    if (rule.units case final u?) {
      _warnUnknown('detail.units.fields', u.fields.keys, _unitFields);
      final nodes = await e.nodes(u.list, doc);
      for (final node in u.reverse ? nodes.reversed : nodes) {
        final unitId = await e.string(u.fields['id'], node);
        if (unitId == null) {
          _log('detail($id): 跳过缺少 id 的 unit');
          continue;
        }
        units.add({
          'id': unitId,
          'title': await e.string(u.fields['title'], node) ?? '',
          'index': units.length,
          'updatedAt': ?await e.string(u.fields['updatedAt'], node),
        });
      }
    }

    return {
      'id': id,
      'title': title ?? '',
      'cover': ?cover,
      'author': ?await e.string(f['author'], doc),
      'description': ?await e.string(f['description'], doc),
      'tags': await e.strings(f['tags'], doc),
      'status': ?await e.string(f['status'], doc),
      'updatedAt': ?await e.string(f['updatedAt'], doc),
      'units': units,
    };
  }

  Future<Map<String, Object?>> content(String unitId) async {
    final rule = rules.content ?? _unsupported('content');
    final known = _contentFields[mediaType];
    if (known == null) {
      throw DeclarativeException(
        DeclarativeException.unsupported,
        '未知的媒体类型: $mediaType',
      );
    }
    final doc = await _fetch(rule.request, {'unitId': unitId});
    _warnUnknown('content', rule.fields.keys, known);
    final f = rule.fields;
    final e = expressions;

    switch (mediaType) {
      case 'comic':
        return {
          'images': [
            for (final s in await e.strings(f['images'], doc))
              if (_url(s) case final url?)
                {'url': url, 'headers': ?_mediaHeaders},
          ],
        };
      case 'novel':
        return {
          'text': (await e.strings(f['text'], doc)).join('\n'),
          'nextPageId': ?await e.string(f['nextPageId'], doc),
        };
      case 'video':
        return {'streams': _streams(await e.strings(f['streams'], doc))};
      default: // music
        final lyrics = await e.string(f['lyrics'], doc);
        return {
          'streams': [
            for (final s in _streams(await e.strings(f['streams'], doc)))
              {...s}..remove('type'),
          ],
          if (lyrics != null)
            'lyrics': {
              'format': _lrcLine.hasMatch(lyrics) ? 'lrc' : 'text',
              'content': lyrics,
            },
        };
    }
  }

  static final _lrcLine = RegExp(r'^\[\d{1,3}:\d{2}', multiLine: true);

  List<Map<String, Object?>> _streams(List<String> urls) => [
    for (final s in urls)
      if (_url(s) case final url?)
        {'url': url, 'type': _streamType(url), 'headers': ?_mediaHeaders},
  ];

  static String _streamType(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return 'hls';
    if (path.endsWith('.mpd')) return 'dash';
    if (path.endsWith('.mp4')) return 'mp4';
    return 'auto';
  }

  Map<String, String>? get _mediaHeaders => headers.isEmpty ? null : headers;

  Future<Map<String, Object?>> _list(
    ListRule rule,
    Map<String, String> vars,
  ) async {
    final doc = await _fetch(rule.request, vars);
    final where = rule.name == null ? 'search' : 'explore(${rule.name})';
    _warnUnknown('$where.fields', rule.fields.keys, _searchFields);
    final f = rule.fields;
    final e = expressions;
    final items = <Map<String, Object?>>[];
    for (final node in await e.nodes(rule.list, doc)) {
      final id = await e.string(f['id'], node);
      final title = await e.string(f['title'], node);
      if (id == null || title == null) {
        _log('$where: 跳过缺少 id 或 title 的条目');
        continue;
      }
      final cover = _url(await e.string(f['cover'], node));
      items.add({
        'id': id,
        'title': title,
        'cover': ?cover,
        if (cover != null) 'coverHeaders': ?_mediaHeaders,
        'subtitle': ?await e.string(f['subtitle'], node),
        'tags': await e.strings(f['tags'], node),
      });
    }
    return {'items': items, 'hasMore': await e.truthy(rule.hasMore, doc)};
  }

  Future<SourceDocument> _fetch(
    RequestRule rule,
    Map<String, String> vars,
  ) async {
    final all = {
      ...vars,
      'baseUrl': baseUrl.toString(),
      for (final MapEntry(:key, :value) in settings.entries)
        'setting.$key': value,
    };
    String render(String t) =>
        renderTemplate(t, all, onMissing: (name) => _log('模板变量 {{$name}} 未定义'));

    final rendered = render(rule.url);
    final url = resolveUrl(baseUrl, rendered);
    if (url == null) {
      throw DeclarativeException(
        DeclarativeException.network,
        '非法 URL: $rendered',
      );
    }
    if (!_hosts.isAllowed(url)) {
      throw DeclarativeException(DeclarativeException.hostNotAllowed, url.host);
    }
    final body = rule.body == null ? null : render(rule.body!);
    final reqHeaders = {
      ...headers,
      for (final MapEntry(:key, :value) in rule.headers.entries)
        key: render(value),
    };
    if (body != null &&
        !reqHeaders.keys.any((k) => k.toLowerCase() == 'content-type')) {
      final trimmed = body.trimLeft();
      reqHeaders['Content-Type'] =
          trimmed.startsWith('{') || trimmed.startsWith('[')
          ? 'application/json; charset=utf-8'
          : 'application/x-www-form-urlencoded; charset=utf-8';
    }

    final request = FetchRequest(
      url: url,
      method: rule.method,
      headers: reqHeaders,
      body: body,
      charset: rule.charset,
    );
    final FetchResponse response;
    try {
      response = await fetcher.fetch(request);
    } on FetchException catch (e) {
      throw DeclarativeException(e.code, e.message, e.status);
    } on DeclarativeException {
      rethrow;
    } on Object catch (e) {
      throw DeclarativeException(DeclarativeException.network, '$request: $e');
    }
    if (response.status < 200 || response.status >= 300) {
      throw DeclarativeException(
        DeclarativeException.http,
        '$request',
        response.status,
      );
    }
    return SourceDocument(response.body);
  }

  String? _url(String? ref) =>
      ref == null ? null : resolveUrl(baseUrl, ref)?.toString();

  void _warnUnknown(String where, Iterable<String> keys, Set<String> known) {
    for (final k in keys) {
      if (!known.contains(k)) _log('$where: 未知字段 `$k` 已忽略');
    }
  }

  Never _unsupported(String what) => throw DeclarativeException(
    DeclarativeException.unsupported,
    '规则未定义 $what',
  );
}

void _noLog(String _) {}
