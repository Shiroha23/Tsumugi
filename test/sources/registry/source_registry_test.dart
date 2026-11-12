import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/storage/test_database.dart';

String fixture(String name) =>
    File('test/fixtures/sources/$name').readAsStringSync();

/// 以 declarative_comic.json 为基础修改字段。
String comicWith(Map<String, Object?> changes) {
  final json = jsonDecode(fixture('declarative_comic.json')) as Map;
  return jsonEncode({...json, ...changes});
}

Matcher throwsImport(SourceImportError error, [Object? message]) => throwsA(
  isA<SourceImportException>()
      .having((e) => e.error, 'error', error)
      .having((e) => e.message, 'message', message ?? anything),
);

void main() {
  late AppDatabase db;
  late SourceRegistry registry;
  var now = DateTime.utc(2026, 11, 1);

  setUp(() {
    db = openTestDatabase();
    now = DateTime.utc(2026, 11, 1);
    registry = SourceRegistry(db, clock: () => now);
  });
  tearDown(() => db.close());

  group('导入', () {
    test('预览展示清单信息、访问的主机与未知字段警告', () async {
      final text = fixture('declarative_comic.json');
      final p = await registry.prepareImport(text);

      expect(p.action, ImportAction.install);
      expect(p.manifest.name, '示例漫画');
      expect(p.manifest.type, MediaType.comic);
      expect(p.manifest.version, '1.0.0');
      expect(p.hosts, ['example.com', '*.example-cdn.com']);
      expect(p.parsed.unknownFields, ['someFutureField']);
      expect(p.warnings.single, contains('someFutureField'));
      expect(p.parsed.sha256, sha256.convert(utf8.encode(text)).toString());
      expect(await registry.getAll(), isEmpty, reason: '预览不写库');
    });

    test('安装后可查询，原文与元数据都保存', () async {
      final text = fixture('declarative_comic.json');
      final s = await registry.importText(text);

      expect(s.id, 'com.example.comic');
      expect(s.enabled, isTrue);
      expect(s.manifest, isNotNull);
      expect(s.loadError, isNull);
      expect(s.manifestJson, text);
      expect(s.origin, const SourceOrigin.local());
      expect(s.installedAt.toUtc(), now);

      final all = await registry.getAll();
      expect(all.map((e) => e.id), ['com.example.comic']);
    });

    test('从文件字节导入：去掉 BOM，sha256 按原始字节计算，记录文件名', () async {
      final bytes = [
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(fixture('script_novel.json')),
      ];
      final p = await registry.prepareImportBytes(
        bytes,
        origin: const SourceOrigin.local('script_novel.json'),
      );
      expect(p.parsed.sha256, sha256.convert(bytes).toString());
      final s = await registry.install(p);
      expect(s.type, MediaType.novel);
      expect(s.origin.label, 'script_novel.json');
      expect(s.manifest!.engine, SourceEngine.script);
    });

    test('非 UTF-8 文件被拒绝', () {
      expect(
        () => registry.prepareImportBytes([0xFF, 0xFE, 0x00]),
        throwsImport(SourceImportError.invalidJson),
      );
    });
  });

  group('校验失败', () {
    test('JSON 语法错误', () {
      expect(
        () => registry.prepareImport('{"id": '),
        throwsImport(SourceImportError.invalidJson, contains('JSON 格式错误')),
      );
    });

    test('不是对象', () {
      expect(
        () => registry.prepareImport('[1, 2]'),
        throwsImport(SourceImportError.invalidJson),
      );
    });

    test('缺少必填字段与枚举错误逐条列出', () async {
      final json = jsonDecode(fixture('declarative_comic.json')) as Map;
      json
        ..remove('name')
        ..remove('baseUrl')
        ..['type'] = 'podcast';
      try {
        await registry.prepareImport(jsonEncode(json));
        fail('应当抛出');
      } on SourceImportException catch (e) {
        expect(e.error, SourceImportError.invalidManifest);
        expect(e.messages, contains('缺少必填字段 name'));
        expect(e.messages, contains('缺少必填字段 baseUrl'));
        expect(e.messages.any((m) => m.startsWith('字段 type')), isTrue);
      }
    });

    test('validate() 的错误被透传', () {
      expect(
        () => registry.prepareImport(
          comicWith({'id': 'Bad ID', 'baseUrl': 'ftp://example.com'}),
        ),
        throwsImport(
          SourceImportError.invalidManifest,
          allOf(contains('id 只能包含'), contains('baseUrl 必须是')),
        ),
      );
    });

    test('字段类型错误', () {
      expect(
        () =>
            registry.prepareImport(comicWith({'allowedHosts': 'example.com'})),
        throwsImport(SourceImportError.invalidManifest),
      );
    });

    test('更高的 apiVersion：提示更新客户端，且不报字段错误', () {
      expect(
        () => registry.prepareImport(fixture('future_api_version.json')),
        throwsImport(
          SourceImportError.unsupportedApiVersion,
          allOf(contains('更新版本的客户端'), contains('99')),
        ),
      );
    });

    test('过旧的 apiVersion', () {
      expect(
        () => registry.prepareImport(comicWith({'apiVersion': 0})),
        throwsImport(
          SourceImportError.unsupportedApiVersion,
          contains('不再受支持'),
        ),
      );
    });

    test('缺少 apiVersion', () {
      expect(
        () => registry.prepareImport(comicWith({'apiVersion': null})),
        throwsImport(SourceImportError.invalidManifest, contains('apiVersion')),
      );
    });
  });

  group('升级 / 降级', () {
    test('更高版本：升级，保留启用状态、排序与安装时间', () async {
      await registry.importText(fixture('script_novel.json'));
      await registry.importText(fixture('declarative_comic.json'));
      await registry.setEnabled('com.example.comic', false);
      final before = await registry.get('com.example.comic');

      now = DateTime.utc(2026, 11, 2);
      final p = await registry.prepareImport(
        comicWith({'version': '1.1.0', 'name': '示例漫画 新'}),
        origin: const SourceOrigin.repository('https://example.com/c.json'),
      );
      expect(p.action, ImportAction.upgrade);
      expect(p.existing!.version, '1.0.0');
      final after = await registry.install(p);

      expect(after.version, '1.1.0');
      expect(after.name, '示例漫画 新');
      expect(after.manifest!.version, '1.1.0');
      expect(after.enabled, isFalse);
      expect(after.sortOrder, before!.sortOrder);
      expect(after.installedAt, before.installedAt);
      expect(after.updatedAt.toUtc(), DateTime.utc(2026, 11, 2));
      expect(after.origin.kind, SourceOriginKind.repository);
      expect(after.manifestSha256, isNot(before.manifestSha256));
      expect(await registry.getAll(), hasLength(2));
    });

    test('降级被拒绝', () async {
      await registry.importText(comicWith({'version': '2.0.0'}));
      expect(
        () => registry.prepareImport(fixture('declarative_comic.json')),
        throwsImport(SourceImportError.downgrade, contains('不能降级')),
      );
      expect((await registry.get('com.example.comic'))!.version, '2.0.0');
    });

    test('预览后数据库变为更高版本，安装时仍拒绝降级', () async {
      final p = await registry.prepareImport(fixture('declarative_comic.json'));
      await registry.importText(comicWith({'version': '3.0.0'}));
      expect(
        () => registry.install(p),
        throwsImport(SourceImportError.downgrade),
      );
    });

    test('完全相同的清单：提示已安装', () async {
      await registry.importText(fixture('declarative_comic.json'));
      expect(
        () => registry.prepareImport(fixture('declarative_comic.json')),
        throwsImport(SourceImportError.alreadyInstalled),
      );
    });

    test('同版本不同内容：覆盖并给出警告', () async {
      await registry.importText(fixture('declarative_comic.json'));
      final p = await registry.prepareImport(comicWith({'author': 'other'}));
      expect(p.action, ImportAction.reinstall);
      expect(p.warnings.any((w) => w.contains('版本号未变')), isTrue);
      final s = await registry.install(p);
      expect(s.manifest!.author, 'other');
    });

    test('预发布版升级到正式版', () async {
      await registry.importText(fixture('script_novel.json'));
      final p = await registry.prepareImport(
        jsonEncode({
          ...jsonDecode(fixture('script_novel.json')) as Map,
          'version': '0.3.0',
        }),
      );
      expect(p.action, ImportAction.upgrade);
    });
  });

  group('管理', () {
    Future<void> installThree() async {
      await registry.importText(fixture('declarative_comic.json'));
      await registry.importText(fixture('script_novel.json'));
      await registry.importText(
        comicWith({'id': 'com.example.comic2', 'name': '漫画二'}),
      );
    }

    test('按安装顺序排序，按类型过滤', () async {
      await installThree();
      expect((await registry.getAll()).map((s) => s.id), [
        'com.example.comic',
        'com.example.novel',
        'com.example.comic2',
      ]);
      expect((await registry.getAll(type: MediaType.comic)).map((s) => s.id), [
        'com.example.comic',
        'com.example.comic2',
      ]);
      expect(await registry.getAll(type: MediaType.video), isEmpty);
    });

    test('启用 / 禁用，enabled() 只返回启用的', () async {
      await installThree();
      await registry.setEnabled('com.example.comic', false);
      expect((await registry.get('com.example.comic'))!.enabled, isFalse);
      expect((await registry.enabled(type: MediaType.comic)).map((s) => s.id), [
        'com.example.comic2',
      ]);
      expect(await registry.enabled(), hasLength(2));
      await registry.setEnabled('com.example.comic', true);
      expect(await registry.enabled(), hasLength(3));
    });

    test('删除', () async {
      await installThree();
      expect(await registry.remove('com.example.novel'), isTrue);
      expect(await registry.remove('com.example.novel'), isFalse);
      expect(await registry.get('com.example.novel'), isNull);
      expect(await registry.getAll(), hasLength(2));
      // 删除后可以重新安装（包括更低版本）。
      await registry.remove('com.example.comic');
      await registry.importText(comicWith({'version': '0.1.0'}));
    });

    test('组内重排不影响其他类型的位置', () async {
      await installThree();
      await registry.reorder(['com.example.comic2', 'com.example.comic']);
      expect((await registry.getAll()).map((s) => s.id), [
        'com.example.comic2',
        'com.example.novel',
        'com.example.comic',
      ]);
      expect((await registry.getAll(type: MediaType.comic)).map((s) => s.id), [
        'com.example.comic2',
        'com.example.comic',
      ]);
    });

    test('新安装的源排在最后', () async {
      await installThree();
      await registry.reorder([
        'com.example.comic2',
        'com.example.novel',
        'com.example.comic',
      ]);
      await registry.importText(
        comicWith({'id': 'com.example.comic3', 'name': '漫画三'}),
      );
      expect((await registry.getAll()).last.id, 'com.example.comic3');
    });

    test('watchAll 推送变化', () async {
      final ids = registry.watchAll().map((l) => [for (final s in l) s.id]);
      final expectation = expectLater(
        ids,
        emitsInOrder([
          <String>[],
          ['com.example.comic'],
          <String>[],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      await registry.importText(fixture('declarative_comic.json'));
      await Future<void>.delayed(Duration.zero);
      await registry.remove('com.example.comic');
      await expectation;
    });

    test('库中清单损坏时仍能列出并删除', () async {
      await registry.importText(fixture('declarative_comic.json'));
      await db.customStatement(
        "UPDATE installed_sources SET manifest_json = '{oops' WHERE id = ?",
        ['com.example.comic'],
      );
      final s = (await registry.getAll()).single;
      expect(s.manifest, isNull);
      expect(s.loadError, contains('清单无法解析'));
      expect(s.isUsable, isFalse);
      expect(await registry.enabled(), isEmpty);
      expect(await registry.remove(s.id), isTrue);
    });
  });

  group('SourceFactories', () {
    test('没有对应引擎时抛出 E_UNSUPPORTED', () async {
      final s = await registry.importText(fixture('declarative_comic.json'));
      final factories = SourceFactories(const []);
      expect(factories.supports(SourceEngine.declarative), isFalse);
      expect(
        () => factories.create(s.manifest!),
        throwsA(
          isA<SourceException>().having(
            (e) => e.code,
            'code',
            SourceErrorCode.unsupported,
          ),
        ),
      );
    });
  });
}
