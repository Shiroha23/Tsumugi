# Tsumugi 原生组件源码包

本包是 Tsumugi 安装包中**原生组件**的对应源码与构建脚本（GPL-3.0 §6、LGPL）。
Tsumugi 自身的源码见 https://github.com/Shiroha23/Tsumugi （与本 Release 同一标签）。

- `native_sources.tsv`：本包每个文件的组件、版本、许可证、原始下载地址与 sha256。
- `windows/`、`android/`、`ios/`、`common/`：按平台存放的源码压缩包（`common/` 为多个平台共用）。
  构建仓库的存档（`libmpv-*-build-*.tar.gz`）包含构建脚本与补丁。
- `windows_libmpv_build_config.txt`：从 Windows `libmpv-2.dll` 中提取的 mpv / FFmpeg 配置串与版本串。

**Windows 的限制**：Windows 预编译 libmpv（media-kit/libmpv-win32-video-build 发布 2023-09-24，构建仓库已归档）
构建时多数依赖取 git 最新提交，确切提交没有记录，当时的定制脚本也不在构建仓库的历史中。
本包提供能确定版本的 mpv、FFmpeg 与 LGPL 组件，以及构建仓库的现存脚本；其余宽松许可证组件的上游地址见
仓库中的 `THIRD_PARTY_NOTICES.md`。如需其他源码，请在 https://github.com/Shiroha23/Tsumugi/issues 提出。

各组件的许可证全文见安装包内「设置 → 关于 → 第三方许可证」或仓库中的 `assets/licenses/`。
