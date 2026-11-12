import 'package:flutter/material.dart';

import '../../sources/model/common.dart';

extension MediaTypeLabel on MediaType {
  String get label => switch (this) {
    MediaType.comic => '漫画',
    MediaType.novel => '小说',
    MediaType.video => '视频',
    MediaType.music => '音乐',
  };

  IconData get icon => switch (this) {
    MediaType.comic => Icons.photo_library_outlined,
    MediaType.novel => Icons.menu_book_outlined,
    MediaType.video => Icons.movie_outlined,
    MediaType.music => Icons.music_note_outlined,
  };
}

extension SourceEngineLabel on SourceEngine {
  String get label => switch (this) {
    SourceEngine.declarative => '声明式',
    SourceEngine.script => '脚本',
  };
}
