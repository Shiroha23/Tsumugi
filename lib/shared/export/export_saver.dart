import 'package:file_picker/file_picker.dart';

import 'export_models.dart';

/// 把导出文件交给用户保存。测试中可替换。
abstract interface class ExportSaver {
  /// 保存 [file]；返回保存位置的说明（路径或 URI），用户取消时返回 null。
  Future<String?> save(ExportFile file);
}

/// 系统保存对话框（`file_picker` 的 `saveFile`，MIT）：
///
/// - Windows / macOS / Linux：保存对话框选路径，由插件写入字节。
/// - Android：系统“创建文档”界面（Storage Access Framework），可存到本机或网盘。
/// - iOS：文件 App 的导出界面（存到“我的 iPhone”/ iCloud 等）。
class FilePickerExportSaver implements ExportSaver {
  const FilePickerExportSaver();

  @override
  Future<String?> save(ExportFile file) async {
    final uri = await FilePicker.saveFile(
      dialogTitle: '保存导出文件',
      fileName: file.fileName,
      bytes: file.bytes,
      mimeType: file.format.mimeType,
    );
    if (uri == null) return null;
    return uri.isScheme('file') ? uri.toFilePath() : uri.toString();
  }
}
