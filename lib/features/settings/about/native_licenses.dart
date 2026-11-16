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

/// Windows libmpv 构建时多数依赖取 git 最新提交，确切版本没有记录（architecture §6.4.1）。
const _unrecorded = 'git 快照（确切版本未记录）';

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
    versions: {
      _w: 'v0.36.0-403-g652a1dd907',
      _a: 'git 78d43740f52d',
      _i: '0.36.0',
    },
    source: 'https://github.com/mpv-player/mpv',
    licenseFiles: ['mpv.txt', 'lgpl-2.1.txt'],
    bundledSources: _wai,
    note: '以 -Dgpl=false 构建，按 LGPL-2.1-or-later 提供。',
  ),
  NativeComponent(
    name: 'FFmpeg',
    license: 'LGPL-3.0-or-later',
    versions: {_w: 'n6.0', _a: 'n6.0', _i: '6.0'},
    source: 'https://ffmpeg.org/',
    licenseFiles: ['ffmpeg.txt', 'lgpl-3.0.txt'],
    bundledSources: _wai,
    note:
        '以 --disable-gpl --disable-nonfree --enable-version3 构建。'
        'LGPL-3.0 引用的 GPL-3.0 全文见「Tsumugi」条目。',
  ),
  // ---- libmpv 的依赖（三平台） ----
  NativeComponent(
    name: 'libass',
    license: 'ISC',
    versions: {_w: _unrecorded, _a: '0.17.1', _i: '0.17.1'},
    source: 'https://github.com/libass/libass',
    licenseFiles: ['libass.txt'],
    bundledSources: _ai,
  ),
  NativeComponent(
    name: 'FreeType',
    license: 'FTL OR GPL-2.0-or-later',
    versions: {_w: _unrecorded, _a: '2.13.0', _i: '2.13.2'},
    source: 'https://freetype.org/',
    licenseFiles: ['freetype.txt'],
    bundledSources: _ai,
    note:
        '按 FreeType License (FTL) 使用。Portions of this software are '
        'copyright © The FreeType Project (www.freetype.org). '
        'All rights reserved.',
  ),
  NativeComponent(
    name: 'HarfBuzz',
    license: 'MIT',
    versions: {_w: _unrecorded, _a: '7.2.0', _i: '8.1.1'},
    source: 'https://github.com/harfbuzz/harfbuzz',
    licenseFiles: ['harfbuzz.txt'],
    bundledSources: _ai,
  ),
  NativeComponent(
    name: 'GNU FriBidi',
    license: 'LGPL-2.1-or-later',
    versions: {_w: '1.0.13', _a: '1.0.12', _i: '1.0.13'},
    source: 'https://github.com/fribidi/fribidi',
    licenseFiles: ['lgpl-2.1.txt'],
    bundledSources: _wai,
  ),
  NativeComponent(
    name: 'Mbed TLS',
    license: 'Apache-2.0 OR GPL-2.0-or-later',
    versions: {_w: '3.4.1（推断）', _a: '3.4.0', _i: '3.4.1'},
    source: 'https://github.com/Mbed-TLS/mbedtls',
    licenseFiles: ['apache-2.0.txt'],
    bundledSources: _ai,
    note: '按 Apache-2.0 使用。',
  ),
  NativeComponent(
    name: 'dav1d',
    license: 'BSD-2-Clause',
    versions: {_w: '1.2.1-48-g769bd14（推断）', _a: '1.2.0', _i: '1.2.1'},
    source: 'https://code.videolan.org/videolan/dav1d',
    licenseFiles: ['dav1d.txt'],
    bundledSources: _ai,
  ),
  NativeComponent(
    name: 'libxml2',
    license: 'MIT',
    versions: {_w: _unrecorded, _a: '2.10.3', _i: '2.11.5'},
    source: 'https://gitlab.gnome.org/GNOME/libxml2',
    licenseFiles: ['libxml2.txt'],
    bundledSources: _ai,
  ),
  NativeComponent(
    name: 'uchardet',
    license: 'MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later',
    versions: {_w: _unrecorded, _i: '0.0.8'},
    source: 'https://www.freedesktop.org/wiki/Software/uchardet/',
    licenseFiles: ['uchardet.txt'],
    bundledSources: {_i},
    note: '按 LGPL-2.1-or-later 使用。',
  ),
  NativeComponent(
    name: 'libpng',
    license: 'libpng-2.0',
    versions: {_w: '1.6.41.git', _i: '1.6.40'},
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
  // ---- Windows：静态链接进 libmpv-2.dll 的其他依赖 ----
  NativeComponent(
    name: 'GNU libiconv',
    license: 'LGPL-2.1-or-later',
    versions: {_w: '1.17（推断）'},
    source: 'https://www.gnu.org/software/libiconv/',
    licenseFiles: ['lgpl-2.1.txt'],
    bundledSources: {_w},
  ),
  NativeComponent(
    name: 'libsoxr',
    license: 'LGPL-2.1-or-later',
    versions: {_w: '0.1.3'},
    source: 'https://sourceforge.net/projects/soxr/',
    licenseFiles: ['libsoxr.txt', 'lgpl-2.1.txt'],
    bundledSources: {_w},
  ),
  NativeComponent(
    name: 'zlib-ng',
    license: 'Zlib',
    versions: {_w: '1.2.13 兼容（推断）'},
    source: 'https://github.com/zlib-ng/zlib-ng',
    licenseFiles: ['zlib-ng.txt'],
  ),
  NativeComponent(
    name: 'bzip2',
    license: 'bzip2-1.0.6',
    versions: {_w: '1.0.8（推断）'},
    source: 'https://sourceware.org/bzip2/',
    licenseFiles: ['bzip2.txt'],
  ),
  NativeComponent(
    name: 'XZ Utils (liblzma)',
    license: '0BSD',
    versions: {_w: _unrecorded},
    source: 'https://github.com/tukaani-project/xz',
    licenseFiles: ['xz.txt'],
  ),
  NativeComponent(
    name: 'libjpeg-turbo',
    license: 'IJG AND BSD-3-Clause AND Zlib',
    versions: {_w: '3.0.1'},
    source: 'https://github.com/libjpeg-turbo/libjpeg-turbo',
    licenseFiles: ['libjpeg-turbo.txt'],
    note:
        'This software is based in part on the work of the Independent '
        'JPEG Group.',
  ),
  NativeComponent(
    name: 'libjxl',
    license: 'BSD-3-Clause',
    versions: {_w: _unrecorded},
    source: 'https://github.com/libjxl/libjxl',
    licenseFiles: ['libjxl.txt', 'libjxl-patents.txt'],
  ),
  NativeComponent(
    name: 'Brotli',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://github.com/google/brotli',
    licenseFiles: ['brotli.txt'],
  ),
  NativeComponent(
    name: 'Highway',
    license: 'Apache-2.0 OR BSD-3-Clause',
    versions: {_w: _unrecorded},
    source: 'https://github.com/google/highway',
    licenseFiles: ['highway.txt'],
  ),
  NativeComponent(
    name: 'libwebp',
    license: 'BSD-3-Clause',
    versions: {_w: _unrecorded},
    source: 'https://chromium.googlesource.com/webm/libwebp',
    licenseFiles: ['libwebp.txt', 'libwebp-patents.txt'],
  ),
  NativeComponent(
    name: 'Speex',
    license: 'BSD-3-Clause',
    versions: {_w: '1.2.1（推断）'},
    source: 'https://github.com/xiph/speex',
    licenseFiles: ['speex.txt'],
  ),
  NativeComponent(
    name: 'libmysofa',
    license: 'BSD-3-Clause',
    versions: {_w: _unrecorded},
    source: 'https://github.com/hoene/libmysofa',
    licenseFiles: ['libmysofa.txt'],
  ),
  NativeComponent(
    name: 'oneVPL (libvpl)',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://github.com/intel/libvpl',
    licenseFiles: ['libvpl.txt'],
  ),
  NativeComponent(
    name: 'libbs2b',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://github.com/alexmarsev/libbs2b',
    licenseFiles: ['libbs2b.txt'],
  ),
  NativeComponent(
    name: 'shaderc / SPIRV-Tools',
    license: 'Apache-2.0',
    versions: {_w: _unrecorded},
    source: 'https://github.com/google/shaderc',
    licenseFiles: ['apache-2.0.txt'],
  ),
  NativeComponent(
    name: 'glslang',
    license: 'BSD-3-Clause AND BSD-2-Clause AND MIT AND Apache-2.0',
    versions: {_w: _unrecorded},
    source: 'https://github.com/KhronosGroup/glslang',
    licenseFiles: ['glslang.txt'],
  ),
  NativeComponent(
    name: 'SPIRV-Headers',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://github.com/KhronosGroup/SPIRV-Headers',
    licenseFiles: ['spirv-headers.txt'],
  ),
  NativeComponent(
    name: 'SPIRV-Cross',
    license: 'Apache-2.0',
    versions: {_w: _unrecorded},
    source: 'https://github.com/KhronosGroup/SPIRV-Cross',
    licenseFiles: ['apache-2.0.txt'],
  ),
  NativeComponent(
    name: 'Little CMS',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://github.com/mm2/Little-CMS',
    licenseFiles: ['lcms2.txt'],
  ),
  NativeComponent(
    name: 'libarchive',
    license: 'BSD-2-Clause',
    versions: {_w: '3.7.3dev'},
    source: 'https://github.com/libarchive/libarchive',
    licenseFiles: ['libarchive.txt'],
  ),
  NativeComponent(
    name: 'libunibreak',
    license: 'Zlib',
    versions: {_w: _unrecorded},
    source: 'https://github.com/adah1972/libunibreak',
    licenseFiles: ['libunibreak.txt'],
  ),
  NativeComponent(
    name: 'MuJS',
    license: 'ISC',
    versions: {_w: _unrecorded},
    source: 'https://mujs.com/',
    licenseFiles: ['mujs.txt'],
  ),
  NativeComponent(
    name: 'zimg',
    license: 'WTFPL',
    versions: {_w: _unrecorded},
    source: 'https://github.com/sekrit-twc/zimg',
    licenseFiles: ['zimg.txt'],
  ),
  NativeComponent(
    name: 'AMF headers',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://github.com/GPUOpen-LibrariesAndSDKs/AMF',
    licenseFiles: ['amf.txt'],
  ),
  NativeComponent(
    name: 'nv-codec-headers',
    license: 'MIT',
    versions: {_w: _unrecorded},
    source: 'https://git.videolan.org/?p=ffmpeg/nv-codec-headers.git',
    licenseFiles: ['nv-codec-headers.txt'],
  ),
  NativeComponent(
    name: 'mingw-w64 runtime',
    license: 'ZPL-2.1 AND MIT AND BSD-3-Clause',
    versions: {_w: _unrecorded},
    source: 'https://www.mingw-w64.org/',
    licenseFiles: ['mingw-w64.txt', 'winpthreads.txt'],
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
    name: 'zlib',
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
    note: '微软提供的二进制，无源码（architecture §6.4.6）。',
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
