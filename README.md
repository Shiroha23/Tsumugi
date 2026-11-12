# Tsumugi

跨平台（Windows / Android / iOS）开源媒体聚合客户端，支持漫画、小说、视频、音乐。

Tsumugi 本身**不提供任何内容**，也不内置任何源。所有内容均由用户自行导入的第三方规则（源）获取，
源的格式见 [docs/source-spec.md](docs/source-spec.md)。

> 状态：早期开发中（M0），尚不可用。

## 开发

需要 Flutter 3.47+（stable）。

```bash
flutter pub get
dart run build_runner build
flutter test
flutter run -d windows
```

架构说明见 [docs/architecture.md](docs/architecture.md)。

## 许可证

本项目以 [GNU General Public License v3.0](LICENSE) 发布。任何分发的修改版本都必须以相同许可证开源。

## 免责声明

本项目仅为技术研究与学习用途的中立工具。用户通过第三方源获取的任何内容与本项目无关，
请遵守所在地法律法规并尊重内容版权方的权利。
