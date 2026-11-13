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
| HTML 解析 | `html`（CSS 选择器） + [`xml`](https://pub.dev/packages/xml)（XPath，MIT） | M1 选定，见 §6 风险 4 |
| JSON 路径 | [`json_path`](https://pub.dev/packages/json_path)（RFC 9535，MIT） | M1 选定，见 §6 风险 4 |
| JS 运行时 | [`qjs`](https://pub.dev/packages/qjs)（QuickJS-ng，MIT） | M0 已验证，三平台同一引擎；封装在 `core/engine/script`，见 §6.1 |
| 加密 | [`crypto`](https://pub.dev/packages/crypto)（BSD-3）+ [`pointycastle`](https://pub.dev/packages/pointycastle)（MIT） | 纯 Dart；`tsumugi.crypto` 的摘要 / HMAC 与 AES（CBC / ECB / GCM） |
| 数据库 | drift（SQLite） | |
| 音视频 | media_kit（libmpv） | 视频与音乐共用 |
| WebView | [`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview) 6.2.0-beta.3（Apache-2.0） | M3 选定：登录 / 人机验证（用户手动完成），见 §5.3 |
| 序列化 | freezed + json_serializable | |
| 压缩 / ZIP | [`archive`](https://pub.dev/packages/archive)（MIT） | M3 选定：生成 EPUB（OCF ZIP 容器），纯 Dart，三平台一致，见 §5.2「小说导出」 |
| 文件选择 / 保存 | [`file_picker`](https://pub.dev/packages/file_picker)（MIT） | M1 导入清单；M3 起 `saveFile` 用于保存导出文件 |

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
      script/             # JS 运行时（QuickJS、worker isolate）、沙箱
        host/             # worker 内的宿主 API（crypto、HTML 句柄）与 tsumugi prelude
      expression/         # 选择器表达式（css/xpath/json/regex）
    network/              # HttpClient、Cookie、限速、重试、日志
    storage/              # drift 数据库、KV 存储
    logging/
  sources/
    model/                # Source 清单、SearchItem、Detail、Content…
    source.dart           # 统一 Source 抽象接口
    declarative/          # engine=declarative 的 Source
    script/               # engine=script 的 Source、主 isolate 宿主 API、工厂
    registry/             # 已安装源管理、启用/禁用、排序
    runtime/              # 按 sourceId 缓存可运行的 Source 实例；错误码 → 中文提示
    repository/           # 规则仓库订阅、更新、校验
  shared/
    library/              # 书架
    history/              # 历史与进度
    image/                # 统一图片加载（M2）
    novel/                # 小说正文模型、HTML 白名单清洗、章节内分页拼接（阅读器与导出共用）
    export/               # 小说导出 TXT / EPUB（M3）
    webview/              # 人机验证 / 登录（M3）
    download/             # 下载管理
    sync/                 # WebDAV 同步
  features/
    comic/  novel/  video/  music/
    common/               # 各媒体共用的页面组件（作品详情、阅读顺序）
    library/  sources/  settings/  search/
test/
  fixtures/               # mock 页面与示例源（仅虚构站点）
  core/  sources/  shared/
tool/
  mock_server/            # 本地 mock HTTP 服务，供测试与规则调试
docs/
```

### 4.1 存储与源管理（M1）

- **数据库**：`core/storage/app_database.dart` 中的 `AppDatabase`（drift），文件为应用支持目录下的
  `tsumugi.sqlite`（`getApplicationSupportDirectory`，不放在用户“文档”目录），SQL 在后台 isolate 执行。
  通过 `appDatabaseProvider` 获取，测试中用内存 SQLite 覆盖。
- **迁移策略**：当前 `schemaVersion = 3`（v2 新增 `source_storage_entries`；v3 新增书架与进度三张表，见 §4.2）。每次改表结构：`schemaVersion` 加一 →
  `dart run drift_dev make-migrations`（把新 schema 导出到 `drift_schemas/`，生成 steps 文件与
  `test/core/storage/migrations/` 下的迁移测试）→ 在 `onUpgrade` 中用 `stepByStep` 写每一步。
  已发布的 `drift_schemas/*.json` 不可修改。数据库版本高于客户端时拒绝打开（不支持降级）。
- **已安装源表** `installed_sources`：清单 JSON 原文是唯一事实来源；`name / type / version /
  apiVersion` 是冗余索引列，另有启用状态、排序值、安装 / 更新时间、来源（本地导入 / 仓库 URL）、
  清单原始字节的 sha256。
- **源注册表** `sources/registry/`：`SourceRegistry` 负责导入（文本 / 文件字节；剪贴板由 UI 读取）、
  校验（先判 `apiVersion`，再查必填字段，最后 `SourceManifest.validate()`）、升级（同 id 版本更高；
  保留启用状态与排序）、拒绝降级、启用 / 禁用、删除、组内重排、按 `MediaType` 过滤。
  导入分两步：`prepareImport` 生成预览（含将访问的主机 = baseUrl 主机 + allowedHosts、未知字段警告），
  用户确认后 `install`。
- 注册表只管理清单。可运行的 `Source` 由按引擎注册的 `SourceFactory`（`sourceFactoriesProvider`）构造，
  声明式 / 脚本引擎各自实现并注册（`DeclarativeSourceFactory` 用 `SourceHttpFetcher` 把按源的
  `SourceHttpClient` 适配为引擎的 `Fetcher`；`ScriptSourceFactory`）。
- **源运行时** `sources/runtime/`：`SourceRuntime`（`sourceRuntimeProvider`）按 sourceId 缓存实例，自行订阅注册表；
  源被禁用 / 删除 / 升级（清单 sha256 变化）时移出缓存并释放（脚本源的 worker、HTTP 客户端），下次 `get` 时重建；
  创建失败不缓存。`sourceInstanceProvider(id)` 在实例被移除时自动失效，依赖它的 provider（如详情）随之重建。
  不直接用 stream provider 的 `.future`：Riverpod 3 会暂停没有监听者的 provider，`ref.read` 读取可能永远等不到值。
- **脚本存储表** `source_storage_entries`：`tsumugi.storage` 的按源 KV（主键 `(sourceId, key)`，值为 JSON 文本），
  经 `core/storage/source_storage.dart` 的 `SourceStorage` 访问；`SourceRegistry.remove` 在同一事务中删除该源的数据。
  用量按 Unicode 码点计（与 SQLite `length()` 一致）；`write(quota:)` 在一个 drift 事务中完成“算用量 → 查配额 → 写入”，
  `isCancelled` 用于丢弃已结束调用排队中的写操作。

### 4.2 书架、进度与历史（M2）

- **书架表** `library_entries`：主键 `(sourceId, itemId)`（`itemId` 即 `SearchItem.id`）；保存加入时的
  标题 / 封面 / 封面请求头（JSON 文本）/ `mediaType` 快照，以及加入时间、元数据更新时间、可选分类与手动排序值。
  源被删除或失效后书架仍可展示。列表顺序：`sortOrder` 升序，再按 `updatedAt` 倒序。
- **条目进度表** `item_progress_entries`：主键 `(sourceId, itemId)`，每个条目只保留**最新**一条进度
  （unit id / 标题、漫画页码（从 0 开始）与总页数、预留给小说 / 视频 / 音乐的 `position`、更新时间），
  并带一份标题 / 封面快照。
- **历史由条目进度表派生，不单独建表**：历史 = 按 `updatedAt` 倒序的条目进度（有索引）。理由：M2 只需要
  “最近读过什么、读到哪”，与“最新进度”是同一份数据；单独的历史表会带来两处写入与一致性问题。
  未来若需要逐次阅读日志（阅读时长统计等）再另加追加写的日志表。删除历史 = 删除条目进度
  （默认连同 unit 进度一起删，可选保留）。历史与书架相互独立：未加入书架的条目也有历史，移出书架不删进度。
- **unit 进度表** `unit_progress_entries`：主键 `(sourceId, itemId, unitId)`，记录每个 unit 自己的位置与已读标记。
  到达最后一页（`page >= pageCount - 1`）或调用方显式标记时置为已读，之后的进度不会清除已读，取消须显式调用。
- 访问层在 `shared/library/`（`LibraryRepository`）与 `shared/history/`（`HistoryRepository`），
  Riverpod provider 见各目录的 `providers.dart`。书架页点击条目通过可覆盖的 `openItemProvider`
  （`features/library/open_item.dart`）跳转，书架不直接依赖详情页路由。
- 数据库中 `mediaType` 为未知值（更高版本客户端写入）的行在读取时被跳过。

## 5. 关键流程

### 5.1 搜索

```
UI(search) → SourceRegistry.enabled(type?) → 并发调用 source.search()
          → 结果按源分组流式返回（Stream），单源超时/失败不影响其他源
```

实现（M2）：`features/search/search_controller.dart` 的 `SourceSearchController` 对每个源独立发起
`SourceRuntime.get(id)` + `search()`（整体受 `searchTimeoutProvider` 限时，默认 30 s），各自回写所在分组；
新搜索递增代号，过时的结果被丢弃。分组保存已加载页、`hasMore` 与最近一次错误，「加载更多」/「重试」都请求下一页。
错误按 §6 错误码显示中文提示（`sources/runtime/source_error_text.dart`）；`E_CHALLENGE` 显示「需要验证」与
「去验证」入口（WebView 尚未接入，见 §5.3）。

漫画详情路由 `/comic/:sourceId/:itemId`，阅读器 `/comic/:sourceId/:itemId/read/:unitId`；`itemId` / `unitId`
通常本身是路径，作为单个路径段时经 `Uri.encodeComponent`（`ComicRoutes`）。`Detail` 没有 `coverHeaders`：
从搜索结果进入且封面相同则沿用该条目的 `coverHeaders`，否则使用源清单的默认 `headers`。
详情页本身是 `features/common/detail/MediaDetailPage`（漫画、小说共用），各媒体只提供阅读器地址与“上次读到”的文案。
小说详情路由 `/novel/:sourceId/:itemId`（`NovelRoutes`）。

### 5.2 打开内容

```
detail(id) → 章节/剧集/曲目列表 → content(itemId)
  comic : List<ImageRef(url, headers)> → 图片加载器（带 headers 与缓存）
  novel : 文本（可分页）             → 排版引擎
  video : StreamRef(url, headers, type) → media_kit
  music : StreamRef + 可选歌词        → media_kit + 后台播放服务
```

**图片加载（M2，`shared/image/`）**：所有源图片（封面、漫画页）经 `SourceImageLoader` 加载：
内存 LRU（编码后字节，默认 64 MB）→ 磁盘 LRU（应用缓存目录 `images/`，默认 512 MB，
键 = sha256(sourceId + url)）→ 该源的 `SourceHttpClient`（因此遵守白名单、限速、默认 headers；
`ImageRef.headers` 随请求发送）。同一图片的并发请求合并，全局并发上限 6；超时 / 连接错误额外重试 1 次，
字节无法解码时清除缓存条目。界面使用 `SourceImageProvider`（`ImageProvider`）或 `SourceImage` / `CoverImage` 组件，
不直接使用 `Image.network`。图片客户端与源实例共用该源的 `SourceSession`（Cookie 与 UA，§5.3）。已知限制：网络层只在响应读完后返回，下载进度目前为不确定进度。

**漫画阅读器（M2，`features/comic/reader/`）**：路由 `/comic/:sourceId/:itemId/read/:unitId?page=N`
（详情路由的子路由；各段 URL 编码，用 `ComicRoutes.reader` / `comicReaderLocation` 生成，`page` 从 0 开始）；纵向滚动 / 左→右 / 右→左三种模式（偏好存于应用支持目录
`comic_reader.json`）；章节列表取自 `detail(itemId)`。阅读进度不直接写库，经
`comicReaderProgressSinkProvider` 回调交给书架 / 历史层。

**小说阅读器（M3，`features/novel/`）**：路由 `/novel/:sourceId/:itemId/read/:unitId?pos=N`（`NovelRoutes.reader`，
`pos` 为章节内字符偏移，定义见 source-spec §2.2.1）。

- 正文：`novelReaderChapterProvider` 经 `loadNovelChapter`（`shared/novel/novel_chapter_loader.dart`，导出共用）调用
  `content(unitId)` 并按 `nextPageId` 拼接章节内分页；纯文本与受限 HTML 都先转换为 `NovelChapter`（段落 / 图片 / 分隔线块，
  `shared/novel/novel_document.dart`），HTML 按白名单清洗，不经任何 HTML 渲染器。同一 `ruby` 元素内的片段（基字与 `rt`）带相同的分组编号，
  阅读器不区分，导出 EPUB 时据此按原分组还原 `<ruby>`。
- 排版：`novel_layout.dart` 中的 `NovelTextStyles` 统一构造文字（段首缩进两个全角空格），上下滚动模式逐块渲染，
  左右翻页模式用 `TextPainter` 按屏幕逐行分页（`paginateNovel`），改字号 / 窗口大小时重新分页并保持字符偏移。
- 偏好（模式、字号、行距、段距、页边距、字体、主题）存于应用支持目录 `novel_reader.json`。
- 进度经 `novelReaderProgressSinkProvider` 节流写入 `HistoryRepository.recordProgress(position:)`，读到章节末尾时标记已读。

**小说导出（M3，`shared/export/`）**：详情页「导出」（`features/novel/export/novel_export_dialog.dart`）选择格式
（TXT / EPUB）、线路与范围（全部 / 起止章节，`ExportRange`），由 `NovelExportJob` 执行：

- 取正文：逐章调用 `loadNovelChapter`（与阅读器同一套分页拼接与白名单清洗），**严格顺序**、一次只有一个 `content`
  调用；源实例来自 `SourceRuntime`（与 `sourceInstanceProvider` 同一缓存实例），因此限速、白名单、Cookie 与默认 headers
  都由该源的网络层执行。每章重新取实例，源被升级 / 禁用时拿到新状态。
- 单章失败进入 `paused`：用户选择重试 / 跳过 / 跳过所有失败章节 / 取消；`E_CHALLENGE` / `E_LOGIN_REQUIRED` 总是暂停
  （跳过只会让后续章节同样失败），对话框中的 `SourceErrorView` 提供「打开验证页」，完成后自动重试。
  跳过的章节列在结果中，并写进 TXT 头部 / EPUB 书名页。取消立即生效，进行中请求的结果被丢弃。
- 封面经统一图片加载器取得（按文件头识别 PNG / JPEG / GIF / WebP），失败或不认识则不放封面。
- 文件在后台 isolate 中生成（`Isolate.run`），避免大部头卡住界面。
- **TXT**：UTF-8（可选 BOM，兼容旧版 Windows 记事本），头部为书名 / 作者 / 来源源名 / 导出时间 / 简介，之后逐章
  “标题 + 正文”；段落一行、段首两个全角空格，`rt` 注音丢弃（ruby 只取正文），图片为「［图片：alt］」占位。
- **EPUB 3**：`mimetype` 为首个条目且不压缩（无扩展字段）→ `META-INF/container.xml` → `OEBPS/content.opf`
  （`dc:identifier` 为由 sourceId + itemId 派生的稳定 UUID）、`nav.xhtml`、兼容 EPUB 2 的 `toc.ncx`、`style.css`、
  可选封面页、书名页、每章一个 XHTML。正文由 `NovelChapter` 重新生成，`body` 内只使用 source-spec §2.2.1 白名单中的标签、
  不带属性（封面 `img` 的 `src` / `alt` 除外）。正文图片暂以占位文字输出（TODO：经图片加载器下载后嵌入）。
- **保存**：`ExportSaver`（默认 `file_picker` 的 `saveFile`）：桌面端为保存对话框；Android 为系统“创建文档”
  （SAF）；iOS 为文件 App 导出界面。文件名由书名生成，替换 `\ / : * ? " < > |` 与控制字符、避开 Windows 保留名、限长 80。

### 5.3 人机验证 / 登录（M3）

网络层检测到挑战（如 403/503 + 特征）或源脚本主动请求时，弹出 WebView 让**用户手动**完成，
完成后将 Cookie 回写到该源的 Cookie 域并重试请求。客户端不自动破解验证码，也不在 WebView 中
自动填写、点击或注入任何脚本（唯一的脚本调用是读取 `navigator.userAgent`）。

**WebView 选型（2026-11）：[`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview) 6.2.0-beta.3（Apache-2.0）。**

使用 beta 的原因：最新稳定版 6.1.5（2024-10）在当前工具链上无法构建——Android 插件使用了新版 AGP 已拒绝的
`proguard-android.txt`，6.2.0-beta.3（2026-02）已改为 `proguard-android-optimize.txt`。Windows 上插件经 C++/WinRT
引入 `<experimental/coroutine>`，VS 2026 默认报错 STL1011，`windows/CMakeLists.txt` 按 MSVC 提示定义了
`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`。上游发布含这些修复的稳定版后应切换回去。

| 包 | Win / Android / iOS | 读取 HttpOnly Cookie | 拦截主框架导航 | 自定义 UA | 许可证 | 结论 |
|---|---|---|---|---|---|---|
| **flutter_inappwebview** ✅ | ✓（WebView2）/ ✓ / ✓ | ✓ Windows 经 CDP `Network.getCookies`，Android `CookieManager`，iOS `WKHTTPCookieStore` | ✓ `shouldOverrideUrlLoading` | ✓ | Apache-2.0 | 选用；稳定版停在 2024-10（6.2 仍为 beta），风险见下 |
| webview_flutter | ✗ / ✓ / ✓ | 只能写不能读 | ✓ | ✓ | BSD-3 | 无 Windows |
| webview_windows | ✓ / ✗ / ✗ | ✗（无 Cookie 读取 API） | 部分 | ✓ | BSD-3 | 只有 Windows，且需与 webview_flutter 拼两套实现 |
| desktop_webview_window | ✓（独立窗口）/ ✗ / ✗ | ✗ | ✗ | — | Apache-2.0 | 只有桌面 |

Apache-2.0 与 GPL-3.0 兼容；Windows 构建时由插件的 CMake 经 NuGet 拉取 WebView2 SDK（BSD-3）、WIL（MIT）
与 nlohmann/json（MIT），因此**构建机需要 `nuget.exe` 在 PATH 中**（GitHub 的 `windows-latest` 镜像自带；
本机可 `winget install Microsoft.NuGet`）。运行时需要系统已安装 WebView2 Runtime（Windows 11 自带），缺失时页面给出提示。
风险：上游稳定版发版放缓。缓解：插件只出现在 `shared/webview/` 的两个文件中
（`inappwebview_page.dart`、`inappwebview_cookie_store.dart`），其余代码依赖可注入的
`WebViewLauncher` / `WebCookieStore` 接口，必要时可换实现。

**组成（`shared/webview/`）**

```
SourceErrorView「打开验证页」 ─┐                 ┌─ WebViewLauncher（真实：推入 SourceWebViewPage）
                               ├▶ SourceVerifier ┤
tsumugi.ui.openWebView ────────┘   （单飞 / 节流） └─ WebCookieStore（真实：flutter_inappwebview CookieManager）
   (WebViewScriptUi)                     │
                                         ▼
                                SourceSession（按源：Cookie Jar + UA）◀── 源实例与图片的 DioSourceHttpClient 共用
```

- **按源会话** `SourceSession`（`core/network/source_session.dart`）：一个源的 Cookie Jar、
  WebView 同步来的 User-Agent、最近一次检测到挑战的地址。`SourceSessions`（`sources/session/`）
  按 sourceId 提供同一个会话，**源实例（声明式 / 脚本）与图片加载器的客户端共用它**，因此登录 / 验证
  Cookie 对图片同样有效。源被删除时丢弃其会话。会话目前只在内存中，重启后需重新验证（后续工作）。
- **打开**：地址必须在该源的 `HostPolicy` 白名单内。`SourceErrorView` 打开的是最近一次触发挑战的地址
  （网络层检测到挑战时记录在会话中），没有时为 `baseUrl`；脚本打开的是它给出的地址。
- **导航限制**：主框架导航到白名单外（或非 http(s)）的地址时取消导航，页面顶部提示被阻止的主机；
  若某个平台未经 `shouldOverrideUrlLoading` 就开始加载（如部分重定向），`onLoadStart` 立即停止加载并显示同样的提示。
  子资源与 iframe 不受限制（验证组件常来自第三方主机），但它们的 Cookie 不会被同步。
- **完成**：用户点「完成」，或主框架**加载完成**的地址匹配 `doneWhenUrlMatches`（只对白名单内的地址判断，
  求值期间若已导航到别处则忽略；正则在后台 isolate 中串行求值、限时 1 s，超时则不再自动判断，
  避免恶意正则卡住界面）。点关闭为取消（读取 UA 期间仍可取消，读取限时 2 s）。
  **Cookie 在页面关闭前同步**（WebView 仍存活）：同步失败时页面不关闭，提示用户重试「完成」或取消，
  不会把读取失败当作 0 个；一个 Cookie 也没读到时给出提示。同步后清空该页面的 Cookie，页面 pop 后
  再等其销毁、清空全局存储一次，退出动画中的旧页面之后的写入不会留给下一个源。
- **Cookie 同步**：页面关闭前对「`baseUrl`、`allowedHosts` 中的非通配主机、本次访问过的白名单内地址」逐个读取 WebView
  中会发往该地址的 Cookie（含 HttpOnly），以**主机限定**（不带 Domain）、保留 Path / 过期时间 / Secure /
  HttpOnly 的形式写入该源的 Cookie Jar（`SourceSession.importCookies`，非白名单地址一律拒绝）。
  平台没给出的属性按收紧方向补全：Path 取读取时的地址路径，经 https 读到的视为 Secure
  （Android 缺少 `GET_COOKIE_INFO` 时只返回 name / value）。`SourceSession` 的 Jar 包装为 `SecureCookieJar`，
  修正 `cookie_jar` 会把 Secure Cookie 发往 http 的问题（每一跳重定向同样生效）。
  Windows 上经该页面自己的 WebView2 调用 CDP `Network.getCookies` 读取（失败时报错）；不用插件的 `CookieManager`，
  因为它经临时 WebView2 读取，页面销毁后常以 `ERROR_NOT_READY` 失败且只返回空列表（M3 手动测试中发现）。
  同一主机上的同名、同 Path Cookie 只写入一次。
  因为 WebView 的 Cookie 存储是全局的，**打开前与结束后都清空 WebView 的 Cookie**（Windows 上插件报告清空失败时不打开验证页；Android 的返回值只表示是否删掉了 Cookie，不作判断），
  所以一个源的验证页看不到、也同步不到其他源留下的 Cookie。代价：每次打开验证页都从空白状态开始
  （源 Cookie Jar 中已有的 Cookie 不会预先放进 WebView）；localStorage 等其他站点数据不清空。
- **User-Agent**：清单 `headers` 设置了 `User-Agent` 时，WebView 使用同一个 UA；否则完成时读取 WebView 的
  `navigator.userAgent` 记入会话，此后该源（含图片）未显式指定 UA 的请求都带上它
  （优先级：请求 headers > 清单 headers > 会话 UA）。限制：只同步 UA 字符串，TLS / HTTP2 指纹、
  `Sec-CH-UA` 等客户端提示仍与浏览器不同，部分站点的验证 Cookie 可能依然失效，此时只能放弃该站点，
  客户端不做进一步的伪装。
- **并发与节流**（`SourceVerifier` + `WebViewThrottle`）：同一时刻只显示一个验证页；同一源的并发请求共用
  进行中的那一次。脚本发起的打开另有限制：应用不在前台、已有验证页打开、该源上次**由脚本打开的**验证页关闭后 30 s 内
  （用户取消后为 2 min）都直接以 `E_CHALLENGE` 拒绝而不弹窗（用户主动打开的、未能显示的不计入冷却）；单次入口调用最多一次 `openWebView`（第二次 → `E_LIMIT`）。
  用户点击「打开验证页」不受节流限制。`ui.toast` 每源每 2 s 最多一条，应用不在前台时丢弃。
- **错误码**：用户取消 → `E_CHALLENGE`；平台不支持 WebView / 缺少 WebView2 Runtime → `E_UNSUPPORTED`。
  `SourceErrorView` 对 `E_CHALLENGE` 与 `E_LOGIN_REQUIRED` 显示「打开验证页」，完成后自动调用重试回调；
  搜索、详情、阅读器复用同一入口（`openSourceVerification`）。
- **已知限制**：`openWebView` 的等待计入单次调用的 30 s 总时长（source-spec §4.4）。调用超时后验证页
  仍保持打开，用户完成后 Cookie 照常写回，但这次调用已以 `E_LIMIT` 失败，需要用户重试；
  需要较长时间的登录建议脚本直接抛出 `E_LOGIN_REQUIRED`，由界面引导用户打开验证页。
  后续可让引擎在等待 `openWebView` 期间暂停总时长计时。
- 测试中用假的 `WebViewLauncher` / `WebCookieStore`，不启动真实 WebView；手动验证用
  `tool/mock_server` 的 `/challenge/page`、`/login` 与 `test/fixtures/sources/mock_comic_gated*.json`。

### 5.4 网络层（M1）

`lib/core/network/` 提供按源隔离的 HTTP 客户端，声明式引擎与脚本宿主 API（`tsumugi.http` /
`tsumugi.cookies`）共用同一抽象：

- `SourceHttpClient`（接口）/ `DioSourceHttpClient`（dio + cookie_jar 实现）：每个源一个实例，
  持有独立的 Cookie Jar、默认 headers、超时、令牌桶限速（`TokenBucket`）与 `HostPolicy`。
  重定向由客户端逐跳处理以便对每一跳做白名单检查；行为细则见 source-spec §5。
- `SourceNetworkConfig`：纯 core 类型；由清单生成的函数 `networkConfigFromManifest` 位于
  `lib/sources/network_error_mapping.dart`（core 不依赖 sources）。
- 错误统一为 `NetworkException(kind)`，`NetworkErrorKind` 与 source-spec §6 错误码一一映射
  （`NetworkException.toSourceException()`，同样在 sources 一侧）。
- `ChallengeDetector` 只做检测（状态码 + 响应头 / 页面特征），命中时上报 `E_CHALLENGE`。
- 测试与规则调试使用 `tool/mock_server/`（纯 Dart，页面在 `test/fixtures/mock_site/`）。
  测试中通过自定义 `HttpClientAdapter` 把 `comic.example.com` 等虚构主机名的连接接到本地随机端口，
  白名单仍按真实主机名检查；手动调试：`dart run tool/mock_server/main.dart --port 8080`。
- **明文 http**：Android（`android:usesCleartextTraffic="true"`）与 iOS（`NSAllowsArbitraryLoads`）
  均允许 http，因为不少源站点只提供 http；访问范围仍由每个源的 `HostPolicy` 白名单限制，
  安全边界不依赖传输层。Secure Cookie 不会经 http 发送（`SecureCookieJar`，§5.3）。
- **真机调试**：`dart run tool/mock_server/main.dart --host 0.0.0.0` 监听局域网，并只打印实际访问得通的本机地址（排除已断开网卡的残留地址与代理虚拟网卡 198.18.0.0/15）；
  手机浏览器打开 `http://<电脑局域网 IP>:8080/sources/`，复制虚构源 JSON 导入应用——
  `/sources/<文件名>` 会把虚构源里的 `http://127.0.0.1:8080` 换成请求所用的地址；命令行启动的服务器
  还会把页面 / JSON 中虚构的图片主机 `http://img.example.com` 换成请求地址，封面与漫画页才能显示
  （`MockServer.rewriteFictionalHosts`，单元测试不开启）。
  Windows 防火墙首次会询问是否允许 dart 接受入站连接。

已知限制：响应文本只识别 utf-8 / latin1 / ascii 字符集（其余按 utf-8 宽松解码），GBK 等需后续补充；
Cookie Jar 在按源的 `SourceSession` 中（§5.3），目前只在内存中，持久化（按源目录的 `PersistCookieJar`）为后续工作。

### 5.5 脚本源（M1）

`lib/sources/script/` 的 `ScriptSource`（`engine: "script"`）执行模型：

```
主 isolate                                          worker isolate（每个源一个）
ScriptSource ─ 串行入口调用 ─▶ IsolateScriptRuntime ═ load/call ═▶ QuickJsScriptRuntime
  │ ScriptCallScope（请求计数 / 取消）   │ 看门狗                     │ prelude 组装 tsumugi
  ▼                                    │                          │ crypto.* / html.*（同步）
ScriptHost：http / storage / cookies ◀═ host 请求（脚本侧 Promise）═┤
            ui.openWebView                                          │
            log.* / ui.toast ◀════════ notify（发出即忘）═════════════┘
```

- `IsolateScriptRuntime`（`core/engine/script/`）实现不变的 `ScriptRuntime` 接口。宿主函数分三类：
  主 isolate 异步执行的（脚本侧为 Promise）、发出即忘的通知（同步返回），以及由 `WorkerHostFactory`
  在 worker 内构造、可同步返回的（`crypto`、HTML 句柄）。主 isolate 只接受当前进行中的调用发来的宿主请求。
- **prelude**：`QuickJsScriptRuntime` 可接受一段受信任 JS（`(raw) => api`），把冻结的原始宿主对象包装成公开的
  `tsumugi`；`HtmlNode` 由此用句柄实现（source-spec §4.2.1），原始句柄函数对脚本不可见。`tsumugi.source` 作为常量嵌入 prelude。
- **看门狗与重建**：每次加载 / 调用在 `wallTime + hangGrace`（默认 5 s）内无回应即判定 worker 卡死，调用以 `E_LIMIT`
  失败，worker 被丢弃，下一次调用新建 worker 并重新加载脚本；worker 意外退出（未捕获异常等）同样以 `E_LIMIT` 失败并在下次重建。
  JS 层面的超限（CPU、总时长、内存）仍由 worker 内的 `QuickJsScriptRuntime` 自行中断与重建，worker 本身保留。
- **每次调用的作用域**：`ScriptHost.begin()` 为每次入口调用建立 `ScriptCallScope`，`tsumugi.http.*` 据此计数（上限 50）
  并共享一个 `NetCancellation`；调用结束即取消未完成的请求。
- `tsumugi.ui` 通过可注入的 `ScriptUi`（`scriptUiProvider`）实现，默认 `UnavailableScriptUi`（WebView → `E_UNSUPPORTED`），
  应用启动时覆盖为 `shared/webview/` 的 `WebViewScriptUi`。WebView 完成后经 `WebViewRequest.session`
  （本源客户端的 `SourceSession`）回写 Cookie，见 §5.3。
- `ScriptSourceFactory` 为每个源创建使用该源 `SourceSession`（§5.3，与图片加载共用 Cookie Jar）的 `DioSourceHttpClient`，存储用 `DriftSourceStorage`。
  创建出的 `ScriptSource` 由调用方 `dispose`（同时关闭其 HTTP 客户端与 worker）。

## 6. 风险与待验证项

1. **QuickJS 绑定的跨平台可用性** —— M0 已完成验证，结论见 §6.1。
2. **iOS 分发**：无法上架 App Store，CI 产出未签名 IPA，用户自签。
3. **音乐后台播放**：需要各平台的媒体会话适配（Android 前台服务、iOS AVAudioSession、Windows SMTC）。
4. **XPath / JSONPath 库质量** —— M1 已选型，结论见 §6.2。

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
- **微任务与结果提交**（2026-11 加固）：每次进入 JS 后在同一 deadline 内清空微任务队列；入口结果先暂存，
  这一段 JS 及其微任务正常结束后才提交，结果之后的超限不会被吞掉。
- **调用隔离**：被中断 / 超限后不再执行任何排队的微任务；调用以 `E_LIMIT` 结束或微任务队列未能清空时，
  丢弃整个 `JSRuntime` 并重新求值模块（模块级状态重置，见 source-spec §4.4）。宿主函数只接受
  进行中调用的请求，迟到的宿主结果被丢弃。
- **加载失败**：实例作废，不允许换脚本重试（失败的模块可能已改动全局对象）。
- **错误映射**：引擎中断最先识别；随后脚本显式 `code` 优先；内存 / 栈超限只认引擎的确切错误类型与消息；
  `status`（100–599）在宿主与脚本之间双向保留。

2026-11 用 Codex（只读）对本节代码做了交叉审查，发现的问题均已修复并有回归测试
（`test/core/engine/script/quickjs_hardening_test.dart`、`test/core/network/host_*_test.dart`），
以下两项除外，列入已知限制。

已知限制与后续工作：

- **`QuickJsScriptRuntime` 在调用方 isolate 上同步执行 JS**。脚本源已通过 `IsolateScriptRuntime`
  把每个源的运行时放进独立 worker isolate（§5.5）；声明式引擎的 `js:` 片段仍在调用方 isolate 上执行
  （可改用 `IsolateScriptRuntime.create` 作为其 `ScriptRuntimeFactory`）。
- **QuickJS 栈顶与线程迁移**（2026-11 实测）：QuickJS 只在创建 `JSRuntime` 时记录一次原生栈顶，
  而 Dart isolate 在两个事件之间可能被调度到另一个 OS 线程。worker 中因此偶发误报
  `Maximum call stack size exceeded`；反方向时栈检查会失效。`qjs` 未暴露 `JS_UpdateStackTop`，
  `core/engine/script/native_stack.dart` 经 native asset 直接调用它（读取 `JSRuntime.ptr` 的第一个字段，
  该成员在 qjs 中标为 `@internal`），在每次从 Dart 同步进入 JS（调用、resolve 宿主 Promise、建引擎、释放）前更新。
  升级 qjs 时需复查结构布局；应向上游报告，修复后删除此文件。
- **worker 无法被强制终止**：不能用 `Isolate.kill(priority: immediate)`——worker 往往正处于 QuickJS → Dart 的
  FFI 回调中，在那里被强制终止会让整个进程崩溃（已实测）。因此看门狗只做 `kill(beforeNextEvent)`：worker 回到事件循环时退出，
  一直卡住的 worker 只能放弃（占用一个线程直到进程退出）。
- **部分原生内建函数不检查中断**：QuickJS-ng 某些内建函数（如 `Array.prototype.flat` 作用于
  `length` 极大的类数组对象）在 C 循环中不检查中断，CPU / 总时长限制对其无效，可能长时间无法返回
  （未实测，依据引擎源码判断）。放进 worker isolate 也不够：isolate 卡在原生代码中时 Dart 无法终止它。
  根治需要给引擎打补丁（在这些循环中加入中断检查）或把脚本放进可被强制结束的独立进程；
  在此之前，恶意源最坏能卡死其所在的 worker。
- 同一运行时上的调用**串行执行**（宿主 Promise 需要归属到具体调用）。如需单源并发，可按调用开多个运行时。
- `ui.openWebView` 的等待时间计入单次调用的 30 s 总时长，用户登录可能来不及完成；M3 的处理与后续工作见 §5.3。
- HTML 句柄的 DOM 不在 JS 堆内，只能靠句柄数与解析文本量的上限间接约束（source-spec §4.2.1）。
- 源脚本**不支持顶层 await**（模块同步求值）；已写入 source-spec §4.1。
- 移动端只验证到“能编译打包”，真机 / 模拟器上的运行时加载尚未自动化验证，M1 加 integration test。
- `qjs` 的 build hook 默认从其 GitHub Release 下载预编译库（sha256 写死在包内并校验），失败时回落到
  本地用 `native_toolchain_c` 编译源码。需要可复现构建时可在 M1 评估改为强制源码编译。
- `qjs` 为单人维护的新库（风险：维护中断）。缓解：引擎细节全部隔离在 `QuickJsScriptRuntime` 一个文件内，
  其 C 桥接层很薄，必要时可 fork；fjs 作为第二候选。

### 6.2 XPath / JSONPath 选型结论（M1，2026-11）

两者都只在 `lib/core/engine/expression/` 内使用，规则引擎的其他部分不直接依赖。

**XPath：[`xml`](https://pub.dev/packages/xml) 7.1（MIT，纯 Dart）。** `package:html` 的 DOM 本身不支持 XPath，
`HtmlXPath`（`expression/html_xpath.dart`）为每棵 HTML 树建一个不带命名空间的 XML 镜像（按树根缓存），
求值后把结果元素映射回原 HTML 节点，因此 `@html` / `@outerHtml` 与后续 css 步骤仍作用于原节点。

| 包 | XPath 版本 | 许可证 | 维护 | 结论 |
|---|---|---|---|---|
| **xml** ✅ | XPath 3.1（XPath 1.0 的超集），W3C 函数库 | MIT | 2026-09 仍在发版，pub.dev 449 likes，Dart 生态最常用的 XML 库 | 选用 |
| xpath_selector + xpath_selector_html_parser | 自研子集（轴、谓词、函数不全） | BSD-3 | 最后发版 2023-01 | 能直接作用于 `html` DOM，但功能与维护都不足 |
| html_xpath | 子集 | Apache-2.0 | 已 discontinued | 否 |

取舍：镜像需要一次 O(n) 的树复制，只在规则真正用到 xpath 时发生，每份文档一次；
换来完整的 XPath 语义与活跃的上游。规范仍只承诺 XPath 1.0（§3.3），3.1 的额外函数不保证跨版本可用。

**JSONPath：[`json_path`](https://pub.dev/packages/json_path) 0.9（MIT，纯 Dart）。** 实现 RFC 9535，
声明通过官方 Compliance Test Suite；依赖只有 petitparser 等纯 Dart 包。
RFC 9535 是目前唯一的 JSONPath 标准，选它可避免各实现间过滤器语法的差异。

两者都支持 Windows / Android / iOS（纯 Dart，无原生库）。兼容性测试见
`test/core/engine/expression/expression_engine_test.dart`。

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
