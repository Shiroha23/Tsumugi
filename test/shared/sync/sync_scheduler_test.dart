import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/sync/sync_scheduler.dart';
import 'package:tsumugi/sources/model/common.dart';

import 'sync_test_support.dart';

const _item = LibraryItem(
  sourceId: 'com.example.comic',
  itemId: '/book/1',
  title: '虚构漫画',
  mediaType: MediaType.comic,
);

void main() {
  late MockServer server;
  late TestDevice device;
  late SyncScheduler scheduler;

  setUp(() async {
    server = await MockServer.start();
    device = TestDevice(server);
    scheduler = SyncScheduler(
      service: device.service,
      db: device.db,
      changeDelay: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    scheduler.dispose();
    await device.close();
    await server.close();
  });

  int syncs() => server.requests.where((r) => r.method == 'GET').length;

  Future<void> idle() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    while (device.service.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('does nothing until configured and enabled', () async {
    scheduler.start();
    await idle();
    expect(await scheduler.trigger(), isFalse);
    await device.configure();
    expect(await scheduler.trigger(), isFalse, reason: '未启用自动同步');
    await device.library.add(_item);
    await idle();
    expect(server.requests, isEmpty);
  });

  test('syncs on start, on resume and after local changes', () async {
    await device.configure();
    await device.store.setEnabled(true);
    scheduler.start();
    await idle();
    expect(syncs(), 1, reason: '启动');

    scheduler.onResume();
    await idle();
    expect(syncs(), 2, reason: '回到前台');

    await device.library.add(_item);
    await device.library.setCategory(_item.sourceId, _item.itemId, '在读');
    await idle();
    expect(syncs(), 3, reason: '本地改动后合并为一次');
    expect(server.dav.files.values.single.bytes, isNotEmpty);

    // 同步自己写回的数据不再触发同步。
    await idle();
    expect(syncs(), 3);
  });

  test('a change that comes due during a running sync is retried', () async {
    await device.configure();
    await device.store.setEnabled(true);
    scheduler.start();
    await idle();
    expect(syncs(), 1);
    // 第二次同步进行中（被 412 拖住重试）时，本地改动的计时到期。
    await device.library.add(_item);
    server.dav.force412 = 2;
    final running = device.service.sync();
    await device.library.setCategory(_item.sourceId, _item.itemId, '在读');
    await running;
    await idle();
    await idle();
    final state = await device.store.ensureState();
    expect(await device.store.hasLocalChanges(), isFalse, reason: '改动最终同步了');
    expect(state.lastError, isNull);
  });

  test('errors are recorded, not thrown', () async {
    final bad = TestDevice(server, password: 'wrong');
    addTearDown(bad.close);
    await bad.configure();
    await bad.store.setEnabled(true);
    final s = SyncScheduler(service: bad.service, db: bad.db);
    addTearDown(s.dispose);
    expect(await s.trigger(), isTrue);
    expect((await bad.store.ensureState()).lastError, isNotNull);
  });
}
