# Tsumugi 原生组件源码包

本包是 Tsumugi 安装包中**原生组件**的对应源码与构建脚本（GPL-3.0 §6、LGPL）。
Tsumugi 自身的源码见 https://github.com/Shiroha23/Tsumugi （与本 Release 同一标签）。

- `native_sources.tsv`：本包每个文件的组件、版本、许可证、原始下载地址与 sha256。
- `windows/`、`android/`、`ios/`、`common/`：按平台存放的源码压缩包（`common/` 为多个平台共用）。
  Android / iOS 构建仓库的存档（`libmpv-*-build-*.tar.gz`）包含构建脚本与补丁。

**Windows**：`libmpv-2.dll` 由 Tsumugi 自建（mpv + FFmpeg 及其全部依赖，均为固定版本的发布包）。
`windows/libmpv-win-<版本>-sources.tar` 是它的完整对应源码：`tarballs/`（全部源码发布包）、`build-scripts/`
（构建脚本 `build.sh` 与带 sha256 的清单 `sources.tsv`，即 https://github.com/Shiroha23/Tsumugi-libmpv 的 `windows/`）与 `BUILD_INFO.txt`
（工具链版本、FFmpeg 配置、mpv 特性、导入的系统 DLL）。在 Ubuntu 24.04 上运行
`build-scripts/build.sh <工作目录> <输出目录>` 即可重新构建（需要的软件包见脚本开头）。脚本优先使用包内的 `tarballs/`；
交叉编译工具链 llvm-mingw 不在包内（它不随产物分发，只有静态链接的运行库随包，其许可证在 `licenses/`），按
`build-scripts/toolchain.tsv` 下载并校验 sha256，离线构建时请预先放入 `<工作目录>/dl/`。

Windows 的 ANGLE 包（`libEGL.dll` 等，来自 media_kit 插件）与版本未知的宽松许可证组件只在仓库的 `THIRD_PARTY_NOTICES.md` 中给出上游地址。
如需其他源码，请在 https://github.com/Shiroha23/Tsumugi/issues 提出。

各组件的许可证全文见安装包内「设置 → 关于 → 第三方许可证」或仓库中的 `assets/licenses/`。
