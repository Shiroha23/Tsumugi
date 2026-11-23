import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/download/providers.dart';
import '../../common/detail/media_detail_provider.dart';

/// 播放页的详情（选集、进度快照）：即详情页的 [mediaDetailProvider]；取不到（离线、源被删除 / 禁用）且该条目有下载时，
/// 改用下载时的快照（architecture §4.5、§4.5.1「离线回放」）。验证 / 登录类错误照常抛出。
final videoPlayerDetailProvider = FutureProvider.autoDispose
    .family<MediaDetailData, (String, String)>(
      (ref, key) async {
        final (sourceId, itemId) = key;
        try {
          // 与详情页共用缓存：从详情页进入时不再请求一次 detail()。
          return await ref.watch(mediaDetailProvider(sourceId, itemId).future);
        } on Object catch (e) {
          if (!useDetailSnapshotFor(e)) rethrow;
          final snapshot = await ref
              .read(downloadLibraryProvider)
              .detailSnapshot(sourceId, itemId);
          if (snapshot == null) rethrow;
          return MediaDetailData(detail: snapshot, sourceHeaders: const {});
        }
      },
      // 失败（离线等）不自动重试：快照已是回退结果，重试只会反复请求。
      retry: (_, _) => null,
    );
