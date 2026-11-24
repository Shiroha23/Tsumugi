import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 随安装包分发、但不在 Dart 包里的原生组件（architecture §6.4.1）。
///
/// Dart 包与 Flutter 引擎的许可证由 Flutter 自动收集进 [LicenseRegistry]；这里补上
/// libmpv / FFmpeg 及其依赖、ANGLE、WebView2 SDK、QuickJS-ng 等原生库。许可证全文在
/// `assets/licenses/`。版本与来源的核对依据见仓库根目录的 `THIRD_PARTY_NOTICES.md`，
/// 升级 `media_kit_libs_*_video` 时须同步更新本文件、该文档与 `tool/release/native_sources.tsv`。
@immutable
class NativeComponent {
  const NativeComponent({
    required this.name,
    required this.license,
    required this.versions,
    required this.source,
    required this.licenseFiles,
    this.bundledSources = const {},
    this.note,
  });

  /// 在许可证页中显示的名称（也是 [LicenseEntry.packages]）。
  final String name;

  /// SPDX 许可证表达式。
  final String license;

  /// 各平台随包的版本；没有出现的平台不分发该组件。
  final Map<TargetPlatform, String> versions;

  /// 上游源码地址。
  final String source;

  /// 确切版本的源码已收进 Release 源码包（`tool/release/native_sources.tsv`）的平台。
  /// 其他平台只给上游地址。
  final Set<TargetPlatform> bundledSources;

  /// `assets/licenses/` 下的文件名，按顺序拼接为许可证正文。
  final List<String> licenseFiles;

  /// 附加说明（如许可证的选择、署名要求）。
  final String? note;

  bool shippedOn(TargetPlatform platform) => versions.containsKey(platform);
}

const _w = TargetPlatform.windows;
const _a = TargetPlatform.android;
const _i = TargetPlatform.iOS;

const _all = {_w: '', _a: '', _i: ''};
const _wai = {_w, _a, _i};
const _ai = {_a, _i};

