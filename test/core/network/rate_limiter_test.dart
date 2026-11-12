import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/rate_limiter.dart';

void main() {
  test('令牌桶：容量内立即放行，之后按速率等待（虚拟时钟）', () async {
    var now = Duration.zero;
    final waits = <Duration>[];
    final bucket = TokenBucket(
      requests: 3,
      per: const Duration(seconds: 3),
      clock: () => now,
      delay: (d) async {
        waits.add(d);
        now += d;
      },
    );

    for (var i = 0; i < 3; i++) {
      await bucket.acquire();
    }
    expect(waits, isEmpty);
    expect(now, Duration.zero);

    await bucket.acquire();
    await bucket.acquire();
    expect(now, const Duration(seconds: 2)); // 每个令牌 1s
  });

  test('空闲后令牌恢复，但不超过容量', () async {
    var now = Duration.zero;
    final bucket = TokenBucket(
      requests: 2,
      per: const Duration(seconds: 1),
      clock: () => now,
      delay: (d) async => now += d,
    );
    await bucket.acquire();
    await bucket.acquire();
    now += const Duration(seconds: 10);
    final start = now;
    await bucket.acquire();
    await bucket.acquire();
    expect(now, start); // 恢复满 2 个
    await bucket.acquire();
    expect(now - start, const Duration(milliseconds: 500));
  });

  test('并发 acquire 按 FIFO 顺序放行', () async {
    var now = Duration.zero;
    final bucket = TokenBucket(
      requests: 1,
      per: const Duration(seconds: 1),
      clock: () => now,
      delay: (d) async => now += d,
    );
    final order = <int>[];
    await Future.wait([
      for (var i = 0; i < 4; i++) bucket.acquire().then((_) => order.add(i)),
    ]);
    expect(order, [0, 1, 2, 3]);
    expect(now, const Duration(seconds: 3));
  });

  test('abort 后立即返回 false，不消耗令牌，也不拖慢后面的调用', () async {
    var now = Duration.zero;
    final bucket = TokenBucket(
      requests: 1,
      per: const Duration(seconds: 10),
      clock: () => now,
      delay: (d) => Completer<void>().future, // 时间不前进：只有 abort 能让等待结束
    );
    expect(await bucket.acquire(), isTrue);

    final abort = Completer<void>();
    final queued = bucket.acquire(abort: abort.future);
    abort.complete();
    expect(await queued, isFalse);

    // 令牌恢复后，下一个调用拿到的就是那一个令牌
    now += const Duration(seconds: 10);
    expect(await bucket.acquire(), isTrue);
  });
}
