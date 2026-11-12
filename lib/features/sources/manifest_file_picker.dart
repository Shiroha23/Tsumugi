import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'manifest_file_picker.g.dart';

typedef PickedManifestFile = ({String name, Uint8List bytes});

/// 选择一个清单文件；用户取消时返回 null。测试中可替换。
abstract interface class ManifestFilePicker {
  Future<PickedManifestFile?> pick();
}

class PlatformManifestFilePicker implements ManifestFilePicker {
  const PlatformManifestFilePicker();

  /// 清单文件上限，防止误选大文件。
  static const maxBytes = 4 * 1024 * 1024;

  @override
  Future<PickedManifestFile?> pick() async {
    // Android 上 .json 的 MIME 识别不可靠，不按扩展名过滤。
    final file = Platform.isAndroid
        ? await FilePicker.pickFile(dialogTitle: '选择源清单')
        : await FilePicker.pickFile(
            dialogTitle: '选择源清单',
            type: FileType.custom,
            allowedExtensions: const ['json'],
          );
    if (file == null) return null;
    final length = file.lengthSync() ?? await file.length();
    if (length != null && length > maxBytes) {
      throw const FileSystemException('文件过大（超过 4 MB），不像是源清单');
    }
    return (name: file.name, bytes: await file.readAsBytes());
  }
}

@riverpod
ManifestFilePicker manifestFilePicker(Ref ref) =>
    const PlatformManifestFilePicker();
