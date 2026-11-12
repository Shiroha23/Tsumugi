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
| JS 运行时 | [`qjs`](https://pub.dev/packages/qjs)（QuickJS-ng，MIT） | M0 已验证，三平台同一引擎；封装在 `core/engine/script`，见 §6.1 |
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

1. **QuickJS 绑定的跨平台可用性** —— M0 已完成验证，结论见 §6.1。
2. **iOS 分发**：无法上架 App Store，CI 产出未签名 IPA，用户自签。
3. **音乐后台播放**：需要各平台的媒体会话适配（Android 前台服务、iOS AVAudioSession、Windows SMTC）。
4. **XPath / JSONPath 库质量**：需用 fixtures 做兼容性测试。

### 6.1 JS 运行时选型结论（M0，2026-11）

**结论：三平台统一使用 [`qjs`](https://pub.dev/packages/qjs) 0.2.x（QuickJS-ng 0.17），暂不需要 iOS 的
JavaScriptCore 备选。** 规则引擎只依赖 `lib/core/engine/script/script_runtime.dart` 中的 `ScriptRuntime`
接口，实现为 `QuickJsScriptRuntime`；将来若需更换引擎只替换实现。

候选对比（2026-11 调研 pub.dev / GitHub）：

| 包 | 引擎 | Win / Android / iOS | 许可证 | Promise ⇄ Future | 内存上限 | 执行中断 | `flutter test` 可直接跑 | 活跃度 |
|---|---|---|---|---|---|---|---|---|
| **qjs** ✅ | QuickJS-ng 0.17（C，FFI） | ✓ / ✓ / ✓ | MIT | ✓ 双向 | ✓ | ✓ deadline + 跨 isolate 中断句柄 | ✓（Dart build hooks） | 2026-11 仍在发版；单人维护 |
| fjs | rquickjs（Rust，FRB） | ✓ / ✓ / ✓ | MIT | ✓ | ✓ | 有，较间接 | ✗ 需 Rust 工具链 / 预编译产物 | 活跃，114★；README 声明不面向不可信脚本 |
| flutter_js | Android/Win QuickJS，iOS **JSC** | ✓ / ✓ / ✓ | MIT | ✓ | iOS 不支持 | ✗ | ✗ 需手动构建 dll 并设 PATH | 2026-01 后未发版，80 个未结 issue |
| flutter_qjs_next | QuickJS（FFI 插件） | ✓ / ✓ / ✓ | MIT | ✓ | ✓ | ✓ 墙钟超时 | ✗ 需先构建插件 | 活跃，单人维护 |
| jsf | QuickJS（FFI 插件） | ✓ / ✓ / ✓ | MIT | ✓ | ✓ | 仅同步执行超时 | ✗ 需先构建插件 | 活跃 |
| flutter_qjs | QuickJS（旧版） | ✓ / ✓ / ✓ | MIT | ✓ | ✗ | ✗ | ✗ | pub 上自 2022 未发版 |
| quickjs_runtime | QuickJS 2024-01 | ✓ / ✓ / ✓ | MIT | ✗ 仅同步宿主回调 | — | ✗ 无超时 | ✓ | 活跃 |

选 `qjs` 的理由：

- 唯一同时满足“宿主异步函数返回 Promise”“内存上限”“不可被脚本 catch 的执行中断”的候选，
  且三平台是**同一个引擎**，脚本行为一致，避免 JSC/QuickJS 双实现的差异与双倍测试。
- 原生库经 Dart build hooks（native assets）构建，`flutter test` / `dart test` 在任何开发机与
  CI 上直接可用，无需额外的插件构建步骤；Windows release 包会自动带上 `qjs_dart.dll`。
- 支持 ES 模块求值且默认禁用 `import`、可关闭 `eval` / `Function`，适合沙箱。
- MIT，与 GPL-3.0 兼容；QuickJS-ng 本身为 MIT。

验证范围（`test/core/engine/script/quickjs_script_runtime_test.dart`）：调用 ES 模块导出的 async 函数、
宿主异步函数往返（含错误码透传）、同步宿主函数、死循环超时中断（含脚本内 try/catch、await 之后）、
CPU 预算跨 await 累计、总时长上限、内存上限、栈上限、超限后运行时可继续使用、沙箱全局对象检查。
本机（Windows）`flutter test` 与 `flutter build windows --release` 通过；Android / iOS 由 CI 构建验证。

实现要点：

- **CPU 时间**：每次进入 JS（调用导出、resolve 宿主 Promise）前按本次调用的剩余 CPU 预算设置
  QuickJS 中断 deadline，退出时累计耗时；等待宿主 Future 的时间不计入。超限 → `E_LIMIT`。
- **总时长**：Dart 侧计时器，超时即让本次调用失败（`E_LIMIT`），之后到达的宿主结果被丢弃。
- **内存 / 栈**：`JSRuntimeConfig.memoryLimit` / `maxStackSize`，超限 → `E_LIMIT`。
- **值传递**：跨边界只传 JSON 兼容值（JS 侧用初始化时缓存的 `JSON.stringify`）。
- 宿主对象 `tsumugi` 在注入后冻结。

已知限制与后续工作：

- **JS 在调用方 isolate 上同步执行**，长计算会卡住该 isolate。M1 接入时把每个源的运行时放进
  worker isolate（`qjs` 提供可跨 isolate 发送的中断句柄）；`ScriptRuntime` 接口已全部异步，无需改动调用方。
- 同一运行时上的调用**串行执行**（宿主 Promise 需要归属到具体调用）。如需单源并发，可按调用开多个运行时。
- 源脚本**不支持顶层 await**（模块同步求值）；已写入 source-spec §4.1。
- 移动端只验证到“能编译打包”，真机 / 模拟器上的运行时加载尚未自动化验证，M1 加 integration test。
- `qjs` 的 build hook 默认从其 GitHub Release 下载预编译库（sha256 写死在包内并校验），失败时回落到
  本地用 `native_toolchain_c` 编译源码。需要可复现构建时可在 M1 评估改为强制源码编译。
- `qjs` 为单人维护的新库（风险：维护中断）。缓解：引擎细节全部隔离在 `QuickJsScriptRuntime` 一个文件内，
  其 C 桥接层很薄，必要时可 fork；fjs 作为第二候选。

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
