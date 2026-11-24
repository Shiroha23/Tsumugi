# 第三方组件声明（Third-Party Notices）

Tsumugi 按 [GPL-3.0-or-later](LICENSE) 发布。本文件列出随安装包分发的**原生组件**（不在 Dart 包中）的版本、许可证与源码地址。

- **Dart 包与 Flutter 引擎**的许可证由 Flutter 自动收集，与下列原生组件一起在应用的「设置 → 关于 → 第三方许可证」中显示。
- 原生组件的许可证全文在 [`assets/licenses/`](assets/licenses/)，注册代码在
  [`lib/features/settings/about/native_licenses.dart`](lib/features/settings/about/native_licenses.dart)。
- **对应源码**（GPL-3.0 §6）：本项目源码即本仓库；原生组件的源码与构建脚本按
  [`tool/release/native_sources.tsv`](tool/release/native_sources.tsv) 下载、校验 sha256 后，以
  `tsumugi-<版本>-native-sources.tar` 随每个 [Release](https://github.com/Shiroha23/Tsumugi/releases) 上传。
- 核对方法与结论见 [`docs/architecture.md`](docs/architecture.md) §6.4.1（M4-B，2026-11）与 §6.4.6 第 2 项（Windows 自建 libmpv，2026-11）。
  “二进制”指从插件固定的预编译库中读出的版本串 / 配置串。

升级 `media_kit_libs_*_video` 等带原生库的依赖、或更换 Windows 自建 libmpv（`windows/libmpv.lock`）时，须同步更新本文件、`assets/licenses/`、
`native_licenses.dart` 与 `native_sources.tsv`。

## libmpv 的来源

| 平台 | 插件 | 预编译库 | 构建脚本（确切提交） |
|---|---|---|---|
| Windows | `media_kit_libs_windows_video` 1.0.11（只用其插件代码与 ANGLE 包；`libmpv-2.dll` 由 `windows/CMakeLists.txt` 替换） | **本项目自建** `libmpv-win-0.42.0-ff8.1.3-r1.zip`（[Shiroha23/Tsumugi-libmpv](https://github.com/Shiroha23/Tsumugi-libmpv) 的不可变 Release，地址与 sha256 固定在 [`windows/libmpv.lock`](windows/libmpv.lock)） | Tsumugi-libmpv 的 `windows/build.sh` + `windows/sources.tsv`，由其 GitHub Actions 构建并附来源证明 |
| Android | `media_kit_libs_android_video` 1.3.8 | `default-<abi>.jar`（MD5 写死在插件 build.gradle） | [media-kit/libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build) `v1.1.7`（`fe8c3ac1a91c`） |
| iOS | `media_kit_libs_ios_video` 1.1.4 | `libmpv-xcframeworks_v0.6.0_ios-universal-video-default.tar.gz`（sha256 `a95bc185…d36ae`） | [media-kit/libmpv-darwin-build](https://github.com/media-kit/libmpv-darwin-build) `v0.6.0`（`4286f5557bdc`） |

三个平台都用 LGPL 构建：mpv `-Dgpl=false`，FFmpeg 带 `--enable-version3`、不带 `--enable-gpl` / `--enable-nonfree`（二进制中 `libavcodec license: LGPL version 3 or later`；
Windows 自建构建的工作流对此有门禁检查）。libplacebo 只在 Windows 自建构建中启用（mpv 0.37 起必需），Android / iOS 的 mpv 0.36 没有它。

## mpv / FFmpeg 与共同依赖

| 组件 | 许可证 | Windows | Android | iOS | 源码 |
|---|---|---|---|---|---|
| mpv (libmpv) | LGPL-2.1-or-later | 0.42.0 | `78d43740f52d`（depinfo） | 0.36.0（锁文件 + 二进制） | https://github.com/mpv-player/mpv |
| FFmpeg | LGPL-3.0-or-later | 8.1.3 | n6.0（depinfo + 二进制） | 6.0（锁文件 + 二进制） | https://ffmpeg.org/ |
| libass | ISC | 0.17.5 | 0.17.1 | 0.17.1 | https://github.com/libass/libass |
| FreeType | FTL OR GPL-2.0-or-later（按 FTL） | 2.15.0 | 2.13.0 | 2.13.2 | https://freetype.org/ |
| HarfBuzz | MIT | 15.2.0 | 7.2.0 | 8.1.1 | https://github.com/harfbuzz/harfbuzz |
| GNU FriBidi | LGPL-2.1-or-later | 1.0.18 | 1.0.12（depinfo + 二进制） | 1.0.13 | https://github.com/fribidi/fribidi |
| Mbed TLS | Apache-2.0 OR GPL-2.0-or-later（按 Apache-2.0） | — | 3.4.0 | 3.4.1 | https://github.com/Mbed-TLS/mbedtls |
| dav1d | BSD-2-Clause | 1.5.5 | 1.2.0（二进制） | 1.2.1 | https://code.videolan.org/videolan/dav1d |
| libxml2 | MIT | — | 2.10.3 | 2.11.5 | https://gitlab.gnome.org/GNOME/libxml2 |
| uchardet | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later（按 LGPL） | — | — | 0.0.8 | https://www.freedesktop.org/wiki/Software/uchardet/ |
| libpng | libpng-2.0 | — | — | 1.6.40（二进制；FreeType 的 meson 回退子项目） | https://github.com/pnggroup/libpng |
| media-kit-android-helper | MIT | — | `42054e5d479f` | — | https://github.com/media-kit/media-kit-android-helper |

Windows 的版本取自 Tsumugi-libmpv 的 `windows/sources.tsv`（发布包 + sha256）。Android 的版本取自 `buildscripts/include/depinfo.sh`，iOS 取自 `downloads.lock`
（均在上述确切提交处），并与二进制中的版本串核对。

## Windows：静态链接进 `libmpv-2.dll` 的其他依赖

全部依赖与上表 Windows 列的组件一样，按 Tsumugi-libmpv 的 `windows/sources.tsv` 中的发布包（sha256 固定）构建，
静态链接进 `libmpv-2.dll`，`libmpv-2.dll` 只依赖 Windows 系统 DLL。**对应源码**是同一 Release 中的 `libmpv-win-<版本>-sources.tar`
（全部源码发布包 + 构建脚本 + `BUILD_INFO.txt`），也收进每次发版的 `tsumugi-<版本>-native-sources.tar`。

（2026-11 之前的 Windows 版本用 media-kit 2023-09 的预编译库，多数依赖的确切源码提交没有记录，见 `docs/architecture.md` §6.4.1。）

| 组件 | 许可证 | 版本 | 源码 |
|---|---|---|---|
| libplacebo | LGPL-2.1-or-later | 7.387.0 | https://code.videolan.org/videolan/libplacebo |
| glad (OpenGL loader in libplacebo) | (WTFPL OR CC0-1.0) AND Apache-2.0（生成的代码；生成器为 MIT，不随包） | git `73db193f853e` | https://github.com/Dav1dde/glad |
| fast_float | MIT OR Apache-2.0 OR BSL-1.0（按 MIT） | git `97b54ca9e75f` | https://github.com/fastfloat/fast_float |
| zlib (libmpv-2.dll) | Zlib | 1.4 | https://zlib.net/ |
| mingw-w64 runtime（含 winpthreads，UCRT） | ZPL-2.1 AND MIT AND BSD-3-Clause | llvm-mingw 20261104 | https://www.mingw-w64.org/ |
| LLVM runtime (libc++ / libunwind / compiler-rt) | Apache-2.0 WITH LLVM-exception | LLVM 23.1.5（llvm-mingw 20261104） | https://github.com/llvm/llvm-project |

以上两项是交叉编译工具链 llvm-mingw（版本与 sha256 见 Tsumugi-libmpv 的 `windows/toolchain.tsv`）自带的运行库。
libplacebo 构建时用到的 Jinja / MarkupSafe（BSD-3-Clause，构建时运行的代码生成器）与 Vulkan-Headers（Apache-2.0 OR MIT，
只用于编译不启用的 Vulkan 桩代码）不随包分发，源码同样在源码包中。mpv 带一个本项目的构建补丁（见源码包 `build-scripts/patches/`）。

## Windows：ANGLE 包与其他原生库

| 文件 | 组件 | 许可证 | 版本 | 源码 |
|---|---|---|---|---|
| `libEGL.dll`、`libGLESv2.dll` | ANGLE | BSD-3-Clause | 2.1.18844，`2693b03eba82a424a19febaacaab4115a45b7682`（版本资源） | https://chromium.googlesource.com/angle/angle |
| `vk_swiftshader.dll` | SwiftShader | Apache-2.0 | 5.0.0（ANGLE 上述提交的依赖） | https://swiftshader.googlesource.com/SwiftShader |
| `vulkan-1.dll` | Vulkan Loader | Apache-2.0 | ANGLE 上述提交的依赖 | https://github.com/KhronosGroup/Vulkan-Loader |
| `zlib.dll` | zlib (ANGLE zlib.dll) | Zlib | 1.2.12（二进制） | https://zlib.net/ |
| `WebView2Loader.dll` | Microsoft Edge WebView2 SDK (WebView2Loader.dll) | 微软 BSD-3 风格条款（`assets/licenses/webview2.txt`） | 1.0.3650.58 | **微软闭源组件**，按 SDK 条款以动态库随包再分发，无源码；https://www.nuget.org/packages/Microsoft.Web.WebView2 |
| `flutter_inappwebview_windows_plugin.dll`（头文件库） | Windows Implementation Libraries (WIL)、C++/WinRT、nlohmann/json | MIT | 随插件构建 | https://github.com/microsoft/wil 、https://github.com/microsoft/cppwinrt 、https://github.com/nlohmann/json |

ANGLE 包来自 [alexmercerind/flutter-windows-ANGLE-OpenGL-ES](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES) `v1.0.1`（作者自行编译）。
该包中的 **`d3dcompiler_47.dll`（微软可再分发组件）不随本项目分发**（`windows/CMakeLists.txt` 排除），ANGLE 使用 Windows 自带的同名 DLL。

## 三平台：本项目直接使用的原生库

| 组件 | 许可证 | 版本 | 源码 |
|---|---|---|---|
| QuickJS-ng | MIT | 0.17.0（`qjs` 0.2.3 内置源码） | https://github.com/quickjs-ng/quickjs |
| SQLite | 公有领域（blessing） | 随 `sqlite3` 包（Windows 为 3.54.1） | https://sqlite.org/ |
