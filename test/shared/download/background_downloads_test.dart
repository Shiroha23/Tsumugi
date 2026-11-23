import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/download/providers.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';

import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _source = 'com.example.comic';
const _item = '/book/1';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _FakePlatform implements BackgroundDownloadPlatform {
  final calls = <String>[];
  final sink = StreamController<BackgroundDownloadEvent>.broadcast();
  Duration? remaining = const Duration(seconds: 30);

  @override
  Stream<BackgroundDownloadEvent> get events => sink.stream;

  bool showResult = true;
  Completer<Duration?>? beginGate;

  @override
  Future<bool> show({required String text, double? progress}) async {
    calls.add('show');
    return showResult;
  }

  @override
  Future<void> hide() async => calls.add('hide');

  @override
  Future<void> requestNotificationPermission() async => calls.add('permission');

  @override
  Future<Duration?> beginBackgroundTask() async {
    calls.add('begin');
    if (beginGate case final g?) return g.future;
    return remaining;
  }

  @override
  Future<void> endBackgroundTask() async => calls.add('end');
}

/// 后台下载（architecture §4.5.1，#74）：队列状态 → 前台服务通知；「暂停全部」；Android 15 时限；
/// iOS 宽限时间到期前挂起（进行中的回到 queued），回到前台继续。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppDatabase db;
  late DownloadRepository repo;
  late DownloadManager manager;
  late _FakePlatform platform;

  /// 设置后图片请求等它完成（让 unit 停在 running）。
  Completer<void>? gate;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tsumugi_bg_');
    db = openTestDatabase();
    repo = DownloadRepository(db);
    platform = _FakePlatform();
    gate = null;
    manager = DownloadManager(
      repository: repo,
      store: DownloadStore(() => Directory('${tmp.path}/downloads')),
      sourceFor: (id) async => FakeSource(
        SourceManifest.fromJson(
          jsonDecode(fakeManifestJson(id)) as Map<String, dynamic>,
        ),
        onContent: (unitId) async => const ComicContent(
          images: [ImageRef(url: 'https://img.example.com/1.png')],
        ),
      ),
      fetchImage: (_, _) async {
        await gate?.future;
        return Uint8List.fromList(_png);
      },
    );
    await manager.start();
  });
  tearDown(() async {
    if (gate case final g? when !g.isCompleted) g.complete();
    manager.dispose();
    await manager.idle;
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> enqueue(List<String> units) => manager.enqueue(
    const LibraryItem(
      sourceId: _source,
      itemId: _item,
      title: '虚构漫画',
      mediaType: MediaType.comic,
    ),
    Detail(
      id: _item,
      title: '虚构漫画',
      units: [for (final u in units) Unit(id: u, title: u)],
    ),
    [
      for (final (i, u) in units.indexed)
        DownloadRequestUnit(
          Unit(id: u, title: u),
          groupName: '默认',
          index: i,
        ),
    ],
  );

  BackgroundDownloadController controller({bool ios = false}) =>
      BackgroundDownloadController(
        manager: manager,
        repository: repo,
        platform: platform,
        usesBackgroundTask: ios,
        safetyMargin: const Duration(seconds: 29, milliseconds: 900),
        updateInterval: Duration.zero,
      )..attach();

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<DownloadStatus> status(String unit) async =>
      (await repo.unit(_source, _item, unit))!.status;

  test(
    'Android: notification while the queue has work; permission asked once',
    () async {
      final c = controller();
      gate = Completer();
      await enqueue(['/c/1']);
      await settle();
      expect(platform.calls.first, 'permission');
      expect(platform.calls, contains('show'));
      expect(platform.calls.where((c) => c == 'permission'), hasLength(1));
      if (!gate!.isCompleted) gate!.complete();
      await manager.idle;
      await settle();
      expect(platform.calls.last, 'hide');
      await c.dispose();
    },
  );

  test('"pause all" pauses queued and running units', () async {
    final c = controller();
    gate = Completer();
    await enqueue(['/c/1', '/c/2']);
    await settle();
    platform.sink.add(BackgroundDownloadEvent.pauseAll);
    await settle();
    if (!gate!.isCompleted) gate!.complete();
    await manager.idle;
    expect(await status('/c/1'), DownloadStatus.paused);
    expect(await status('/c/2'), DownloadStatus.paused);
    await settle();
    expect(platform.calls.last, 'hide');
    await c.dispose();
  });

  test(
    'Android 15 timeout in background suspends; foreground resumes',
    () async {
      final c = controller();
      gate = Completer();
      await enqueue(['/c/1']);
      await settle();
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      platform.sink.add(BackgroundDownloadEvent.timeout);
      await settle();
      expect(manager.suspended, isTrue);
      expect(await status('/c/1'), DownloadStatus.queued, reason: '进行中的回到排队');
      if (!gate!.isCompleted) gate!.complete();
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(manager.suspended, isFalse);
      await settle();
      await manager.idle;
      expect(await status('/c/1'), DownloadStatus.done);
      await c.dispose();
    },
  );

  test(
    'iOS: grace period → suspend before expiry, end task; resume in foreground',
    () async {
      final c = controller(ios: true);
      gate = Completer();
      await enqueue(['/c/1']);
      await settle();
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      // 剩余 30 s、提前 29.9 s 挂起：约 100 ms 后挂起。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(platform.calls, containsAllInOrder(['begin', 'end']));
      expect(platform.calls, isNot(contains('show')), reason: 'iOS 没有常驻通知');
      expect(manager.suspended, isTrue);
      expect(await status('/c/1'), DownloadStatus.queued);
      if (!gate!.isCompleted) gate!.complete();
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      await manager.idle;
      expect(await status('/c/1'), DownloadStatus.done);
      await c.dispose();
    },
  );

  test('iOS: system expiry notice suspends immediately', () async {
    final c = controller(ios: true);
    platform.remaining = const Duration(minutes: 10);
    gate = Completer();
    await enqueue(['/c/1']);
    await settle();
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(manager.suspended, isFalse);
    platform.sink.add(BackgroundDownloadEvent.expiring);
    await settle();
    expect(manager.suspended, isTrue);
    expect(platform.calls.last, 'end');
    await c.dispose();
  });

  test('iOS: nothing to download → no background task', () async {
    final c = controller(ios: true);
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(platform.calls, isEmpty);
    await c.dispose();
  });

  test('describe', () {
    DownloadUnit u(DownloadStatus s, int done, int total) => DownloadUnit(
      sourceId: _source,
      itemId: _item,
      unitId: '$s$done',
      title: 't',
      groupName: 'g',
      index: 0,
      status: s,
      completedFiles: done,
      totalFiles: total,
      bytes: 0,
      errorCode: null,
      queueOrder: 0,
      updatedAt: DateTime(2026),
    );
    final (text, progress) = BackgroundDownloadController.describe([
      u(DownloadStatus.running, 3, 4),
      u(DownloadStatus.running, 1, 4),
      u(DownloadStatus.queued, 0, 0),
    ]);
    expect(text, '正在下载 2 项，剩余 3 项');
    expect(progress, 0.5);
    expect(
      BackgroundDownloadController.describe([u(DownloadStatus.queued, 0, 0)]),
      ('排队中：1 项', null),
    );
  });

  test('Android: service unavailable (timeout in foreground / start refused) → suspend when going to background', () async {
    final c = controller();
    gate = Completer();
    await enqueue(['/c/1']);
    await settle();
    platform.sink.add(BackgroundDownloadEvent.timeout); // 仍在前台
    await settle();
    expect(manager.suspended, isFalse, reason: '前台时不挂起');
    final shows = platform.calls.where((c) => c == 'show').length;
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(manager.suspended, isTrue);
    expect(await status('/c/1'), DownloadStatus.queued);
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(
      platform.calls.where((c) => c == 'show').length,
      shows,
      reason: '本次进程内不再启动服务',
    );
    if (!gate!.isCompleted) gate!.complete();
    await manager.idle;
    expect(await status('/c/1'), DownloadStatus.done);
    await c.dispose();
  });

  test('Android: show() refused marks the service unavailable', () async {
    platform.showResult = false;
    final c = controller();
    gate = Completer();
    await enqueue(['/c/1']);
    await settle();
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(manager.suspended, isTrue);
    await c.dispose();
  });

  test('Android: permission is not requested while in background', () async {
    final c = controller();
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    gate = Completer();
    await enqueue(['/c/1']);
    await settle();
    expect(platform.calls, isNot(contains('permission')));
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(platform.calls, contains('permission'));
    await c.dispose();
  });

  test('iOS: quick background/foreground switching does not suspend in the foreground', () async {
    final c = controller(ios: true);
    gate = Completer();
    await enqueue(['/c/1']);
    await settle();
    platform.beginGate = Completer();
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    // 过期的 begin 结果迟到：不再建立计时器。
    platform.beginGate!.complete(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(manager.suspended, isFalse);
    // 迟到的到期通知（已在前台）同样忽略。
    platform.sink.add(BackgroundDownloadEvent.expiring);
    await settle();
    expect(manager.suspended, isFalse);
    await c.dispose();
  });

  test('iOS: no grace period returned → suspend immediately', () async {
    platform.remaining = null;
    final c = controller(ios: true);
    gate = Completer();
    await enqueue(['/c/1']);
    await settle();
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(manager.suspended, isTrue);
    expect(platform.calls.last, 'end');
    await c.dispose();
  });

  test('pauseAll does not overwrite units that completed meanwhile', () async {
    await enqueue(['/c/1']);
    await manager.idle;
    expect(await status('/c/1'), DownloadStatus.done);
    await manager.pauseAll();
    expect(await status('/c/1'), DownloadStatus.done);
  });

  test(
    'suspend while the queue is claiming a unit puts it back to queued',
    () async {
      gate = Completer();
      // enqueue 触发 _pump；不等它，立刻挂起（认领与挂起交错）。
      final adding = enqueue(['/c/1', '/c/2']);
      await Future<void>.delayed(Duration.zero);
      await manager.suspend();
      await adding;
      await settle();
      expect(await status('/c/1'), DownloadStatus.queued);
      expect(await status('/c/2'), DownloadStatus.queued);
      if (!gate!.isCompleted) gate!.complete();
      manager.resumeQueue();
      await settle();
      await manager.idle;
      expect(await status('/c/2'), DownloadStatus.done);
    },
  );
}
