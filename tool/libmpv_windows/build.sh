#!/usr/bin/env bash
# 在 Ubuntu 24.04 上用 mingw-w64 交叉编译 Windows x64 的 libmpv-2.dll（LGPL，docs/architecture.md §6.4.6 第 2 项）。
#
# 用法：tool/libmpv_windows/build.sh <工作目录> <输出目录>
#   依赖（apt）：gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix mingw-w64-tools nasm meson ninja-build
#               pkgconf python3 curl xz-utils zip binutils-mingw-w64-x86-64
#
# 只用 sources.tsv 中按 sha256 校验过的发布包；所有依赖静态链接进 libmpv-2.dll（只依赖 Windows 系统 DLL）。
# 输出：
#   <TAG>.zip              libmpv-2.dll、libmpv.dll.a、include/*.h（media_kit 插件期望的扁平布局）、BUILD_INFO.txt
#   <TAG>-sources.tar      对应源码：sources.tsv 中的全部发布包 + 本目录的构建脚本 + BUILD_INFO.txt
#   SHA256SUMS
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mkdir -p "$1" && cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
TAG=$(tr -d '[:space:]' < "$HERE/VERSION")
TRIPLE=x86_64-w64-mingw32
PREFIX=$WORK/prefix
DL=$WORK/dl
SRC=$WORK/src
BUILD=$WORK/build
JOBS=$(nproc)

rm -rf "$SRC" "$BUILD" "$PREFIX"
mkdir -p "$DL" "$SRC" "$BUILD" "$PREFIX"

# ---- 1. 下载并校验 ----
declare -A FILE
while IFS=$'\t' read -r name version license url sha file; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! -f "$DL/$file" ]] || ! echo "$sha  $DL/$file" | sha256sum -c --status -; then
    curl -fsSL --retry 3 --proto '=https' -o "$DL/$file.part" "$url"
    mv "$DL/$file.part" "$DL/$file"
  fi
  echo "$sha  $DL/$file" | sha256sum -c -
  FILE[$name]=$DL/$file
done < "$HERE/sources.tsv"

extract() { # extract <组件> <目标目录>
  mkdir -p "$2"
  tar -xf "${FILE[$1]}" -C "$2" --strip-components=1
}
for name in mpv ffmpeg libplacebo libass freetype harfbuzz fribidi dav1d zlib; do
  extract "$name" "$SRC/$name"
done
for sub in glad jinja markupsafe fast_float; do
  rm -rf "$SRC/libplacebo/3rdparty/$sub"
  extract "$sub" "$SRC/libplacebo/3rdparty/$sub"
done

# ---- 2. 交叉编译环境 ----
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=
export PKG_CONFIG_SYSROOT_DIR=
CROSS=$WORK/cross.txt
cat > "$CROSS" <<EOF
[binaries]
c = '$TRIPLE-gcc-posix'
cpp = '$TRIPLE-g++-posix'
ar = '$TRIPLE-ar'
strip = '$TRIPLE-strip'
windres = '$TRIPLE-windres'
nasm = 'nasm'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-O2', '-D_WIN32_WINNT=0x0A00']
cpp_args = ['-O2', '-D_WIN32_WINNT=0x0A00']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

meson_static() { # meson_static <组件> [选项…]
  local name=$1; shift
  meson setup "$BUILD/$name" "$SRC/$name" --cross-file "$CROSS" --prefix "$PREFIX" --libdir lib \
    --buildtype release -Db_ndebug=true -Ddefault_library=static --wrap-mode=nodownload "$@"
  ninja -C "$BUILD/$name" -j "$JOBS"
  ninja -C "$BUILD/$name" install
}

# ---- 3. 依赖（全部静态库） ----
(
  cd "$SRC/zlib"
  CHOST=$TRIPLE CC=$TRIPLE-gcc-posix ./configure --static --prefix="$PREFIX"
  make -j "$JOBS" libz.a
  make install-libs install-headers 2>/dev/null || make install
)
[[ -f "$PREFIX/lib/pkgconfig/zlib.pc" ]] || { echo 'zlib.pc missing' >&2; exit 1; }

meson_static freetype -Dbrotli=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=system -Dbzip2=disabled \
  -Dtests=disabled
meson_static fribidi -Ddocs=false -Dbin=false -Dtests=false
meson_static harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
  -Dicu=disabled -Dgraphite=disabled -Dfontations=disabled -Dgdi=disabled -Ddirectwrite=disabled \
  -Dcoretext=disabled -Dharfrust=disabled -Dkbts=disabled -Dwasm=disabled -Draster=disabled -Dvector=disabled \
  -Dgpu=disabled -Dgpu_demo=false -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
  -Dutilities=disabled -Dbenchmark=disabled -Dpng=disabled -Dzlib=disabled
meson_static libass -Dfontconfig=disabled -Ddirectwrite=enabled -Dcoretext=disabled -Dasm=enabled \
  -Dlibunibreak=disabled -Drequire-system-font-provider=false -Dtest=disabled -Dcompare=disabled \
  -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled
meson_static dav1d -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false \
  -Dbitdepths="['8','16']"