const nativeComponents = <NativeComponent>[
  // ---- 本项目 ----
  NativeComponent(
    name: 'Tsumugi',
    license: 'GPL-3.0-or-later',
    versions: _all,
    source: 'https://github.com/Shiroha23/Tsumugi',
    licenseFiles: ['gpl-3.0.txt'],
  ),
  // ---- mpv / FFmpeg ----
  NativeComponent(
    name: 'mpv (libmpv)',
    license: 'LGPL-2.1-or-later',
    versions: {_w: '0.42.0', _a: 'git 78d43740f52d', _i: '0.36.0'},
    source: 'https://github.com/mpv-player/mpv',
    licenseFiles: ['mpv.txt', 'lgpl-2.1.txt'],
    bundledSources: _wai,
    note:
        '以 -Dgpl=false 构建，按 LGPL-2.1-or-later 提供。'
        'Windows 版由本项目自建（Tsumugi-libmpv 仓库），构建脚本收在源码包中。',
  ),
  NativeComponent(
    name: 'FFmpeg',
    license: 'LGPL-3.0-or-later',
    versions: {_w: '8.1.3', _a: 'n6.0', _i: '6.0'},
    source: 'https://ffmpeg.org/',
    licenseFiles: ['ffmpeg.txt', 'lgpl-3.0.txt'],
    bundledSources: _wai,
    note:
        '以 --enable-version3 构建，不含 GPL / nonfree 组件。'
        'Windows 版带本项目的补丁（http 协议不读取环境变量 http_proxy），见源码包。'
        'LGPL-3.0 引用的 GPL-3.0 全文见「Tsumugi」条目。',
  ),
  // ---- libmpv 的依赖（三平台） ----
  NativeComponent(
    name: 'libass',
    license: 'ISC',
    versions: {_w: '0.17.5', _a: '0.17.1', _i: '0.17.1'},
    source: 'https://github.com/libass/libass',
    licenseFiles: ['libass.txt'],
    bundledSources: _wai,
  ),
  NativeComponent(
    name: 'FreeType',
    license: 'FTL OR GPL-2.0-or-later',
    versions: {_w: '2.15.0', _a: '2.13.0', _i: '2.13.2'},
    source: 'https://freetype.org/',
    licenseFiles: ['freetype.txt'],
    bundledSources: _wai,
    note:
        '按 FreeType License (FTL) 使用。Portions of this software are '
        'copyright © The FreeType Project (www.freetype.org). '
        'All rights reserved.',
  ),
  NativeComponent(
    name: 'HarfBuzz',
    license: 'MIT',
    versions: {_w: '15.2.0', _a: '7.2.0', _i: '8.1.1'},
    source: 'https://github.com/harfbuzz/harfbuzz',
    licenseFiles: ['harfbuzz.txt'],
    bundledSources: _wai,
  ),
  NativeComponent(
    name: 'GNU FriBidi',
    license: 'LGPL-2.1-or-later',
    versions: {_w: '1.0.18', _a: '1.0.12', _i: '1.0.13'},
    source: 'https://github.com/fribidi/fribidi',
    licenseFiles: ['lgpl-2.1.txt'],
    bundledSources: _wai,
  ),
  NativeComponent(
    name: 'Mbed TLS',
    license: 'Apache-2.0 OR GPL-2.0-or-later',
    versions: {_a: '3.4.0', _i: '3.4.1'},
    source: 'https://github.com/Mbed-TLS/mbedtls',
    licenseFiles: ['apache-2.0.txt'],
    bundledSources: _ai,
    note: '按 Apache-2.0 使用。',
  ),
  NativeComponent(
    name: 'dav1d',
    license: 'BSD-2-Clause',
    versions: {_w: '1.5.5', _a: '1.2.0', _i: '1.2.1'},
    source: 'https://code.videolan.org/videolan/dav1d',
    licenseFiles: ['dav1d.txt'],
    bundledSources: _wai,
  ),
  NativeComponent(
    name: 'libxml2',
    license: 'MIT',
    versions: {_a: '2.10.3', _i: '2.11.5'},
    source: 'https://gitlab.gnome.org/GNOME/libxml2',
    licenseFiles: ['libxml2.txt'],
    bundledSources: _ai,
  ),
  NativeComponent(
    name: 'uchardet',
    license: 'MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later',
    versions: {_i: '0.0.8'},
    source: 'https://www.freedesktop.org/wiki/Software/uchardet/',
    licenseFiles: ['uchardet.txt'],
    bundledSources: {_i},
    note: '按 LGPL-2.1-or-later 使用。',
  ),
  NativeComponent(
    name: 'libpng',
    license: 'libpng-2.0',
    versions: {_i: '1.6.40'},
    source: 'https://github.com/pnggroup/libpng',
    licenseFiles: ['libpng.txt'],
    bundledSources: {_i},
  ),
  NativeComponent(
    name: 'media-kit-android-helper',
    license: 'MIT',
    versions: {_a: 'git 42054e5d479f'},
    source: 'https://github.com/media-kit/media-kit-android-helper',
    licenseFiles: ['media-kit-android-helper.txt'],
    bundledSources: {_a},
  ),
  // ---- Windows：静态链接进 libmpv-2.dll 的其他依赖（Tsumugi-libmpv 的 windows/sources.tsv） ----
  NativeComponent(
    name: 'libplacebo',
    license: 'LGPL-2.1-or-later',
    versions: {_w: '7.387.0'},
    source: 'https://code.videolan.org/videolan/libplacebo',
    licenseFiles: ['lgpl-2.1.txt'],
    bundledSources: {_w},
  ),
  NativeComponent(
    name: 'glad (OpenGL loader in libplacebo)',
    license: '(WTFPL OR CC0-1.0) AND Apache-2.0',
    versions: {_w: 'git 73db193f853e'},
    source: 'https://github.com/Dav1dde/glad',
    licenseFiles: ['glad.txt', 'apache-2.0.txt'],
    bundledSources: {_w},
    note: 'libplacebo 构建时由 glad 生成的 OpenGL 加载代码；生成器本身不随包分发。',
  ),
  NativeComponent(
    name: 'fast_float',
    license: 'MIT OR Apache-2.0 OR BSL-1.0',
    versions: {_w: 'git 97b54ca9e75f'},
    source: 'https://github.com/fastfloat/fast_float',
    licenseFiles: ['fast_float.txt'],
    bundledSources: {_w},
    note: '按 MIT 使用。',
  ),
  NativeComponent(
    name: 'zlib (libmpv-2.dll)',
    license: 'Zlib',
    versions: {_w: '1.4'},
    source: 'https://zlib.net/',
    licenseFiles: ['zlib.txt'],
    bundledSources: {_w},
  ),
  NativeComponent(
    name: 'mingw-w64 runtime',
    license: 'ZPL-2.1 AND MIT AND BSD-3-Clause',
    versions: {_w: 'llvm-mingw 20261104'},
    source: 'https://www.mingw-w64.org/',
    licenseFiles: ['mingw-w64.txt', 'winpthreads.txt'],
    note: '随交叉编译工具链 llvm-mingw 20261104 提供，静态链接进 libmpv-2.dll。',
  ),
  NativeComponent(
    name: 'LLVM runtime (libc++ / libunwind / compiler-rt)',
    license: 'Apache-2.0 WITH LLVM-exception',
    versions: {_w: 'LLVM 23.1.5（llvm-mingw 20261104）'},
    source: 'https://github.com/llvm/llvm-project',
    licenseFiles: ['llvm-runtime.txt'],
    note: '工具链运行库，静态链接进 libmpv-2.dll（libplacebo / HarfBuzz 的 C++ 代码需要）。',
  ),
  // ---- Windows：ANGLE 包（libEGL / libGLESv2 / vk_swiftshader / vulkan-1 / zlib） ----
  NativeComponent(
    name: 'ANGLE',
    license: 'BSD-3-Clause',
    versions: {_w: '2.1.18844 (2693b03eba82)'},
    source: 'https://chromium.googlesource.com/angle/angle',
    licenseFiles: ['angle.txt'],
  ),
  NativeComponent(
    name: 'SwiftShader',
    license: 'Apache-2.0',
    versions: {_w: '5.0.0'},
    source: 'https://swiftshader.googlesource.com/SwiftShader',
    licenseFiles: ['swiftshader.txt'],
  ),
  NativeComponent(
    name: 'Vulkan Loader',
    license: 'Apache-2.0',
    versions: {_w: 'ANGLE 2693b03eba82 的依赖'},
    source: 'https://github.com/KhronosGroup/Vulkan-Loader',
    licenseFiles: ['vulkan-loader.txt'],
  ),
  NativeComponent(
    name: 'zlib (ANGLE zlib.dll)',
    license: 'Zlib',
    versions: {_w: '1.2.12'},
    source: 'https://zlib.net/',
    licenseFiles: ['zlib.txt'],
  ),
  // ---- Windows：flutter_inappwebview_windows 的原生依赖 ----
  NativeComponent(
    name: 'Microsoft Edge WebView2 SDK (WebView2Loader.dll)',
    license: 'LicenseRef-WebView2-SDK',
    versions: {_w: '1.0.3650.58'},
    source: 'https://www.nuget.org/packages/Microsoft.Web.WebView2',
    licenseFiles: ['webview2.txt'],
    note: '微软闭源组件，按 WebView2 SDK 的条款以动态库随包再分发，无源码。',
  ),
  NativeComponent(
    name: 'Windows Implementation Libraries (WIL)',
    license: 'MIT',
    versions: {_w: ''},
    source: 'https://github.com/microsoft/wil',
    licenseFiles: ['wil.txt'],
  ),
  NativeComponent(
    name: 'C++/WinRT',
    license: 'MIT',
    versions: {_w: ''},
    source: 'https://github.com/microsoft/cppwinrt',
    licenseFiles: ['cppwinrt.txt'],
  ),
  NativeComponent(
    name: 'nlohmann/json',
    license: 'MIT',
    versions: {_w: ''},
    source: 'https://github.com/nlohmann/json',
    licenseFiles: ['nlohmann-json.txt'],
  ),
  // ---- 本项目直接使用的原生库 ----
  NativeComponent(
    name: 'QuickJS-ng',
    license: 'MIT',
    versions: {_w: '0.17.0', _a: '0.17.0', _i: '0.17.0'},
    source: 'https://github.com/quickjs-ng/quickjs',
    licenseFiles: ['quickjs-ng.txt'],
    note: '经 qjs 包从源码构建。',
  ),
  NativeComponent(
    name: 'SQLite',
    license: 'blessing',
    versions: _all,
    source: 'https://sqlite.org/',
    licenseFiles: [],
    note:
        'SQLite 为公有领域软件（https://sqlite.org/copyright.html），'
        '经 sqlite3 包随应用分发。',
  ),
];

