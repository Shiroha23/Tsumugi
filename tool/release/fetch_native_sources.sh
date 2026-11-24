#!/usr/bin/env bash
# 下载 native_sources.tsv 中列出的原生组件源码与构建脚本，按 sha256 校验，
# 打包为一个 tar（各文件本身已压缩，不再压缩）。供 Release 工作流上传（GPL-3.0 §6）。
#
# 用法：tool/release/fetch_native_sources.sh <输出目录> [包名]
#   --print-hashes：只下载并打印每个文件的 sha256 与大小，不校验（更新清单时用）。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/native_sources.tsv"

print_hashes=false
if [ "${1:-}" = "--print-hashes" ]; then
  print_hashes=true
  shift
fi

out="${1:?usage: fetch_native_sources.sh [--print-hashes] <out-dir> [bundle-name]}"
name="${2:-tsumugi-native-sources}"
stage="$out/$name"
mkdir -p "$stage"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

failed=0
declare -A seen=()
while IFS=$'\t' read -r platforms component version license url expected file; do
  case "$platforms" in ''|'#'*) continue ;; esac
  dest="$stage/$file"
  if [ -n "${seen[$file]:-}" ]; then
    continue
  fi
  seen[$file]=1
  mkdir -p "$(dirname "$dest")"
  if [ ! -s "$dest" ]; then
    echo "→ $component $version ($platforms): $url"
    curl -fsSL --retry 3 --retry-delay 5 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  actual="$(sha256 "$dest")"
  size="$(wc -c <"$dest" | tr -d ' ')"
  if $print_hashes; then
    printf '%s\t%s\t%s\n' "$actual" "$size" "$file"
  elif [ "$actual" != "$expected" ]; then
    echo "✗ sha256 mismatch: $file" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    failed=1
  fi
done <"$manifest"

[ "$failed" = 0 ] || exit 1
$print_hashes && exit 0

cp "$manifest" "$stage/"
cp "$here/SOURCES_README.md" "$stage/README.md"

tar -C "$out" -cf "$out/$name.tar" "$name"
# 标准格式“哈希  文件名”，可直接 `sha256sum -c` 校验。
(cd "$out" && printf '%s  %s\n' "$(sha256 "$name.tar")" "$name.tar" >"$name.tar.sha256")
du -sh "$out/$name.tar"
