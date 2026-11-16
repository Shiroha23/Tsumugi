# 第三方组件声明（Third-Party Notices）

Tsumugi 按 [GPL-3.0-or-later](LICENSE) 发布。本文件列出随安装包分发的**原生组件**（不在 Dart 包中）的版本、许可证与源码地址。

- **Dart 包与 Flutter 引擎**的许可证由 Flutter 自动收集，与下列原生组件一起在应用的「设置 → 关于 → 第三方许可证」中显示。
- 原生组件的许可证全文在 [`assets/licenses/`](assets/licenses/)，注册代码在
  [`lib/features/settings/about/native_licenses.dart`](lib/features/settings/about/native_licenses.dart)。
- **对应源码**（GPL-3.0 §6）：本项目源码即本仓库；原生组件的源码与构建脚本按
  [`tool/release/native_sources.tsv`](tool/release/native_sources.tsv) 下载、校验 sha256 后，以
  `tsumugi-<版本>-native-sources.tar` 随每个 [Release](https://github.com/Shiroha23/Tsumugi/releases) 上传。
- 核对方法与结论见 [`docs/architecture.md`](docs/architecture.md) §6.4.1（M4-B，2026-11）。“二进制”指从插件固定的预编译库中读出的版本串 / 配置串。

升级 `media_kit_libs_*_video` 等带原生库的依赖时，须同步更新本文件、`assets/licenses/`、`native_licenses.dart` 与 `native_sources.tsv`。

## 预编译 libmpv 的来源

| 平台 | 插件 | 预编译库 | 构建仓库（确切提交） |
|---|---|---|---|
| Windows | `media_kit_libs_windows_video` 1.0.11 | `mpv-dev-x86_64-20230924-git-652a1dd.7z`（MD5 `a832ef24b3a6ff97cd2560b5b9d04cd8`） | [media-kit/libmpv-win32-video-build](https://github.com/media-kit/libmpv-win32-video-build)（**已归档**）发布 `2023-09-24`；标签只含版本号文件，构建时的定制脚本未保留，见下文 |
| Android | `media_kit_libs_android_video` 1.3.8 | `default-<abi>.jar`（MD5 写死在插件 build.gradle） | [media-kit/libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build) `v1.1.7`（`fe8c3ac1a91c`） |
| iOS | `media_kit_libs_ios_video` 1.1.4 | `libmpv-xcframeworks_v0.6.0_ios-universal-video-default.tar.gz`（sha256 `a95bc185…d36ae`） | [media-kit/libmpv-darwin-build](https://github.com/media-kit/libmpv-darwin-build) `v0.6.0`（`4286f5557bdc`） |

三个平台都用 LGPL 构建：mpv `-Dgpl=false`，FFmpeg `--disable-gpl --disable-nonfree --enable-version3`（二进制中 `libavcodec license: LGPL version 3 or later`）。
libplacebo 三个平台都没有启用。

## mpv / FFmpeg 与共同依赖

| 组件 | 许可证 | Windows | Android | iOS | 源码 |
|---|---|---|---|---|---|
| mpv (libmpv) | LGPL-2.1-or-later | `v0.36.0-403-g652a1dd907`（二进制） | `78d43740f52d`（depinfo） | 0.36.0（锁文件 + 二进制） | https://github.com/mpv-player/mpv |
| FFmpeg | LGPL-3.0-or-later | n6.0（二进制） | n6.0（depinfo + 二进制） | 6.0（锁文件 + 二进制） | https://ffmpeg.org/ |
| libass | ISC | 未记录 | 0.17.1 | 0.17.1 | https://github.com/libass/libass |
| FreeType | FTL OR GPL-2.0-or-later（按 FTL） | 未记录 | 2.13.0 | 2.13.2 | https://freetype.org/ |
| HarfBuzz | MIT | 未记录 | 7.2.0 | 8.1.1 | https://github.com/harfbuzz/harfbuzz |
| GNU FriBidi | LGPL-2.1-or-later | 1.0.13（二进制） | 1.0.12（depinfo + 二进制） | 1.0.13 | https://github.com/fribidi/fribidi |
| Mbed TLS | Apache-2.0 OR GPL-2.0-or-later（按 Apache-2.0） | 3.4.1（上游脚本固定，推断） | 3.4.0 | 3.4.1 | https://github.com/Mbed-TLS/mbedtls |
| dav1d | BSD-2-Clause | `1.2.1-48-g769bd14`（二进制，推断） | 1.2.0（二进制） | 1.2.1 | https://code.videolan.org/videolan/dav1d |
| libxml2 | MIT | 未记录 | 2.10.3 | 2.11.5 | https://gitlab.gnome.org/GNOME/libxml2 |
| uchardet | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later（按 LGPL） | 未记录 | — | 0.0.8 | https://www.freedesktop.org/wiki/Software/uchardet/ |
| libpng | libpng-2.0 | 1.6.41.git（二进制） | — | 1.6.40（二进制；FreeType 的 meson 回退子项目） | https://github.com/pnggroup/libpng |
| media-kit-android-helper | MIT | — | `42054e5d479f` | — | https://github.com/media-kit/media-kit-android-helper |

Android 的版本取自 `buildscripts/include/depinfo.sh`，iOS 取自 `downloads.lock`（均在上述确切提交处），并与二进制中的版本串核对。

## Windows：静态链接进 `libmpv-2.dll` 的其他依赖

Windows 的构建脚本（[shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake) 的分支）对多数依赖不固定版本，构建时取各自 git 的最新提交，
**确切提交没有记录**；media-kit 当时的定制脚本也不在构建仓库的 git 历史中。下表的组件依据二进制中的配置串
（[`tool/release/windows_libmpv_build_config.txt`](tool/release/windows_libmpv_build_config.txt)）与字符串确定；
“推断”表示版本取自构建时（2023-09-24 之前）上游脚本固定的版本，未能从二进制确认。

**Windows 对应源码的现状（已决定，2026-11）**：

- **缺什么**：下表多数组件的确切源码提交，以及 media-kit 当时的定制构建脚本（裁剪解码器等）。
- **为什么**：上游构建脚本构建时取各依赖 git 的最新提交且不记录；定制脚本未提交进构建仓库的历史，仓库也已归档。
- **现在提供**：mpv `652a1dd`、FFmpeg n6.0、FriBidi 1.0.13、libsoxr 0.1.3、GNU libiconv 1.17 的源码（Release 源码包），
  二进制内嵌的构建配置 [`windows_libmpv_build_config.txt`](tool/release/windows_libmpv_build_config.txt)，以及构建仓库在确切提交处的
  上游地址——[`f5a6f87`](https://github.com/media-kit/libmpv-win32-video-build/tree/f5a6f879c9b8bef6a73e52c8c0f35e51636c96e5)
  （构建时的 `master`）与 [`35a3be3`](https://github.com/media-kit/libmpv-win32-video-build/tree/35a3be3cd7b8039ad1a75dd8bf7df08f80532418)
  （归档时的 `master`）。该仓库**没有许可证文件**，所以不收进源码包。
- **计划**：改用自建 / fork 的 LGPL libmpv（`docs/architecture.md` §6.4.6 后续 2），固定所有依赖版本，随 Release 提供完整的对应源码与构建脚本。
  在此之前接受上述“尽力提供”的状态。

| 组件 | 许可证 | 版本 | 源码 |
|---|---|---|---|
| GNU libiconv | LGPL-2.1-or-later | 1.17（推断；二进制中有 GNU libiconv 的字符集表） | https://www.gnu.org/software/libiconv/ |
| libsoxr | LGPL-2.1-or-later | 0.1.3（二进制） | https://sourceforge.net/projects/soxr/ |
| zlib-ng | Zlib | 1.2.13 兼容（二进制版本串，推断为 zlib-ng） | https://github.com/zlib-ng/zlib-ng |
| bzip2 | bzip2-1.0.6 | 1.0.8（推断） | https://sourceware.org/bzip2/ |
| XZ Utils (liblzma) | 0BSD | 未记录 | https://github.com/tukaani-project/xz |
| libjpeg-turbo | IJG AND BSD-3-Clause AND Zlib | 3.0.1（二进制） | https://github.com/libjpeg-turbo/libjpeg-turbo |
| libjxl | BSD-3-Clause（含专利授权） | 未记录 | https://github.com/libjxl/libjxl |
| Brotli | MIT | 未记录 | https://github.com/google/brotli |
| Highway | Apache-2.0 OR BSD-3-Clause | 未记录 | https://github.com/google/highway |
| libwebp | BSD-3-Clause（含专利授权） | 未记录 | https://chromium.googlesource.com/webm/libwebp |
| Speex | BSD-3-Clause | 1.2.1（推断） | https://github.com/xiph/speex |
| libmysofa | BSD-3-Clause | 未记录 | https://github.com/hoene/libmysofa |
| oneVPL (libvpl) | MIT | 未记录 | https://github.com/intel/libvpl |
| libbs2b | MIT | 未记录 | https://github.com/alexmarsev/libbs2b |
| shaderc / SPIRV-Tools | Apache-2.0 | 未记录 | https://github.com/google/shaderc |
| glslang | BSD-3-Clause AND BSD-2-Clause AND MIT AND Apache-2.0 | 未记录 | https://github.com/KhronosGroup/glslang |
| SPIRV-Headers | MIT | 未记录 | https://github.com/KhronosGroup/SPIRV-Headers |
| SPIRV-Cross | Apache-2.0 | 未记录 | https://github.com/KhronosGroup/SPIRV-Cross |
| Little CMS | MIT | 未记录 | https://github.com/mm2/Little-CMS |
| libarchive | BSD-2-Clause | 3.7.3dev（二进制） | https://github.com/libarchive/libarchive |
| libunibreak | Zlib | 未记录 | https://github.com/adah1972/libunibreak |
| MuJS | ISC | 未记录 | https://mujs.com/ |
| zimg | WTFPL | 未记录 | https://github.com/sekrit-twc/zimg |
| AMF headers | MIT | 未记录 | https://github.com/GPUOpen-LibrariesAndSDKs/AMF |
| nv-codec-headers | MIT | 未记录 | https://git.videolan.org/?p=ffmpeg/nv-codec-headers.git |
| mingw-w64 runtime（含 winpthreads） | ZPL-2.1 AND MIT AND BSD-3-Clause | 未记录 | https://www.mingw-w64.org/ |

另有 GCC 运行库（libgcc / libstdc++，GPL-3.0 附 GCC Runtime Library Exception），无署名要求。

## Windows：ANGLE 包与其他原生库

| 文件 | 组件 | 许可证 | 版本 | 源码 |
|---|---|---|---|---|
| `libEGL.dll`、`libGLESv2.dll` | ANGLE | BSD-3-Clause | 2.1.18844，`2693b03eba82a424a19febaacaab4115a45b7682`（版本资源） | https://chromium.googlesource.com/angle/angle |
| `vk_swiftshader.dll` | SwiftShader | Apache-2.0 | 5.0.0（ANGLE 上述提交的依赖） | https://swiftshader.googlesource.com/SwiftShader |
| `vulkan-1.dll` | Vulkan Loader | Apache-2.0 | ANGLE 上述提交的依赖 | https://github.com/KhronosGroup/Vulkan-Loader |
| `zlib.dll` | zlib | Zlib | 1.2.12（二进制） | https://zlib.net/ |
| `WebView2Loader.dll` | Microsoft Edge WebView2 SDK (WebView2Loader.dll) | 微软 BSD-3 风格条款（`assets/licenses/webview2.txt`） | 1.0.3650.58 | **微软闭源组件**，按 SDK 条款以动态库随包再分发，无源码；https://www.nuget.org/packages/Microsoft.Web.WebView2 |
| `flutter_inappwebview_windows_plugin.dll`（头文件库） | Windows Implementation Libraries (WIL)、C++/WinRT、nlohmann/json | MIT | 随插件构建 | https://github.com/microsoft/wil 、https://github.com/microsoft/cppwinrt 、https://github.com/nlohmann/json |

ANGLE 包来自 [alexmercerind/flutter-windows-ANGLE-OpenGL-ES](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES) `v1.0.1`（作者自行编译）。
该包中的 **`d3dcompiler_47.dll`（微软可再分发组件）不随本项目分发**（`windows/CMakeLists.txt` 排除），ANGLE 使用 Windows 自带的同名 DLL。

## 三平台：本项目直接使用的原生库

| 组件 | 许可证 | 版本 | 源码 |
|---|---|---|---|
| QuickJS-ng | MIT | 0.17.0（`qjs` 0.2.3 内置源码） | https://github.com/quickjs-ng/quickjs |
| SQLite | 公有领域（blessing） | 随 `sqlite3` 包（Windows 为 3.54.1） | https://sqlite.org/ |