# ---- 4. FFmpeg（LGPL-2.1+：不加 --enable-gpl / --enable-nonfree / --enable-version3） ----
# 只保留播放需要的部分：协议只有 http / tcp（所有请求经本地媒体代理，见 lib/shared/video/player_options.dart），
# 不带 TLS、不带 DASH（apiVersion 1 不支持）、不带 rtmp / rtsp / udp / file 等。
FF_DECODERS=(
  h264 hevc vp8 vp9 av1 libdav1d mpeg1video mpeg2video mpeg4 h263 h263p flv vp6 vp6a vp6f theora
  msmpeg4v1 msmpeg4v2 msmpeg4v3 wmv1 wmv2 wmv3 vc1 mjpeg png webp bmp
  aac aac_latm ac3 eac3 mp1 mp1float mp2 mp2float mp3 mp3float opus vorbis flac alac dca truehd mlp wmav1 wmav2
  wmapro wavpack pcm_s16le pcm_s16be pcm_s24le pcm_s32le pcm_f32le pcm_u8 pcm_alaw pcm_mulaw
  ass ssa srt subrip webvtt movtext text dvbsub dvdsub pgssub
)
FF_DEMUXERS=(
  hls mpegts mpegtsraw mov matroska flv live_flv avi asf mpegps mpegvideo h264 hevc m4v av1 aac ac3 eac3 mp3
  flac ogg wav w64 latm loas dts dtshd truehd wv webvtt srt ass image2 image_png_pipe image_jpeg_pipe image_webp_pipe
)
FF_PARSERS=(
  h264 hevc vp8 vp9 av1 mpeg4video mpegvideo h263 vc1 mjpeg png webp aac aac_latm ac3 mpegaudio flac opus vorbis
  dca mlp dvbsub dvdsub
)
FF_BSFS=(h264_mp4toannexb hevc_mp4toannexb aac_adtstoasc extract_extradata vp9_superframe_split av1_frame_split
  av1_frame_merge null)
FF_FILTERS=(buffer buffersink abuffer abuffersink format aformat null anull aresample scale)
join() { local IFS=,; echo "$*"; }
mkdir -p "$BUILD/ffmpeg"
FF_CONFIGURE=(
  --prefix="$PREFIX" --arch=x86_64 --target-os=mingw32 --cross-prefix="$TRIPLE-" --enable-cross-compile
  --cc="$TRIPLE-gcc-posix" --cxx="$TRIPLE-g++-posix" --pkg-config=pkg-config --pkg-config-flags=--static
  --enable-static --disable-shared --disable-programs --disable-doc --disable-debug --disable-autodetect
  --disable-everything --disable-avdevice
  --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample --enable-network
  --enable-w32threads --enable-d3d11va --enable-dxva2 --enable-zlib --enable-libdav1d --enable-runtime-cpudetect
  --enable-protocol=http,tcp
  --enable-decoder="$(join "${FF_DECODERS[@]}")"
  --enable-demuxer="$(join "${FF_DEMUXERS[@]}")"
  --enable-parser="$(join "${FF_PARSERS[@]}")"
  --enable-bsf="$(join "${FF_BSFS[@]}")"
  --enable-filter="$(join "${FF_FILTERS[@]}")"
  --enable-hwaccel='*_d3d11va,*_d3d11va2,*_dxva2'
)
(cd "$BUILD/ffmpeg" && "$SRC/ffmpeg/configure" "${FF_CONFIGURE[@]}")
make -C "$BUILD/ffmpeg" -j "$JOBS"
make -C "$BUILD/ffmpeg" install

# ---- 5. libplacebo（mpv 0.37 起必需；只要 OpenGL 后端） ----
meson_static libplacebo -Dvulkan=disabled -Dvk-proc-addr=disabled -Dopengl=enabled -Dgl-proc-addr=disabled \
  -Dd3d11=disabled -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled -Ddovi=enabled -Dlibdovi=disabled \
  -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false -Dunwind=disabled -Dxxhash=disabled

# libplacebo / HarfBuzz 含 C++ 代码，而 mpv 用 C 编译器链接：静态链接时需要显式带上 libstdc++。
for pc in libplacebo harfbuzz; do
  grep -q -- '-lstdc++' "$PREFIX/lib/pkgconfig/$pc.pc" ||
    sed -i 's/^Libs.private:/Libs.private: -lstdc++/; t; $a Libs.private: -lstdc++' "$PREFIX/lib/pkgconfig/$pc.pc"
done

# ---- 6. mpv → libmpv-2.dll ----
# --auto-features=disabled：只开下面显式列出的特性（不带 lua / javascript / libarchive / 光盘 / 网络库等）。
meson setup "$BUILD/mpv" "$SRC/mpv" --cross-file "$CROSS" --prefix "$PREFIX" --libdir lib \
  --buildtype release -Db_ndebug=true -Ddefault_library=shared -Dprefer_static=true --wrap-mode=nodownload \
  --auto-features=disabled -Dgpl=false -Dcplayer=false -Dlibmpv=true -Dbuild-date=false -Dtests=false \
  -Dgl=enabled -Dplain-gl=enabled -Dd3d-hwaccel=enabled -Dwasapi=enabled -Dwin32-threads=enabled \
  -Dzlib=enabled -Dvector=enabled \
  -Dc_link_args="['-static', '-static-libgcc', '-static-libstdc++', '-Wl,--gc-sections']" \
  -Dcpp_link_args="['-static', '-static-libgcc', '-static-libstdc++', '-Wl,--gc-sections']"