/// 当前平台随包的原生组件。
Iterable<NativeComponent> nativeComponentsFor(TargetPlatform platform) =>
    nativeComponents.where((c) => c.shippedOn(platform));

/// 把 [platform] 上随包的原生组件许可证转为 [LicenseEntry]。
Stream<LicenseEntry> nativeLicenseEntries(
  AssetBundle bundle,
  TargetPlatform platform,
) async* {
  for (final c in nativeComponentsFor(platform)) {
    final version = c.versions[platform]!;
    final header = [
      if (version.isNotEmpty) '版本：$version',
      '许可证：${c.license}',
      c.bundledSources.contains(platform)
          ? '源码：${c.source}（该版本的源码收在 Release 的原生组件源码包中）'
          : '源码：${c.source}',
      if (c.note != null) c.note!,
    ].join('\n');
    final texts = [
      header,
      for (final f in c.licenseFiles)
        await bundle.loadString('assets/licenses/$f', cache: false),
    ];
    yield LicenseEntryWithLineBreaks([c.name], texts.join('\n\n'));
  }
}

/// 在应用启动时调用一次，向 [LicenseRegistry] 注册原生组件的许可证。
void registerNativeLicenses() {
  LicenseRegistry.addLicense(
    () => nativeLicenseEntries(rootBundle, defaultTargetPlatform),
  );
}
