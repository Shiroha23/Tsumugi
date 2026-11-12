# Tsumugi

跨平台（Windows / Android / iOS）开源媒体聚合客户端，支持漫画、小说、视频、音乐。
内容全部来自用户导入的第三方规则（源），客户端本身是中立的引擎与阅读/播放器。

## 必读文档

- `docs/architecture.md` — 分层、目录结构、技术选型、里程碑
- `docs/source-spec.md` — 源规范（清单格式、声明式规则、JS 宿主 API、仓库格式）

改动涉及架构或源格式时，**先更新对应文档**，再改代码。

## 环境

- Flutter 3.47（stable）/ Dart 3.13，开发机为 Windows
- iOS 只通过 GitHub Actions 的 macOS runner 构建（未签名 IPA）

## 常用命令

```bash
flutter pub get
dart run build_runner build   # freezed / riverpod / drift 代码生成
flutter analyze
flutter test
flutter run -d windows
```

## 约定

- 依赖方向：`features → shared → sources → core`，不可反向；`core` 不依赖 Flutter UI。
- 状态管理用 Riverpod，数据库用 drift，模型用 freezed + json_serializable。
- 新依赖引入前先查 pub.dev 最新稳定版，并确认支持 Windows / Android / iOS。
- 项目许可证为 GPL-3.0。新依赖（含其原生库）的许可证必须与 GPL-3.0 兼容
  （MIT / BSD / Apache-2.0 / LGPL / GPL 可以；专有、SSPL、仅限非商用等不行），不确定时先询问。
- 规则引擎（`lib/core/engine`）的改动必须附带单元测试，测试数据放在 `test/fixtures/`。
- 提交前必须通过 `flutter analyze` 和 `flutter test`。
- 代码注释与提交信息用中文或英文均可，标识符一律英文。

## 红线

- **不在仓库中内置、引用或测试任何真实站点的源。** 测试和示例只使用虚构域名
  （`example.com`）配合 `test/fixtures/` 和 `tool/mock_server/`。
- JS 沙箱只能暴露 `docs/source-spec.md` §4.2 列出的宿主 API；新增 API 必须先改规范并做安全评估。
- 不实现任何自动绕过验证码 / 人机验证的逻辑，只允许让用户在 WebView 中手动完成。
