# Tsumugi 架构设计（草案）

> 状态：草案，待评审。任何与此文档冲突的实现都应先更新此文档。

## 1. 目标与非目标

**目标**

- 一个跨平台（Windows / Android / iOS，后续可扩展 macOS / Linux）的媒体聚合客户端。
- 支持四种媒体：漫画（comic）、小说（novel）、视频（video）、音乐（music）。
- 内容全部来自用户导入的**第三方规则（源）**，客户端本身只是中立的引擎与阅读/播放器。
- 本地优先：书架、进度、历史、下载均存于本地，可选 WebDAV 同步。

**非目标**

- 不内置、不推荐、不托管任何真实站点的源。
- 不做 DRM 破解。
- 不提供账号体系 / 云服务。

## 2. 技术选型

| 领域 | 选型 | 备注 |
|---|---|---|
| 框架 | Flutter（stable） | 当前开发环境 Flutter 3.47 / Dart 3.13 |
| 状态管理 | Riverpod（含代码生成） | |
| 路由 | go_router | |
| 网络 | dio + cookie_jar | 每个源独立 Cookie 域与拦截器 |
| HTML 解析 | `html`（CSS 选择器） + XPath 库 | XPath 库选型待验证 |
| JSON 路径 | JSONPath 实现库 | 选型待验证 |
| JS 运行时 | QuickJS 绑定 | 需验证三平台可用性，见 §6 风险 |
| 数据库 | drift（SQLite） | |
| 音视频 | media_kit（libmpv） | 视频与音乐共用 |
| WebView | flutter_inappwebview | 用于登录 / 人机验证兜底 |
| 序列化 | freezed + json_serializable | |

依赖版本在引入时以 pub.dev 最新稳定版为准，并锁定在 `pubspec.lock`。

## 3. 分层

```
┌──────────────────────────────────────────────┐
│ features/  (UI：comic / novel / video / music │
│            / library / sources / settings)   │
├──────────────────────────────────────────────┤
│ shared/    (书架、历史、下载、同步 等跨媒体服务)  │
├──────────────────────────────────────────────┤
│ sources/   (源接口、源管理、仓库订阅)            │
├──────────────────────────────────────────────┤
│ core/      (规则引擎、JS 运行时、网络、存储、日志) │
└──────────────────────────────────────────────┘
```

依赖方向只能**自上而下**：`features → shared → sources → core`。
`core` 不得依赖 Flutter UI（便于纯 Dart 单元测试）。

## 4. 目录结构

```
lib/
  main.dart
  app/                    # App 根、路由、主题
  core/
    engine/
      declarative/        # 声明式规则解析与执行
      script/             # JS 运行时、宿主 API 绑定、沙箱
      expression/         # 选择器表达式（css/xpath/json/regex）
    network/              # HttpClient、Cookie、限速、重试、日志
    storage/              # drift 数据库、KV 存储
    logging/
  sources/
    model/                # Source 清单、SearchItem、Detail、Content…
    source.dart           # 统一 Source 抽象接口
    registry/             # 已安装源管理、启用/禁用、排序
    repository/           # 规则仓库订阅、更新、校验
  shared/
    library/              # 书架
    history/              # 历史与进度
    download/             # 下载管理
    sync/                 # WebDAV 同步
  features/
    comic/  novel/  video/  music/
    library/  sources/  settings/  search/
test/
  fixtures/               # mock 页面与示例源（仅虚构站点）
  core/  sources/  shared/
tool/
  mock_server/            # 本地 mock HTTP 服务，供测试与规则调试
docs/
```

## 5. 关键流程

### 5.1 搜索

```
UI(search) → SourceRegistry.enabled(type?) → 并发调用 source.search()
          → 结果按源分组流式返回（Stream），单源超时/失败不影响其他源
```

### 5.2 打开内容

```
detail(id) → 章节/剧集/曲目列表 → content(itemId)
  comic : List<ImageRef(url, headers)> → 图片加载器（带 headers 与缓存）
  novel : 文本（可分页）             → 排版引擎
  video : StreamRef(url, headers, type) → media_kit
  music : StreamRef + 可选歌词        → media_kit + 后台播放服务
```

### 5.3 人机验证 / 登录

网络层检测到挑战（如 403/503 + 特征）或源脚本主动请求时，弹出 WebView 让**用户手动**完成，
完成后将 Cookie 回写到该源的 Cookie 域并重试请求。客户端不自动破解验证码。

## 6. 风险与待验证项

1. **QuickJS 绑定的跨平台可用性**（Windows / iOS 尤其）。MVP 前先做技术验证；备选方案：
   iOS 用 JavaScriptCore，其他平台用 QuickJS，在 `core/engine/script` 抽象出统一接口。
2. **iOS 分发**：无法上架 App Store，CI 产出未签名 IPA，用户自签。
3. **音乐后台播放**：需要各平台的媒体会话适配（Android 前台服务、iOS AVAudioSession、Windows SMTC）。
4. **XPath / JSONPath 库质量**：需用 fixtures 做兼容性测试。

## 7. 里程碑

| 阶段 | 内容 |
|---|---|
| M0 | 项目骨架、CI（三平台构建 + 测试）、JS 运行时技术验证 |
| M1 | 核心：网络层、声明式规则引擎、JS 沙箱、源管理、mock 服务器 |
| M2 | 漫画 MVP：搜索、详情、阅读器、书架、历史 |
| M3 | 小说：阅读器、排版、导出 |
| M4 | 视频：media_kit 播放器、选集、倍速、进度记忆 |
| M5 | 音乐：播放列表、后台播放、歌词 |
| M6 | 下载管理、WebDAV 同步、规则仓库订阅 |

## 8. 安全原则

- 源脚本运行在沙箱中，只能使用 `docs/source-spec.md` 定义的宿主 API。
- 禁止脚本访问文件系统、其他源的存储与 Cookie、任意原生能力。
- 单次脚本调用有 CPU 时间与内存上限，超时强制终止。
- 安装来自仓库的源时校验 sha256；安装/更新时向用户展示源的请求域名。