ninja -C "$BUILD/mpv" -j "$JOBS"
ninja -C "$BUILD/mpv" install

# ---- 7. 检查与打包 ----
DLL=$PREFIX/bin/libmpv-2.dll
IMPLIB=$PREFIX/lib/libmpv.dll.a
[[ -f "$DLL" && -f "$IMPLIB" ]] || { echo 'libmpv-2.dll / libmpv.dll.a missing' >&2; exit 1; }
"$TRIPLE-strip" --strip-unneeded "$DLL"

# 许可证门禁：FFmpeg 必须是 LGPL，且没有 GPL / nonfree 组件。
strings "$DLL" > "$WORK/strings.txt"
grep -q 'LGPL version 2.1 or later' "$WORK/strings.txt" || { echo 'FFmpeg license string not LGPL' >&2; exit 1; }
if grep -E -- '--enable-(gpl|nonfree|version3)' "$WORK/strings.txt"; then
  echo 'FFmpeg configured with GPL / nonfree / version3' >&2; exit 1
fi
python3 -"$BUILD/mpv/meson-info/intro-buildoptions.json" <<'PY'
import json, sys
opts = {o["name"]: o["value"] for o in json.load(open(sys.argv[1]))}
if opts.get("gpl") is not False:
    sys.exit("mpv gpl option is not false")
PY

# 只允许依赖 Windows 系统 DLL（全部第三方组件都应静态链接）。
"$TRIPLE-objdump" -p "$DLL" | awk '/DLL Name:/ {print tolower($3)}' | sort -u > "$WORK/imports.txt"
SYSTEM_DLLS='^(kernel32|user32|gdi32|advapi32|shell32|ole32|oleaut32|shlwapi|ws2_32|bcrypt|avrt|winmm|dwrite|d3d11|dxgi|d3d9|dxva2|uuid|version|secur32|ntdll|msvcrt|api-ms-win-[a-z0-9-]+|ucrtbase|mfplat|mfuuid|strmiids|propsys|imm32|comdlg32|uxtheme|dwmapi|powrprof|setupapi|cfgmgr32|opengl32|pathcch)\.dll$'
if grep -v -E "$SYSTEM_DLLS" "$WORK/imports.txt"; then
  echo 'libmpv-2.dll imports non-system DLLs (listed above)' >&2; exit 1
fi

PKG=$WORK/pkg/$TAG
rm -rf "$WORK/pkg"; mkdir -p "$PKG/include"
cp "$DLL" "$IMPLIB" "$PKG/"
cp "$PREFIX"/include/mpv/*.h "$PKG/include/"
{
  echo "# $TAG"
  echo "# 由 Tsumugi 的 tool/libmpv_windows/build.sh 构建（docs/architecture.md §6.4.6 第 2 项）。"
  echo
  echo "## 源码（sources.tsv）"
  grep -v '^#' "$HERE/sources.tsv"
  echo
  echo "## 工具链"
  dpkg-query -W -f '${Package} ${Version}\n' gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
    mingw-w64-common mingw-w64-x86-64-dev binutils-mingw-w64-x86-64 nasm meson ninja-build 2>/dev/null || true
  echo
  echo "## FFmpeg configure"
  printf '%q ' "${FF_CONFIGURE[@]}" | sed "s#$PREFIX#<prefix>#g"
  echo
  echo
  echo "## mpv 特性"
  python3 - "$BUILD/mpv/meson-info/intro-buildoptions.json" <<'PY'
import json, sys
for o in json.load(open(sys.argv[1])):
    if o["section"] == "user":
        print(f'{o["name"]}={o["value"]}')
PY
  echo
  echo "## libmpv-2.dll 导入的 DLL"
  cat "$WORK/imports.txt"
} > "$PKG/BUILD_INFO.txt"

rm -f "$OUT/$TAG.zip" "$OUT/$TAG-sources.tar"
(cd "$WORK/pkg" && zip -qr -X "$OUT/$TAG.zip" "$TAG")

SRCPKG=$WORK/srcpkg/$TAG-sources
rm -rf "$WORK/srcpkg"; mkdir -p "$SRCPKG/tarballs" "$SRCPKG/build-scripts"
while IFS=$'\t' read -r name version license url sha file; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  cp "$DL/$file" "$SRCPKG/tarballs/"
done < "$HERE/sources.tsv"
cp "$HERE"/* "$SRCPKG/build-scripts/"
cp "$PKG/BUILD_INFO.txt" "$SRCPKG/"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
  -cf "$OUT/$TAG-sources.tar" -C "$WORK/srcpkg" "$TAG-sources"

(cd "$OUT" && sha256sum "$TAG.zip" "$TAG-sources.tar" > SHA256SUMS && cat SHA256SUMS)
ls -l "$DLL" "$OUT"
