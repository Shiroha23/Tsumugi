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
| 音视频 | [`media_kit`](https://pub.dev/packages/media_kit)（MIT）+ 预编译 libmpv / FFmpeg（LGPL） | M4 已验证，视频与音乐共用；所有请求经本地媒体代理走源的网络层，见 §6.4 |
| WebView | [`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview) 6.2.0-beta.3（Apache-2.0） | M3 选定：登录 / 人机验证（用户手动完成），见 §5.3 |
| 序列化 | freezed + json_serializable | |
| 文本编码 | 自实现 WHATWG Encoding 解码器（纯 Dart，无新依赖） | #22：GBK / GB18030 / Big5 / Shift_JIS / EUC-KR / 单字节编码，见 §6.3 |
| 压缩 / ZIP | [`archive`](https://pub.dev/packages/archive)（MIT） | M3 选定：生成 EPUB（OCF ZIP 容器），纯 Dart，三平台一致，见 §5.2「小说导出」 |
| 文件选择 / 保存 | [`file_picker`](https://pub.dev/packages/file_picker)（MIT） | M1 导入清单；M3 起 `saveFile` 用于保存导出文件 |
| 凭据存储 | [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) 11.2.0（BSD-3，含各平台实现包） | M6：WebDAV 密码，见 §4.6；Android 7.0+（插件 minSdk 24；RSA OAEP + AES-GCM）、iOS 13+（Keychain）、Windows（DPAPI 加密的 JSON 文件，旧版凭据管理器数据经 C++ 插件兼容读取，构建需 VS 的 C++ ATL） |
| WebDAV | 自实现（基于 dio） | M6：只需 `PROPFIND` / `MKCOL` / `GET` / `PUT`，见 §4.6 |

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
      media/              # 本地媒体代理与 HLS 播放列表改写（音视频请求经源的网络层，§6.4）
    encoding/             # 响应文本的编码识别与解码（WHATWG Encoding，§6.3）
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
    video/                # 播放器选项、按源建立代理会话（M4）
    download/             # 下载管理
    sync/                 # WebDAV 同步
  features/
    comic/  novel/  video/  music/
    common/               # 各媒体共用的页面组件（作品详情、阅读顺序、列表条目行）
    library/  sources/  settings/  search/
    downloads/            # 下载对话框、书架「下载」标签与条目的章节状态页（§4.5）
    explore/              # 发现页：选源 → 分类 → 可翻页列表（§5.1）
test/
  fixtures/               # mock 页面与示例源（仅虚构站点）
  core/  sources/  shared/
tool/
  mock_server/            # 本地 mock HTTP 服务，供测试与规则调试
  encoding/               # 由 WHATWG 索引生成 lib/core/encoding/whatwg_indexes.dart
docs/
```

### 4.1 存储与源管理（M1）

- **数据库**：`core/storage/app_database.dart` 中的 `AppDatabase`（drift），文件为应用支持目录下的
  `tsumugi.sqlite`（`getApplicationSupportDirectory`，不放在用户“文档”目录），SQL 在后台 isolate 执行。
  通过 `appDatabaseProvider` 获取，测试中用内存 SQLite 覆盖。
- **迁移策略**：当前 `schemaVersion = 8`（v2 新增 `source_storage_entries`；v3 新增书架与进度三张表，见 §4.2；v4 为 `installed_sources` 新增 `settings_json`；v5 新增 `source_repositories` 与 `installed_sources.repository_url`，见 §4.4；v6 新增下载两张表，见 §4.5；v7 为 WebDAV 同步新增 `sync_state` / `sync_tombstones`、参与同步的表加 `modified_at` 与改动跟踪触发器，见 §4.6；v8 为 `download_units` 新增 `stream_label`（视频下载所选的清晰度），见 §4.5.1）。每次改表结构：`schemaVersion` 加一 →
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
- **源设置**（source-spec §1.1）：用户修改过的值存为 `installed_sources.settings_json`（JSON 对象，只含改过的键；
  null 表示全部取默认），与清单在同一行，删除源时随行删除。`sources/model/source_settings.dart` 负责校验
  （`validateSettingDefinitions`，由 `SourceManifest.validate()` 调用）、按清单过滤保存的值（`sanitizeSettingValues`）
  与求有效值（`effectiveSettings`：保存的有效值，否则 `default`）。`install` 升级 / 覆盖时在同一事务中按新清单过滤旧值
  （丢弃已删除的键、与旧清单相比类型变化、或对新清单不再有效的值）；`SourceRegistry.setSettings` 写入前同样过滤。
  源页面菜单「源设置」（`features/sources/source_settings_dialog.dart`）按清单渲染 `select` / `switch` / `text`，
  没有可显示项的源不出现该菜单项。
- 注册表只管理清单。可运行的 `Source` 由按引擎注册的 `SourceFactory`（`sourceFactoriesProvider`）构造，
  声明式 / 脚本引擎各自实现并注册（`DeclarativeSourceFactory` 用 `SourceHttpFetcher` 把按源的
  `SourceHttpClient` 适配为引擎的 `Fetcher`；`ScriptSourceFactory`）。
- **源运行时** `sources/runtime/`：`SourceRuntime`（`sourceRuntimeProvider`）按 sourceId 缓存实例，自行订阅注册表；
  源被禁用 / 删除 / 升级（清单 sha256 变化）或源设置变化（有效值不同）时移出缓存并释放（脚本源的 worker、HTTP 客户端），
  下次 `get` 时以新的清单与设置重建（`SourceFactory.create(manifest, settings: …)`）；释放会中断进行中的调用（取消请求、结束脚本 worker），
  与升级时一致；
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
- **快照的封面请求头**（#24）：阅读器 / 播放器的条目快照取自 `Detail`，而 `Detail` 没有 `coverHeaders`。
  `recordProgress` 把快照中为 null 的 `coverHeaders` 视为“调用方不知道”，依次沿用已有历史、书架条目中的值
  （都只在封面地址相同时采用），最后回退到调用方给出的 `defaultCoverHeaders`（源清单的默认 headers，与详情页一致）；
  快照自带的请求头优先。这样各阅读器不必各自查书架 / 历史，也不会把已知的请求头覆盖为空。
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

### 4.3 M6 总览：规则仓库订阅、下载管理、WebDAV 同步

> 状态：设计已定（2026-11-19）。规则仓库订阅（§4.4，v5）、下载管理第一期（§4.5，v6）、WebDAV 同步（§4.6，v7）均已实现。下列三项相互独立，可并行开发；各自新增的表在合并时按合并顺序
> 依次占用 `schemaVersion`（5、6、7…），后合并的 PR 在变基时重新生成迁移，已合并的 `drift_schemas/*.json` 不改。

已定的取舍（2026-11-19）：

| 项 | 决定 |
|---|---|
| 下载范围 | 第一期只做**漫画与小说**；视频下载与后台下载放到 M6 第二期（§4.5.1，2026-11-23 定） |
| 同步范围 | 书架、条目 / unit 进度（即历史）、已安装源（清单 + 用户改过的设置 + 启用与排序）、仓库订阅列表 |
| 不同步 | Cookie 与登录状态、脚本源的 `tsumugi.storage`、已下载的文件、阅读器 / 播放器偏好 |
| 源签名（#33） | **不做**作者 / 仓库签名；靠仓库索引中的 sha256、只允许 HTTPS、更新时主机变化必须单独确认 |
| 仓库更新 | 只提示“可更新”，由用户确认后安装；不自动更新 |

### 4.4 规则仓库订阅（M6，`sources/repository/`）

仓库格式与客户端规则见 source-spec §7，这里只写实现结构。

- **表** `source_repositories`（v5）：主键为规范化后的 `index.json` 地址；名称（取自索引）、加入时间、上次检查时间与结果
  （`last_error_code` 为 null 表示成功，否则为 `RepositoryErrorKind` 名称，另存中文说明）、上次成功取得的索引原文与其 sha256
  （离线时仍可浏览仓库列表；检查失败时保留）。`installed_sources.repository_url`（v5）记所属仓库，退订后保留原值。
- **代码结构**：`sources/repository/` 下 `RepositoryHttpClient`（网络）、`repository_index.dart`（地址规范化、索引解析与校验）、
  `RepositoryService`（订阅 / 退订 / 检查 / 准备安装预览，以及纯函数 `entryState`、`sourceRepositoryStatuses` 派生“可更新 / 仓库已移除”）、
  `providers.dart`（`repositoryUpdateSchedulerProvider` 由应用根组件监听，启动后检查一次并每 24 h 一次）；
  界面在 `features/sources/repository/`。
- **地址规范化**：去首尾空白与片段，协议与主机小写，去默认端口；路径为空或以 `/` 结尾时补 `index.json`；
  不允许 URL 中带用户信息（`user:pass@`）。
- **取索引与清单**：使用独立的 `RepositoryHttpClient`（dio），**不**经过任何源的网络层：无 Cookie、不带源的 headers、
  固定客户端 UA（`Tsumugi-Repository/1`）、单次获取（含全部重定向与读取响应体）15 s、索引不超过 2 MiB、清单不超过 4 MiB（与本地文件导入的上限相同）；只允许 `https`（测试用的回环地址
  `127.0.0.1` / `localhost` / `::1` 例外，可用 `http`；该例外由 `RepositoryHttpClient(allowLoopbackHttp: true)` 开启，只在测试中使用，
  应用中关闭——否则远程仓库可以用索引条目或重定向让客户端向本机端口发请求）；应用中指向本机的地址（`localhost` 及其子域、`127.0.0.0/8`、`0.0.0.0`、`::1`、`::`、`::ffff:127.*`）不论 `http` 还是 `https` 一律拒绝；重定向每一跳同样只能是 `https`（回环例外同上），最多 5 跳。
  连接阶段也受同一时限（`connectTimeout`），不会在超时后继续挂在后台。
- **安装**：从仓库安装复用 `SourceRegistry.prepareImportBytes` → 预览 → `install`；顺序为：条目 `apiVersion` 受支持 →
  同 id 已装源来自本仓库（否则不下载）→ 下载 → sha256（不符直接拒绝）→ 清单解析与校验（含拒绝降级）→ 清单 id / version /
  apiVersion 与条目一致。`installed_sources.originKind = repository`、`originUrl` 记清单的绝对地址、`repositoryUrl` 记所属仓库。
  `SourceRegistry.install` 在写入事务中再次检查：仓库来源的预览只能覆盖来自同一仓库的源（`SourceImportError.otherOrigin`）；
  用户从本地导入同 id 源则照常覆盖，来源变为本地。
- **更新检查**：应用启动时、运行中每 24 h、用户在仓库页下拉刷新时检查全部仓库（仓库之间串行，单个失败不影响其他）。
  只对“来自该仓库”的已装源比较版本（`version` 按语义化版本比较，见 `registry/version.dart`）；
  本地导入或来自其他仓库的同 id 源不会被这个仓库更新。结果只在源页面标“可更新”，不自动安装。
- **更新确认**：预览中照常列出将访问的主机；若新清单的主机集合（`baseUrl` 主机 + `allowedHosts`）**不是**旧集合的子集，
  新增的主机单独高亮列出，需要用户再确认一次（`ImportPreview.newHosts`，按小写后的字符串比较，不按通配符展开——
  旧集合为 `*.example.com` 时新出现的 `img.example.com` 也算新增，宁可多问）。旧清单无法解析时全部主机视为新增。
- **退订**：删除仓库记录，已装的源保留（变为不再检查更新的源，源页面显示“仓库已移除”）。
- **界面**：源页面增加「仓库」入口：添加（输入地址 → 取索引 → 展示仓库名与源数量 → 确认订阅）、列表、按类型 / 语言 / nsfw 过滤的
  源浏览、安装 / 更新按钮、“全部更新”（逐个弹出预览，不批量跳过确认）。

### 4.5 下载管理（M6，`shared/download/`）

第一期支持漫画（按章节下载全部页）与小说（按章节下载正文与正文图片）。下载用于**应用内离线阅读**，
与“导出”（§5.2，生成用户可带走的 TXT / EPUB）是两回事；导出以后可以优先读取已下载的章节，但不在第一期范围内。

> 状态：第一期（漫画 / 小说）已实现（2026-11）：`shared/download/`（`DownloadManager` 队列、`DownloadStore` 文件、
> `DownloadRepository` 表、`DownloadLibrary` 供阅读器读取）与 `features/downloads/`（下载对话框、书架「下载」标签、条目页）。

- **存储位置**：应用支持目录下的 `downloads/`（与数据库同一目录树，系统不会当作缓存清理；不放在用户文档目录）。
  路径一律由哈希与序号生成，**不使用源返回的任何字符串**（标题、id、URL）作为文件名：
  `downloads/<h(sourceId)>/<h(itemId)>/<h(unitId)>/`，`h` 为 sha256 的前 32 位十六进制（128 位）——完整的 64 位会使三段目录
  加上 Windows 的应用支持目录超过 `MAX_PATH`（260 字符，实测目录列举失败）。其中漫画页为 `0001.<ext>` 起编号，
  小说为 `chapter.json`（清洗后的 `NovelChapter` 序列化结果）与 `img-NNNN.<ext>`。扩展名按文件头识别（PNG / JPEG / GIF / WebP，
  与导出一致），识别不了的图片视为失败。
  每个 unit 目录有一份 `unit.json`：按序列出每个文件对应的**来源标识**（图片地址 + 请求头的规范化 JSON 的 sha256）与本地文件名。
  读取时严格校验：文件名必须是上面两种由客户端生成的形式（拒绝 `..`、分隔符等），否则整份记录视为损坏。
  小说正文中的图片在 `chapter.json` 里保留原地址，`unit.json` 给出“原地址 → 本地文件”的映射；离线阅读时阅读器按映射
  从本地文件加载（没有映射或文件缺失的图片显示与导出相同的「［图片：alt］」占位，不发起网络请求）。
- **表**：`download_items`（主键 `(sourceId, itemId)`：标题 / 封面 / 封面请求头 / `mediaType` 快照，以及下载时 `detail()` 结果的
  JSON 快照，用于离线打开目录）与 `download_units`（主键 `(sourceId, itemId, unitId)`：unit 标题、所在线路与序号、状态
  `queued / running / paused / failed / done`、已完成文件数 / 总数、已用字节、最近错误码、更新时间）。
- **取内容**：与阅读器相同的路径——源实例来自 `SourceRuntime`，漫画页经 `SourceImageLoader` 的**不写缓存**的下载入口
  （同样走该源的网络客户端：白名单、限速、Cookie、默认 headers、`ImageRef.headers`、`maxResponseBytes`），
  小说正文经 `loadNovelChapter`（分页拼接与白名单清洗与阅读器一致），正文图片的单张 / 合计上限沿用导出的默认值。
  先写临时文件、校验后再改名，目录内另写一个完成标记；没有完成标记的 unit 视为未下载。
  加载器的下载入口（`SourceImageLoader.download`）既不写也不读内存 / 磁盘缓存，也不与阅读器同一图片的请求合并；
  小说中超过单张 / 合计上限的图片不算失败，保留占位（与导出一致），其余图片失败或格式不认识时 unit 进入 `failed`。
  上限（下载目录不是缓存，不会被淘汰）：漫画一章最多 2000 页、合计 1 GiB，超过时 unit 以 `E_LIMIT` 失败；
  小说一章最多 500 张正文图片，之后的以及超过单张 / 合计上限的图片保留占位，并在 `unit.json` 中记为跳过，续传时不再请求。
  `unit.json` 每写完 10 个文件重写一次，出错、取消与结束时再写一次。
- **并发与续传**：一个全局队列；同一源一次只下载一个 unit（避免与浏览抢限速），不同源最多同时 2 个 unit；
  图片并发受加载器的全局上限（6）约束。续传以文件为粒度，不做 HTTP 区间续传：继续或重试时重新调用 `content()`，
  把新结果的来源标识列表与 `unit.json` 比较——完全一致才跳过已写完的文件；不一致（源换了图片、顺序或数量）时
  丢弃该 unit 已下载的文件，从头下载，避免新旧内容混在一起。
  暂停 / 删除不中断进行中的请求：当前的 `content()` 或图片请求结束后停止，结果丢弃；任务结束时只在 unit 仍为 `running`
  时写入结果（暂停与队列认领之间的竞态不会覆盖暂停）。下载调用的脚本若调用 `tsumugi.ui.openWebView`，与浏览时一样
  受 §5.3 的前台 / 单例 / 冷却限制，用户取消后该 unit 按 `E_CHALLENGE` 暂停整个源。
  应用退出时进行中的 unit 回到 `queued`，下次启动后继续。第一期不做后台下载（Android 前台服务 / iOS 后台任务），
  应用被系统挂起时暂停——后台下载见 §4.5.1（#74）。
- **错误**：单页 / 单图失败按网络层既有的重试后，unit 进入 `failed`，可单独重试；`E_CHALLENGE` / `E_LOGIN_REQUIRED`
  暂停**该源**的全部下载，下载页提供「打开验证页」，完成后自动继续；源被删除 / 禁用时该源的队列暂停。
  “源暂停”不单独存表：出错的 unit 记为 `paused` 并带错误码（`E_CHALLENGE` / `E_LOGIN_REQUIRED` / 内部的 `E_SOURCE_UNAVAILABLE`），
  队列不再为有这类 unit 的源开始新任务，重启后同样生效；恢复源时把这些 unit 改回 `queued`。
- **阅读器接入**：漫画 / 小说阅读器打开 unit 时先查 `download_units`，状态为 `done` 且完成标记存在则从本地读取，不调用 `content()`；
  文件缺失或损坏时回退到网络并把该 unit 标为未下载（`failed`，错误码 `E_FILES_MISSING`，删除残留文件，可在下载页重试）。
  漫画页在阅读器中解码失败时同样处理。离线时（详情取不到）可从「下载」页按快照打开目录与已下载章节：
  阅读器的详情取不到（任何错误）且该条目有下载时，改用下载时的 `detail()` 快照。进度照常写入 `HistoryRepository`。
- **删除**：按 unit / 条目删除，或在设置中查看总占用并清空；删除源时询问是否一并删除其下载（默认保留，标“源已删除”，仍可阅读）。
- **界面**：详情页「下载」（选择线路与章节范围，同导出）；书架新增「下载」页签（条目 → 章节状态、进度、暂停 / 继续 / 重试 / 删除）；
  章节列表上标出已下载。
- **安全**：下载的文件只作为图片解码或按 `NovelChapter` 结构反序列化，不交给任何 HTML / 脚本渲染器；
  路径不含外部字符串，不存在目录穿越。

### 4.5.1 视频下载与后台下载（M6 第二期）

> 状态：视频下载与离线回放已实现（2026-11）：`core/network/media/hls_download_plan.dart`（下载用的 HLS 解析与选择）、
> `aes128.dart`（与代理共用的解密）、`MediaProxy.openLocal`（本地来源会话）、`shared/download/video_downloader.dart`
> （`VideoDownloadTask`）与 `video_manifest.dart`（`video.json`、本地播放列表）；播放页对已下载剧集走本地会话。
> 后台下载（#74）也已实现：`shared/download/background_downloads.dart`（`BackgroundDownloadController`）与原生的
> `DownloadService.kt` / `MainActivity.kt`（Android）、`AppDelegate.swift`（iOS）。沿用 §4.5 的队列、表、目录规则与阅读器接入方式，这里只写视频特有的部分与后台下载。
>
> 实现细节（规范未写到的部分）：
> - 所选清晰度存为 `download_units.stream_label`（v8）。下载对话框的清晰度列表取自所选线路第一集的 `content()`（取不到时下载每集的第一个流）；
>   播放页的清晰度选择不持久化，因此默认取第一个。
> - `video.json` 存**结构**（每个轨道的分片时长、`DISCONTINUITY`、初始化分片与本地文件名），本地会话打开时由它重新生成 HLS（主播放列表
>   只含 `STREAM-INF`、音频 / 字幕的 `EXT-X-MEDIA`；子播放列表只含 `TARGETDURATION` / `MEDIA-SEQUENCE` / `PLAYLIST-TYPE` / `MAP` /
>   `DISCONTINUITY` / `EXTINF` / `ENDLIST`），源给出的名称 / 语言去掉引号与控制字符后才写入属性。字节区间引用的分片各自存为一个文件，
>   本地播放列表中不再有 `BYTERANGE`。同一子播放列表的代理地址扩展名取第一项的（FFmpeg 的扩展名检查，§6.4.3）。
> - 单文件下载直接写 `media.bin`（不经 `*.part`，以便跨重启续传），完成与否只看完成标记；HLS 分片与其他文件仍先写 `*.part` 再改名。
> - 外挂字幕：格式不可用（伪装成字幕的 HTML 等）与上游 4xx 的条目跳过（在线播放时它们同样只是“加载失败”），其他网络错误让剧集失败；
>   文件名序号与 `content.subtitles` 的下标对应。续传时 `lang` / `format` / `charset` 未变且文件仍在的沿用。
> - 暂停 / 删除视频剧集时**中止**进行中的分片请求（漫画 / 小说仍是当前请求结束后停止）。
> - 一个分片失败时其余并发请求随之中止，已写完的分片记入 `video.json`，重试时续传。`E_LIMIT` 时删除该剧集已写的全部文件。
> - 字节区间分片要求上游返回 206 且 `Content-Range` 起点一致，否则 `E_UNSUPPORTED`。
> - 播放列表：每个剧集的全部播放列表（主 / 子）合计不超过 16 MB，取一个播放列表或密钥不超过 60 s（从发出请求算起，含等响应头、挑战扫描与重试，不含限速排队）；
>   每取完一个子播放列表就累加检查 20000 个分片的上限，不先取完全部（至多 101 个）播放列表。
>   `EXT-X-KEY` 的方式按播放列表**原文**检查（改写时会整行删掉带其他 `…URI=` 属性的标签，不能据改写结果判断没有加密）。
> - 分片与单文件开头的识别只看前 1 KB，与代理相同。`StreamRef.headers` 中的 `Range` / `If-Range` 不发送（清单 `headers` 中的仍会由网络层加上，但没有发区间请求的单文件与分片都必须返回 200，
>   不会存下不完整的内容）；单文件的首个请求必须返回 200。离线打开单文件时实际长度必须与记录的 `Content-Length` 一致。单文件已写满但没有完成标记时，只取最后 1 个字节确认版本未变。续传的 206 响应还要求 `Content-Range` 终点正确、响应带的 `ETag` / `Last-Modified`（若有）与记录一致，否则从头下载。
> - 单文件的外挂字幕在媒体响应体读完之后再取（不让媒体连接闲置）；续传时外挂字幕按地址的 sha256 判断能否沿用。不再引用的 `sub-NN.*`（格式变了、条目没了、上次中途失败留下的）在每次取完字幕后删除。
>   任何路径上的 `E_LIMIT`（含播放列表 / 分片数超限）都删除该剧集已写的全部文件；写入 `video.json` 的文字按读取时的长度上限截断（显示用）或不保存（`ETag` 等参与续传的）。

已定的取舍（2026-11-23）：

| 项 | 决定 |
|---|---|
| 存储方式 | HLS 按分片原样落盘 + 一份指向本地文件的播放列表；回放仍经本地媒体代理（§6.4.3），不合并成单个文件 |
| 加密内容 | AES-128 分片下载时解密，**存明文**（应用私有目录）；不存密钥 |
| 字幕 | 外挂字幕（`content.subtitles`）与 HLS 自带的 WebVTT 字幕轨都下载 |
| 后台下载 | 与视频下载一起做，覆盖漫画 / 小说 / 视频的同一个队列（#74） |

**下载什么**

- 用户在下载对话框中按剧集选择，并选一个清晰度（`content.streams` 中非 DASH 的流，与播放页的清晰度菜单相同）；
  默认选与播放页记住的清晰度标签相同的流，没有则取第一个。
- **HLS**：主播放列表中选 `BANDWIDTH` 最高的变体；该变体引用的音频组只取 `DEFAULT=YES`（没有则第一条）的轨道；
  字幕组（`TYPE=SUBTITLES`，WebVTT）全部下载。只有子播放列表时直接下载它。**直播**（子播放列表没有 `EXT-X-ENDLIST`）不能下载，
  以 `E_UNSUPPORTED` 失败；`SAMPLE-AES` 等代理不解密的方式同样不能下载。
- **单文件**（`mp4` / `auto` 且根地址不是播放列表）：整文件下载，按字节区间续传（见下）。与 HLS 同样以 16 GiB 为上限：
  声明的 `Content-Length` 超过上限时不开始下载，未声明或声明不实时按实际写入的字节计数，超过即中止，都以 `E_LIMIT` 失败并删除已写部分
  （`openStream` 不受 `maxResponseBytes` 约束，上限由下载器自己执行）。
- **外挂字幕**：全部条目按 §2.2（source-spec）的规则取回（4 MB、30 s、格式识别），按原样保存为 `sub-NN.<ext>`，离线时由 Dart 侧解析显示。

**怎么取**

- 复用代理已有的部件而不复用代理会话：`hls_playlist.dart` 解析与过滤标签、`media_signature.dart` 识别容器、代理的 AES-128 解密，
  请求经该源的 `SourceHttpClient.openStream`（白名单与每跳重定向、Cookie、默认 headers、`StreamRef.headers`）。
  播放列表计入 `rateLimit`，分片、密钥、单文件的区间请求计入媒体配额（突发 10、每秒 10），与播放时相同。
- 每个剧集同时最多 3 个分片请求；队列规则（同源一次一个 unit、不同源最多 2 个）不变。
- 分片必须通过与代理相同的容器识别（字幕分片必须是 WebVTT），否则该剧集失败；单个分片沿用代理的上限（加密分片 64 MB），
  每个剧集最多 20000 个分片、合计不超过 16 GiB，超过以 `E_LIMIT` 失败。写入失败（磁盘满等）→ 该剧集 `failed`，错误码 `E_STORAGE`。

**怎么存**（目录规则同 §4.5：路径只由哈希与序号构成）

- 视频剧集目录下：`v/NNNNN.<ext>`（视频变体的分片与初始化分片，扩展名按代理“按内容命名”的规则）、`a/…`（音频轨）、
  `s<k>/NNNNN.vtt`（第 k 条 HLS 字幕轨）、`sub-NN.<ext>`（外挂字幕）、单文件为 `media.bin`。
- `video.json`：本地播放列表结构（由客户端重新生成的 HLS，只含代理会保留的标签；`EXT-X-KEY` 去掉，因为分片已是明文），
  每条地址换成本地文件名；字幕轨的名称 / 语言、外挂字幕的 `lang` / `format`；以及续传用的来源标识（见下）。
- 不保存密钥、播放列表原文与任何上游地址以外的会话信息；上游地址只在 `video.json` 的来源标识中以哈希出现。

**续传**

- HLS 按分片续传。来源标识**不用完整的分片地址**（很多站点的分片地址带有每次都变的签名参数）：用所选流的序号与 `quality`、
  变体的 `BANDWIDTH` / `RESOLUTION`、`EXT-X-MEDIA-SEQUENCE`、分片数，以及每个分片（含 `EXT-X-MAP` 初始化分片、`EXT-X-BYTERANGE`）的
  `EXTINF` 时长与**去掉查询串和片段后的地址**（基于播放列表的最终地址解析为绝对地址后，只取协议、主机、端口与路径）。继续时重新调用 `content()` 并取播放列表，
  标识一致才跳过已写完的分片，否则丢弃该剧集已下载的文件从头下载（与 §4.5 一致）。站点把签名放在路径里时标识每次都不同，
  续传退化为从头下载——宁可重下，也不把两个版本的分片拼在一起。仍可能漏判的情形（站点原地替换内容且路径、时长都不变）作为已知限制写进文档。
- 单文件按字节区间续传：记录已写入的长度与上游的 `Content-Length`、`ETag` / `Last-Modified`（有的话）。
  **只有在有校验值时才续传**：续传请求带 `Range` 与 `If-Range`（强 `ETag` 优先，否则 `Last-Modified`；弱 `ETag` 视为没有校验值），
  上游返回 206 且 `Content-Range` 的起点与总长度都与记录一致才接在后面写；返回 200、长度或校验值变了，则从头下载。
  上游没有任何校验值时不发区间请求，直接从头下载，避免把新版本的后半段接到旧版本的前半段上。

**离线回放**

- 播放页打开已下载的剧集时，不调用 `content()`，而是建立一个**本地来源**的代理会话：代理按会话编号返回本地文件，
  播放器看到的仍是 `http://127.0.0.1:<port>/<token>/…`（`protocol_whitelist` 保持 `http,tcp`，播放器不接触文件路径）。
  本地会话照常做容器识别、按编号查找（只认 `video.json` 中登记的文件），支持 `Range` / `HEAD`；不发任何上游请求。
- 外挂字幕从本地文件读取并解析（与在线时相同的解析器与 4 MB 上限）；HLS 字幕轨经本地播放列表提供，字幕菜单与在线时一致。
- 清晰度菜单只列已下载的那一个；进度、换集、自动下一集照常（下一集没有下载且在线时按在线方式打开）。
- 文件缺失 / 识别失败时与 §4.5 相同：标为未下载（`E_FILES_MISSING`）并在在线时回退到网络。

**后台下载**（#74，漫画 / 小说 / 视频共用同一队列）

- **Android**：队列中有任务时启动前台服务（`foregroundServiceType="dataSync"`），常驻通知显示总进度与「暂停全部」；
  Android 13+ 首次下载时请求通知权限，拒绝时仍可下载（只是没有通知）。队列清空或全部暂停时停止服务。
  Android 15 起 `dataSync` 前台服务每天累计限 6 小时，超时被系统停止后队列暂停，回到前台继续。
  下载仍在 Dart 中执行（同一个 isolate 与网络层），服务只负责让进程保持在前台优先级。
- **iOS**：系统不允许任意时长的后台执行，后台 `URLSession` 又无法经过本项目的网络层（白名单、每源 Cookie、解密），因此只做
  “进入后台后用尽系统给的宽限时间”（`beginBackgroundTask`，通常约 30 s），到期前把进行中的任务记为 `queued` 并暂停，回到前台继续；
  文档与下载页说明这一限制。是否另用 `BGProcessingTask` 在充电 / 空闲时继续，留待实现时评估。
- **实现（2026-11）：不引入第三方插件**，用本项目自己的 `MethodChannel`（`io.github.tsumugi/background_download`）：
  Android 为 `DownloadService`（前台服务，系统通知 API，不依赖 androidx）与 `MainActivity` 中的通道，iOS 为 `AppDelegate` 中的
  `beginBackgroundTask`。需要的只是“启动 / 更新 / 停止一个前台服务”和“申请宽限时间”，几十行原生代码即可；现有插件
  （如 `flutter_foreground_task`、`flutter_background_service`）都另起 isolate 或后台引擎来执行任务，而这里的下载必须留在主 isolate
  （共用网络层、会话与数据库），用不上它们的主要功能，反而多一层原生依赖与许可证审查。Windows 不需要（桌面应用不会被挂起）。
  - Dart 一侧（`BackgroundDownloadController`）订阅 `download_units`：有 `queued` / `running` 时（每秒至多一次）更新通知，
    文字为“正在下载 n 项，剩余 m 项”，进度为下载中的 unit 已完成文件数之和 / 总数之和；第一次显示前请求通知权限。
  - 「暂停全部」→ 全部未完成的 unit 记为 `paused`。时限到或宽限时间将尽 → `DownloadManager.suspend()`：进行中的任务记为 `queued`
    （视频分片请求立即中止，漫画 / 小说的当前请求结束后丢弃结果），不开始新任务；回到前台 `resumeQueue()`。iOS 的宽限时间按 `backgroundTimeRemaining`（刚进入后台时可能仍为“无限”，按 25 s 计）提前 5 s 挂起。系统的到期回调先让 Dart 挂起队列、等它回复（最多 1 s）再结束后台任务；回到前台时把没有任务在跑的 `running` 改回 `queued`（进程在挂起写完前被冻结时的兜底）。
  - 从后台启动前台服务会被 Android 12+ 拒绝：服务只在应用在前台、队列开始有任务时启动，之后在后台只更新通知。
    启动失败、进入前台失败（`startForeground` 被拒）或时限已到时，本次进程内不再尝试，进入后台时与 iOS 一样挂起队列。
    Flutter 引擎销毁（界面被销毁、从最近任务划掉，`stopWithTask`）时停止服务，下载也随之停止。
  - 未做：`BGProcessingTask`（iOS 在充电 / 空闲时继续）——它在系统选定的时机冷启动或唤醒应用，下载需要的源实例、会话与数据库都要在没有界面的情况下
    重建，且同样有时限；收益不确定，留待需要时再评估。

**安全**

- 落盘的是解密后的第三方内容明文，只在应用私有目录；删除剧集 / 条目 / 源的下载时删除文件。崩溃留下的临时文件（`*.part`）在启动时清理。
- 回放仍经代理，播放器侧的深度防御（§6.4.3）不变；本地会话不能被用来读取下载目录之外的文件（只按编号查表，不接受路径）。

### 4.6 WebDAV 同步（M6，`shared/sync/`）

- **服务器配置**：地址、用户名、密码，以及远端目录（默认 `Tsumugi/`）。密码存系统安全存储
  （[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)，BSD-3：Android Keystore、iOS Keychain、
  Windows DPAPI），**不写入数据库或应用自己的任何文件**（Windows 上由插件写 DPAPI 加密的文件）。只允许 `https`（回环地址例外，用于测试）。
  WebDAV 客户端用 dio 自行实现所需的 `PROPFIND` / `MKCOL` / `GET` / `PUT`，不引入额外依赖。
- **数据文件**：远端一个 `sync-v1.json`（gzip 压缩，解压后不超过 20 MiB）。内容是按记录的集合：书架条目、条目进度、unit 进度、
  已安装源、仓库订阅；每条记录带 `modifiedAt`（UTC 毫秒）与写入设备的 `deviceId`，删除以墓碑记录（`deleted: true`）表示。
  文件头有 `syncVersion`，高于客户端支持的版本时拒绝同步并提示更新客户端。
- **本地改动记录**：新增 `sync_state`（本机 `deviceId`、上次同步时间与远端 ETag）与 `sync_tombstones`（被删除记录的表、主键、
  删除时间）；参与同步的表新增 `modifiedAt` 列（与业务上的 `updatedAt` 区分：例如书架的分类、排序变化也要更新 `modifiedAt`）。
- **合并**：按记录主键逐条比较，`modifiedAt` 大者胜；相同时按 `deviceId` 字典序决定（确定性，两台设备得到同一结果）。
  墓碑同样参与比较；unit 进度的已读标记与位置作为同一记录整体比较。
  - **远端没有的本地记录**：若该记录的 `modifiedAt` 不晚于本机上次**成功**同步的时间，说明它上次已上传、之后被别的设备删除
    （墓碑可能已清理），按删除处理；晚于上次同步时间的（本机之后新建或修改的）保留并上传。从未同步过的设备，本地记录全部保留。
    因此墓碑只是加速与保留删除时间的手段，保留 90 天后清理不会让长期离线设备把已删除的记录“复活”。
  - “上次成功同步时间”只在 `PUT` 成功（或远端未变、无需写入）后更新；更换服务器地址或远端目录时清空，按从未同步处理。
  - **远端整个文件不存在**（被删除、换了目录）时也按从未同步处理，本地记录全部保留并重新上传，不会因为文件丢失而清空本地；
    远端文件中缺少某个集合时，该集合同样按从未同步处理。
- **写入**：先 `GET`（带上次 ETag，未变则跳过下载）→ 合并 → 写本地 → `PUT`：远端已有文件时带 `If-Match: <ETag>`，
  远端还没有文件（首次同步）时带 `If-None-Match: *`，避免两台设备同时首次同步时互相覆盖。收到 412 说明期间有别的设备写入，
  重新下载、合并、再写，最多 3 次。服务器不返回（强）ETag 或不支持条件请求时退化为“读—合并—写”，并在设置中提示“服务器不支持并发保护”。
- **源的同步需要用户确认**：合并结果中**本机没有的源**或**清单有变化的源**，不直接安装，而是列出（名称、来源、将访问的主机，
  主机变化同 §4.4 高亮）等用户确认；未确认的保留在“待安装”列表里。理由：远端文件可能被他人修改，清单安装必须和本地导入一样经过预览。
  已有源的启用状态、排序与设置直接合并（设置写入前照常经 `sanitizeSettingValues` 过滤）。
- **触发**：手动「立即同步」；启用后在应用启动、回到前台、以及本地有改动后 2 min 内自动同步；同时只有一个同步在进行。
  失败只在设置页显示最近一次的错误，不打断阅读。
- **不同步的数据**：见 §4.3 的表。远端文件是明文 JSON（压缩），存放在用户自己的服务器上；设置页说明这一点。

**实现细节（M6 实现时补充）**

- **`modifiedAt` 由 SQLite 触发器维护**（`core/storage/sync_triggers.drift`），不在各仓库方法里手写：参与同步的表
  （`library_entries`、`item_progress_entries`、`unit_progress_entries`、`installed_sources`，以及 `source_repositories`）插入后、
  或参与同步的列变化后，把 `modified_at` 置为当前 UTC 毫秒；删除后在 `sync_tombstones` 记一条墓碑（仅在已配置服务器时记录，
  未启用同步的用户不会积累墓碑），重新插入同一主键时删除其墓碑。这样以后新增的写入路径也自动被跟踪。
  只改不参与同步的列不算改动：例如书架的 `updatedAt`（详情页每次刷新元数据都会写）、已安装源的冗余索引列与 `updatedAt`。
  同步把合并结果写回本地时置 `sync_state.applying = 1`（与写入在同一事务中），触发器据此不改 `modified_at`、不记墓碑。
- **记录格式**：`{"syncVersion": 1, "collections": {"library": [...], "itemProgress": [...], "unitProgress": [...],
  "sources": [...], "repositories": [...]}}`，每条 `{"key": [主键…], "modifiedAt": 毫秒, "deviceId": "…", "deleted": false, "data": {…}}`
  （墓碑没有 `data`）。不认识的集合与记录顶层的未知字段原样保留并写回（`data` 内的未知字段只在远端记录胜出时保留：本机胜出时按本机的列重建 `data`）；JSON 嵌套超过 64 层的文件按格式错误拒绝；`data` 不合法的记录不应用到本地，但仍保留在远端文件中。
  已安装源的 `data` 为 `manifest`（清单原文）、`enabled`、`sortOrder`、`settings`、`originKind`、`originUrl`（以及 m6-repo 的所属仓库地址）。
- **本地记录的 `deviceId` 不单独存列**：本地行与远端记录 `modifiedAt` 相同且内容相同，视为同一条（沿用远端的 `deviceId`）；
  内容不同则本地是本机写入的，`deviceId` 取本机。合并结果中本机胜出的记录写本机 `deviceId`。
- **“上次成功同步时间”取本地快照时刻减 1 ms**：快照在读本地数据的事务中取 SQLite 时钟 `T`，`PUT` 成功后记为 `T - 1`；
  这样快照之后（哪怕同一毫秒）的本地改动都晚于它，不会在下次同步被误判为“已上传后被删除”。
- **源的取舍**：本机已有、清单相同的源，远端胜出时直接合并启用状态、排序与设置（设置经 `sanitizeSettingValues` 按本机清单过滤）；
  来源（`originKind` / `originUrl`）不直接合并，也不参与“内容是否相同”的比较。远端胜出且本机没有或清单不同时进入“待安装”：
  本机行（若有）只合并启用 / 排序 / 设置，保持原 `modifiedAt`，下次同步远端仍胜出，结果稳定。用户在设置页逐个预览确认安装
  （`SourceRegistry.prepareImport`；安装后的来源一律记为本地来源“WebDAV 同步”——同步文件里的来源是远端声称的、未经验证，预览中标为“未验证”，不据此把源记为来自某个仓库），装好后把远端的启用 / 排序 / 设置与 `modifiedAt` 写入本机行。
  “待安装”列表存于 `sync_state.pending_sources_json`，每次同步按合并结果重算；用户“忽略”的项在该记录的 `modifiedAt` 变化前不再出现。
- **仓库订阅**：记录主键为规范化后的 `index.json` 地址，`data` 只有 `addedAt`。名称与索引不同步，检查更新时刷新它们也不算改动；同步来的新订阅先以地址作名称、索引为空，等本机下次检查更新时取得（取索引照常经 `RepositoryHttpClient` 的全部限制）。地址必须通过 `normalizeRepositoryUrl` 且与规范化结果相同，否则该记录不应用。同步来的订阅只会让本机去取该仓库的索引并提示可更新，安装与更新仍须用户预览确认。退订同样同步；已装的源保留（显示“仓库已移除”）。
- **清单按版本取高者**：同一个源两边都有时，整条记录按 `modifiedAt` 决定启用 / 排序 / 设置，但清单取版本较高的一方（`RowRecords.newerManifest`）。否则还没更新的设备改一下启用状态，就会用旧清单覆盖远端，其他设备得到一个无法安装的“降级”。
- **时钟与篡改**：远端记录的 `modifiedAt` 比本机时钟晚 1 天以上时按“现在”处理，避免一条未来时间的记录或墓碑永远压过本机的修改。
- **服务器不支持条件写入时**（远端文件没有 ETag，或只有弱 ETag `W/…`）：“远端没有且不晚于上次同步时间的本地记录按删除处理”这条规则不生效，删除只靠墓碑传播——没有并发保护时，远端可能被别的设备的无条件写入覆盖，不能把“远端没有”当成“已被删除”。代价是墓碑过期（90 天）后，长期离线的设备可能让已删除的记录重新出现。
- **密码只用于同一服务器**：配置时密码留空表示沿用已保存的密码，但只限协议、主机、端口与用户名都没变；否则必须重新填写，并先删除旧密码再保存新配置（`sameCredentialScope`）。
- **远端快照缓存**：`GET` 返回 304 时需要上次的远端内容才能合并，因此 `sync_state` 同时保存上次远端文件的压缩字节与 ETag。
- **代码结构**：`shared/sync/` 下 `webdav_client.dart`（地址校验与四个方法）、`sync_document.dart`（文件格式、gzip 限长解压）、
  `sync_merge.dart`（纯函数合并，单元测试覆盖合并规则）、`sync_records.dart` / `sync_store.dart`（表与记录的转换、在一个事务中
  读快照—合并—写回）、`sync_service.dart`（下载—合并—上传、412 重试、待安装源的预览与安装）、`sync_scheduler.dart`（自动触发）、
  `credential_store.dart`（`flutter_secure_storage`）；界面在 `features/settings/sync/`。mock 服务器的 `/dav/` 是测试用的最小 WebDAV。
- **客户端**：独立的 dio 实例，无 Cookie、固定 UA、不跟随重定向（3xx 视为错误，凭据不会被带到别的地址）、每个请求（含读完响应体）总时长 60 s，超时取消；不接受传输压缩（`Accept-Encoding: identity`，避免代理改写 ETag）；上传带 `Content-Length`；错误响应体最多读 64 KiB；
  只支持 Basic 认证（经 HTTPS）。地址中不允许带用户名 / 密码。下载的文件压缩后、解压后都不超过 20 MiB，单个源清单不超过 4 MiB。

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

**发现页**（#57）：应用外壳的独立标签页「发现」（`/explore`，位于「搜索」与「源」之间），而不是搜索页内的切换。
理由：搜索是“输入关键词、对所有源并发”，发现是“一次浏览一个源的分类”，两者的状态（关键词 / 媒体类型 vs. 源 / 分类 / 列表）
和空状态都不同，放在一页里会让两套状态互相干扰；独立标签页也让发现页在切换标签时保持滚动位置与已加载的页。

```
UI(explore) → exploreSources（已启用、清单可用、提供发现页）→ 选源 → source.explore() → 分类
           → 选分类 → source.exploreList(categoryId, page)，逐页追加 → 点条目进入详情（按源类型，与搜索一致）
```

- 实现：`features/explore/explore_controller.dart` 的 `ExploreController`；源列表来自注册表的 stream，所有媒体类型都列出
  （下拉框显示「源名（类型）」）。“提供发现页”只看清单、不创建源实例：声明式为 `rules.explore` 非空；脚本为源码中出现
  `explore` 这个名字（ES 模块导出名是静态的，不会漏掉源；误判的源调用时报 `E_UNSUPPORTED`，按出错显示）。
- 换源 / 换分类递增代号，过时结果丢弃；每次调用受 `exploreTimeoutProvider` 限时（默认 30 s）。分类与列表的加载、出错、空状态与
  搜索页一致：出错用 `SourceErrorView`（`E_CHALLENGE` / `E_LOGIN_REQUIRED` 可「打开验证页」，完成后自动重试），
  翻页失败保留已加载条目并在列表末尾显示重试。AppBar 的「刷新」重新加载分类与当前分类的第一页。
- 上次选择的源与分类保存在应用支持目录的 `explore.json`（`explorePreferencesStoreProvider`，测试中用内存），再次打开时恢复；
  该源已被禁用 / 删除时改选第一个可用源，分类不存在时选第一个分类。
- 列表条目行与“按类型打开详情”是 `features/common/search_item_tile.dart`，搜索页与发现页共用。

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
  video : StreamRef(url, headers, type) → 本地媒体代理（源的网络层）→ media_kit
  music : StreamRef + 可选歌词        → 本地媒体代理 → media_kit + 后台播放服务
```

**视频播放（M4，`features/video/`）**：详情 `/video/:sourceId/:itemId`（通用详情页），播放页
`/video/:sourceId/:itemId/play/:unitId?pos=<毫秒>`（`VideoRoutes`）。流经 `openProxiedStreamProvider`（`shared/video/`）
建立代理会话后交给 media_kit；控件见下文「控件」。

- **线路与选集**：线路即 `unitGroupsOf(detail)`（`groups` 非空时为各线路，否则 `units` 为唯一一条）。播放页下方列出当前线路的剧集，
  多于一条线路时可切换；切换线路时取另一线路中**标题相同**的剧集，没有则取同一下标，并保持当前位置。
  上一集 / 下一集按当前线路的顺序；播放完成后自动播放下一集（最后一集停在结尾）。换集在页面内完成，不改变路由。
- **清晰度**：`content.streams` 中非 DASH 的流即可选的清晰度（标签为 `quality`，缺省为“流 n”），多于一个时在标题栏菜单中切换。
  切换时为新流建立代理会话，并以 `Media.start`（mpv `start`）从当前位置打开（Android 上见 §6.4.2 的重新打开）。换集时优先选与当前标签相同的流，否则取第一个。
- **进度**（`VideoProgressRecorder`）：`HistoryRepository.recordProgress(position:)`，`position` 为毫秒。播放中按条目节流（5 s），
  暂停、换集 / 换线路 / 换清晰度、离开页面时立即写入。播放完成或位置到达时长的 97% 时标记已读并把位置记为 0（再次打开从头播放）。
  打开时的起始位置：`?pos`（详情页“继续播放”）→ 该剧集的 unit 进度 → 0。
- **条目快照的封面请求头**（#24）：`Detail` 没有 `coverHeaders`，`videoItemSnapshot` 打开时依次取书架条目、
  已有历史中的值（封面地址相同时），最后回退到源清单的默认 headers；漫画 / 小说阅读器交给 `recordProgress` 解析（见 §4.2）。
- **控件**：按 `Theme.platform` 区分。桌面（Windows）沿用 media_kit 的 `MaterialDesktopVideoControls`：空格播放 / 暂停、
  左右方向键快退 / 快进、双击或按钮进入窗口全屏（media_kit 推入全屏路由），行为不变。
  Android / iOS 用自己的触控控件（`VideoTouchControls`，`Video` 本身不带控件），只经 `VideoPlayback` 接口操作播放器（便于 widget 测试）：
  - 单击显示 / 隐藏控件（播放中 3 s 无操作自动隐藏）；双击播放 / 暂停；横向拖动定位，拖动时在画面中央显示目标时间 /
    时长，松手才 seek（整屏宽度对应 90 s，不超过时长）；长按临时 2 倍速，松手恢复原倍速（暂停时不生效）。
  - 底栏为播放 / 暂停、进度条、时间与全屏按钮；全屏时顶栏为返回、标题与清晰度 / 倍速菜单（非全屏时它们在页面标题栏）。
  - 加载中（见 §6.4.2 的加载遮罩）不响应手势、不显示底栏；全屏时仍显示顶栏的返回按钮。
  - 音量 / 亮度手势未做：需要新的原生依赖（系统音量、窗口亮度），留待评估。
- **移动端全屏**（`VideoFullscreenController`，只在 Android / iOS）：在同一页面内切换布局（不推新路由；播放器子树用 `GlobalKey`
  保留状态），隐藏标题栏与选集面板，系统栏进入 `immersiveSticky`。方向按视频宽高比：宽 ≥ 高（或尚不知道尺寸）时锁定横屏
  （左右两个方向），否则锁定竖屏。退出全屏时恢复系统栏（`edgeToEdge`），手机（最短边 < 600 dp）锁回竖屏、平板不限制方向；
  离开页面时恢复系统栏并解除方向限制。返回键 / 返回手势在全屏时只退出全屏（`PopScope`），再按才离开页面。出错时自动退出全屏。
- **屏幕常亮**：用 media_kit `Video` 的 `wakelock`（经 `wakelock_plus`，按播放状态开关，`Video` 销毁时释放）：播放时常亮，
  暂停、播完、出错、离开页面时取消。全屏不另建 `Video`，不影响计数。
- **切到后台**（Android / iOS）：应用进入 `hidden` / `paused` 时暂停，回到前台不自动播放；正在加载时进入后台的，加载完成后立即暂停
  （包括后台播完自动打开下一集）。桌面沿用 media_kit 的默认行为（只在 `paused` 时暂停）。后台播放留给 M5。
- **字幕**（M4，方案与安全边界见 §6.4.7）：标题栏（移动端全屏时在顶栏）的字幕菜单列出「关闭」、`content.subtitles` 中的
  外挂字幕（标签为 `lang`，缺省为“字幕 n”）与 HLS 流自带的字幕轨（字幕播放列表，标签为 libmpv 报告的轨道标题 / 语言，带“（内嵌）”；
  FFmpeg 不把 `EXT-X-MEDIA` 的 `NAME` 作为标题，实际为 `LANGUAGE`，都没有时为“内嵌字幕 n”；与前面的轨道同名时附上序号，如 `zh 2`）。
  两者都由页面自己的字幕层（`VideoSubtitleOverlay`）显示，media_kit 的 `SubtitleView` 与 libmpv 自己的字幕渲染都不用；
  字幕层放在 `Video` 的控件构造器里，因此桌面的窗口全屏路由中同样显示，位于控件之下。
  - 外挂字幕只在选中时才取（每条每集最多一次，结果缓存到换集；换集、离开页面时取消仍在进行的请求），取回后在 Dart 中解析为纯文本的时间轴。
    加载失败时提示原因并退回“关闭”（不记住），本集不再自动选择其他字幕，播放不受影响。
  - **记住选择（按源）**：用户在菜单中选择后，按源记住“关闭”或所选的标签（应用支持目录 `video_subtitles.json`）。
    换集、重新打开时按记录选择：先找标签相同的外挂字幕，再找名称 / 语言相同的内嵌轨；没有记录或找不到时，选第一条外挂字幕，
    没有外挂字幕则关闭（内嵌轨只在记录指明时才选）。记录的标签没有对应的外挂字幕时，先保持关闭，等当前流开始播放、
    轨道列表确定后再决定（它可能是内嵌轨，不先去取外挂字幕）。记录文件串行写入、经临时文件改名替换。按源而不是全局：各源的语言标签写法不同（`zh` / `中文` / `简体`），
    全局记录难以跨源匹配；是否需要字幕也因源而异（有的源是硬字幕）。
  - **与清晰度 / 换集联动**：换清晰度时外挂字幕保持（同一份时间轴，不重新请求）；内嵌轨属于具体的流，换清晰度后按记住的标签重新自动选择：
    新流有该轨道时选上，没有（如 MP4）时按默认规则，换回原来的流时再选回内嵌轨。换集时按上一条重新选择。未选内嵌轨时让 libmpv 也不选字幕轨（`sid=no`），不多取字幕分片。
    新流开始播放时总是再设置一次字幕轨：打开期间轨道列表经历“有 → 空 → 有”，media_kit 记录的当前轨道与 libmpv 实际的 `sid`
    可能不一致（Android 真机上，换集后自动选择的内嵌轨曾经没有字幕）。

**图片加载（M2，`shared/image/`）**：所有源图片（封面、漫画页）经 `SourceImageLoader` 加载：
内存 LRU（编码后字节，默认 64 MB）→ 磁盘 LRU（应用缓存目录 `images/`，默认 512 MB，
键 = sha256(sourceId + url)）→ 该源的 `SourceHttpClient`（因此遵守白名单、限速、默认 headers；
`ImageRef.headers` 随请求发送）。同一图片的并发请求合并，全局并发上限 6；超时 / 连接错误额外重试 1 次，
字节无法解码时清除缓存条目。界面使用 `SourceImageProvider`（`ImageProvider`）或 `SourceImage` / `CoverImage` 组件，
不直接使用 `Image.network`。图片客户端与源实例共用该源的 `SourceSession`（Cookie 与 UA，§5.3）。
**下载进度**（#26）：网络层边读边检查 `maxResponseBytes`（声明的 `Content-Length` 超限时不读响应体，未声明时读到超出的那一块即中止），
并经 `NetRequest.onReceiveProgress` 上报已收字节与 `Content-Length`（只对 2xx 的最终响应；重定向中间响应、错误页不上报）。
加载器把它转为 `ImageChunkEvent`，阅读器页面与 `SourceImage` / 封面的占位用 `ImageLoadingIndicator` 显示确定进度。
已知限制：没有 `Content-Length`、或响应经过内容编码（gzip 等，收到的是解压后的字节）时总长度未知，退回不确定进度；
网络层或加载器重试时进度从 0 重新开始；排队（并发名额 / 限速）期间封面不显示进度，阅读器显示不确定进度。

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
- 封面（仅 EPUB）经统一图片加载器（`SourceImageLoader`，走该源的网络客户端：白名单、限速、Cookie 与默认 headers）
  取得（按文件头识别 PNG / JPEG / GIF / WebP），失败或不认识则不放封面。
- **正文图片**（仅 EPUB，#25）：正文取完后，按首次出现顺序逐张（一次一张）经同一图片加载器下载，同一地址只下载一次，
  headers 与阅读器相同（`NovelChapter.imageHeaders`）。单张失败、格式不认识、超过单张上限（默认 10 MiB）
  或会使合计超过总上限（默认 100 MiB）的图片保留「［图片：alt］」占位，不影响整本导出；合计达到上限后不再下载其余图片。
  单个响应另受网络层 `maxResponseBytes` 限制。下载期间可取消。
- 文件在后台 isolate 中生成（`Isolate.run`），避免大部头卡住界面。
- **TXT**：UTF-8（可选 BOM，兼容旧版 Windows 记事本），头部为书名 / 作者 / 来源源名 / 导出时间 / 简介，之后逐章
  “标题 + 正文”；段落一行、段首两个全角空格，`rt` 注音丢弃（ruby 只取正文），图片为「［图片：alt］」占位。
- **EPUB 3**：`mimetype` 为首个条目且不压缩（无扩展字段）→ `META-INF/container.xml` → `OEBPS/content.opf`
  （`dc:identifier` 为由 sourceId + itemId 派生的稳定 UUID）、`nav.xhtml`、兼容 EPUB 2 的 `toc.ncx`、`style.css`、
  可选封面页、书名页、每章一个 XHTML。正文由 `NovelChapter` 重新生成，`body` 内只使用 source-spec §2.2.1 白名单中的标签、
  不带属性（`img` 的 `src` / `alt` 除外）。已下载的正文图片写为 `OEBPS/images/img-NNNN.<ext>`、在 OPF manifest 中登记
  （id `img-NNNN`，`media-type` 按文件头），正文中为 `<div><img src="images/…" alt="…"/></div>`；其余图片为占位文字。
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
`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`。上游发布含这些修复的稳定版后应切换回去（[#27](https://github.com/Shiroha23/Tsumugi/issues/27)）。

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
  Cookie 对图片同样有效。源被删除时丢弃其会话。会话按源持久化，重启后登录 / 验证状态仍有效，见下方「会话持久化」。
- **会话持久化**（[#21](https://github.com/Shiroha23/Tsumugi/issues/21)）：`SessionPersistence`（`core/network/session_persistence.dart`）
  把每个源的 Cookie 与 WebView 同步来的 User-Agent 存为**一个源一个文件**：
  `<应用支持目录>/source_sessions/<sourceId 的 UTF-8 字节的 sha256>.json`（应用支持目录不会被系统当作缓存清理；
  文件名定长，不受 sourceId 长度影响——清单不限制 id 长度，直接编码可能超过 255 字符的文件名上限；
  也避开 `..`、Windows 保留名与大小写不敏感的文件系统带来的冲突）。
  - 选型：不用 `cookie_jar` 自带的 `PersistCookieJar`——它按主机分多个文件、非原子写入、并发写可能交错，
    读到损坏文件时抛异常；也不放进 drift，Cookie 读写频繁且与业务数据无关，单独的小文件更易隔离与删除。
    内存中仍是 `cookie_jar` 的 `DefaultCookieJar`，外面依次包 `PersistingCookieJar`（读写前等待加载、写后落盘、
    读取时剔除并清理已过期的 Cookie）与 `SecureCookieJar`（Secure Cookie 不经 http 发送）。
  - 隔离：每个 `SourceSession` 只读写自己 sourceId 对应的文件，Jar 实例不共享；WebView 同步
    （`importCookies`）与响应 `Set-Cookie`、`tsumugi.cookies.set` 都经同一个 Jar，因此都会持久化。
  - 写入：每次变更后把**整个会话的当前快照**写到临时文件再重命名替换（原子写）。同一源的读、写、删除
    在一个队列里串行执行；排队中的写入合并为一次，执行时取最新快照，所以并发写入不会丢数据。
    写入失败只记日志，不让请求失败。
  - 内容：会话 Cookie（无过期时间）也持久化（登录 Cookie 常是会话 Cookie）；写入 Jar 时把 `Max-Age` 换算为绝对过期时间
    （RFC 6265 §5.3：`Max-Age` 优先于 `Expires`），并把过期时间限制在 400 天内（RFC 6265bis 的上限，也避免超出 `DateTime` 范围）；
    已过期的 Cookie 在加载、读取与写入时都会被丢弃，加载时丢弃了条目会立即改写文件。
  - 损坏：文件无法解析时删除该文件、记录日志并从空会话开始；单个无效 Cookie 只跳过该条。
  - 生命周期：源被删除时关闭其会话（之后的写入被忽略）并删除文件——源页面删除时直接调用，
    不依赖会话管理器此前是否已创建；registry 推送的删除同样处理。应用启动后第一次读到已安装源列表时，
    清理不属于任何已安装源的文件（及残留的临时文件）；是否保留在每个文件真正删除前（该源的队列中）重新判断，
    列目录期间新安装的源不会被误删。源升级 / 覆盖安装不改变 sourceId，会话保留。
    源页面每个源的菜单提供「清除 Cookie 与登录状态」：清空该源的 Cookie、UA 与最近挑战地址并删除文件。
- **打开**：地址必须在该源的 `HostPolicy` 白名单内。`SourceErrorView` 打开的是最近一次触发挑战的地址
  （网络层检测到挑战时记录在会话中），没有时为 `baseUrl`；脚本打开的是它给出的地址。
  源页面菜单「登录 / 打开网页」（[#59](https://github.com/Shiroha23/Tsumugi/issues/59)）经
  `SourceVerification.openLoginPage` 打开清单的 `loginUrl`（缺省 `baseUrl`；清单校验已保证在白名单内，打开前再按
  `HostPolicy` 检查一次，不通过则报 `E_HOST_NOT_ALLOWED`），与「打开验证页」走同一个 `SourceVerifier`（用户主动发起，
  不受脚本节流限制，与进行中的验证页单飞），完成后只提示已保存 Cookie，不重试任何请求。
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
- **并发与节流**（`SourceVerifier` + `WebViewThrottle`）：同一时刻只显示一个验证页；用户发起的同源请求共用
  进行中的那一次（脚本发起的不共用）。脚本发起的打开另有限制：应用不在前台、已有验证页打开（含用户打开的）、该源上次**由脚本打开的**验证页关闭后 30 s 内
  （用户取消后为 2 min）都直接以 `E_CHALLENGE` 拒绝而不弹窗（用户主动打开的、未能显示的不计入冷却）；单次入口调用最多一次 `openWebView`（第二次 → `E_LIMIT`）。
  用户点击「打开验证页」不受节流限制。`ui.toast` 每源每 2 s 最多一条，应用不在前台时丢弃。
- **错误码**：用户取消 → `E_CHALLENGE`；平台不支持 WebView / 缺少 WebView2 Runtime → `E_UNSUPPORTED`。
  `SourceErrorView` 对 `E_CHALLENGE` 与 `E_LOGIN_REQUIRED` 显示「打开验证页」，完成后自动调用重试回调；
  搜索、详情、阅读器复用同一入口（`openSourceVerification`）。
- **等待时长**（#23）：`openWebView` 进行中时引擎暂停单次调用的 30 s 总时长，改按单独的 10 min 上限
  （`ScriptLimits.interactiveTime`）计时，见 source-spec §4.4；只在没有其他宿主请求未完成时暂停，与之重叠的请求照常计时。worker 内的 `QuickJsScriptRuntime` 与主 isolate 的看门狗
  各自计时（交互式路径为 `interactiveHostPaths`），看门狗是否暂停只由主 isolate 自己执行该宿主函数决定。
  超过上限时验证页仍保持打开，用户完成后 Cookie 照常写回，但这次调用以 `E_LIMIT` 失败。
- **界面层超时**（[#65](https://github.com/Shiroha23/Tsumugi/issues/65)）：搜索 / 发现页的超时（`searchTimeoutProvider` /
  `exploreTimeoutProvider`，30 s）经 `runSourceCall`（`sources/source_call.dart`）执行：
  - `ScriptSource` 实现 `UserWaitReporting`，`ui.openWebView` 进行中时 `waitingForUser` 为 true；此期间界面超时暂停
    （排在这次等待之后的同源调用同样暂停），等待用户本身仍受 `interactiveTime` 限制。
  - 等待状态按调用归属：只统计当前进行中的入口调用发起的 `openWebView`；调用结束（含取消、超限）后即使验证页仍开着也不再算等待。
    等待结束后界面超时重新给出完整的 30 s（用户刚完成验证，后续带新 Cookie 的请求不应因此前用掉的时间而被取消）。
  - 超时后取消这次调用：`SourceCallTicket` 经 zone 传给源，`ScriptSource` 在入口调用开始时读取；排队中被取消的调用不再执行，
    执行中的调用经 `IsolateScriptRuntime.cancelCurrent` 中止（worker 内 JS 运行时重建，进行中的请求随调用作用域取消），
    该源的串行队列随即释放。worker 正在同步执行 JS 时取消在这段 JS 结束（最长 `cpuTime`）后生效；worker 无响应时
    取消不会生效，队列要等看门狗放弃 worker（`wallTime + hangGrace`）才释放。声明式源忽略票据（其调用没有串行队列，结果被丢弃）。
  - 新一轮搜索、换源 / 换分类或页面销毁时，上一轮仍在进行的调用同样被取消。
  - 错误：`SourceCallTimeoutException`；本次调用自己打开过验证页时（`awaitedUser`，排在别的调用之后等待不算）
    显示「验证后仍然超时」并提供「打开验证页」。
- 测试中用假的 `WebViewLauncher` / `WebCookieStore`，不启动真实 WebView；手动验证用
  `tool/mock_server` 的 `/challenge/page`、`/login` 与 `test/fixtures/sources/mock_comic_gated*.json`。

### 5.4 网络层（M1）

`lib/core/network/` 提供按源隔离的 HTTP 客户端，声明式引擎与脚本宿主 API（`tsumugi.http` /
`tsumugi.cookies`）共用同一抽象：

- `SourceHttpClient`（接口）/ `DioSourceHttpClient`（dio + cookie_jar 实现）：按源构造，持有该源的默认 headers、
  超时与 `HostPolicy`；Cookie Jar、UA 与**限速令牌桶**在按源的 `SourceSession` 中（`SourceSessions.of(sourceId)`）。
  同一源的源实例、图片加载与每次播放的媒体代理客户端都用同一个会话，因此共用同一个令牌桶（source-spec §5）；
  不同源的会话（Cookie、UA、令牌桶）互不相通。重定向由客户端逐跳处理以便对每一跳做白名单检查；行为细则见 source-spec §5。
- **限速**（`TokenBucket`，FIFO，排队期间可取消且不消耗令牌）：会话按 `RateLimitConfig` 的取值各保留一个桶——源升级改了
  `rateLimit` 时，按旧清单构造、尚未关闭的客户端（图片客户端失效后延迟 30 s 关闭）继续用旧桶，新客户端用新桶，二者不会互相重置。
  请求分两条**通道**（`RateLimitLane`）：`source`（默认，`request` 只用它）计入清单的 `rateLimit`；`media` 只经
  `openStream(lane: media)` 使用，计入每个源单独的固定媒体配额（`SourceSession.mediaRateLimit`，突发 10、每秒 10）。
  只有媒体代理会选 `media`（HLS 分片与密钥、确认是媒体后的单文件区间请求），脚本与声明式规则无法选择通道。
  图片加载器全局最多 6 个下载并发，因此源实例的请求在共用队列中最多排在几个图片请求之后。
- `SourceNetworkConfig`：纯 core 类型；由清单生成的函数 `networkConfigFromManifest` 位于
  `lib/sources/network_error_mapping.dart`（core 不依赖 sources）。
- 错误统一为 `NetworkException(kind)`，`NetworkErrorKind` 与 source-spec §6 错误码一一映射
  （`NetworkException.toSourceException()`，同样在 sources 一侧）。
- **响应文本解码**（`NetResponse.text` / `decodeText`，实现在 `lib/core/encoding/`）：按显式 `charset` → BOM →
  `Content-Type` 的 charset → HTML `<meta>` / XML 声明（只看响应体前 4 KB）→ utf-8 识别编码，规则见 source-spec §5。
  声明式引擎、脚本 `tsumugi.http`（`text` / `json`）与小说阅读 / 导出（正文来自同一请求）都经此路径；
  `responseType: "bytes"` 与图片直接取原始字节，不受影响。不认识的 charset 跳过并记录调试日志（`tsumugi.network`）。
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

#### 设备与模拟器上的集成测试

`integration_test/` 在真实平台上运行完整应用或原生部分，**移动端以模拟器为先**，真机只留给视频播放与 release 实测：

| 文件 | 覆盖 | Windows | Android 模拟器（x86_64） | iOS 模拟器 | 真机 |
|---|---|---|---|---|---|
| `app_flow_test.dart` | 真实路由与引擎：加载 JS 脚本源 → 搜索 → 详情 → 漫画阅读器翻页（漫画页经源的图片客户端加载）；小说阅读器翻页模式翻到下一章；导出 TXT / EPUB | ✓ | ✓（本机 + CI） | CI | — |
| `script_stack_depth_test.dart` | QuickJS 原生库加载与栈上限；release 下测深度（文件头注释） | ✓ | ✓（本机 + CI） | CI | Android release 实测 |
| `video_playback_test.dart` | 真实 libmpv 经媒体代理播放（§6.4.2） | ✓ | ✗（见下） | — | Android |
| `download_offline_test.dart` | 下载漫画章节与带插图的小说章节 → mock 服务器断网 → 从书架「下载」标签离线阅读（§4.5） | ✓ | ✓（本机 + CI） | CI | — |
| `video_download_offline_test.dart` | 视频详情「下载」一集（AES-128 HLS + 字幕轨 + 外挂字幕）→ 断网 → 本地来源会话返回明文分片与字幕；Windows 上另在播放页离线播放并选字幕（§4.5.1） | ✓ | ✓（本机 + CI，不播放） | CI（不播放） | — |

- **mock 服务器**（`integration_test/test_mock.dart`）：桌面上在测试进程内启动；设备 / 模拟器读不到电脑上的 `test/fixtures/`，
  改为连接电脑上以 `--test-control` 启动的服务器（经 `/__test/*` 取测试数据、读请求记录、`/__test/offline` 模拟断网）。所有 HTTP 连接都经自定义连接接到它，
  虚构主机名照常可用，白名单仍按虚构主机名检查。
- **本机运行**：

  ```bash
  flutter test integration_test/app_flow_test.dart -d windows

  # Android 模拟器 / 真机（adb reverse 比局域网稳定）；iOS 模拟器与电脑共用网络，不需要 reverse
  dart run tool/mock_server/main.dart --port 8081 --test-control
  adb reverse tcp:8081 tcp:8081
  flutter test integration_test/app_flow_test.dart -d <设备> --dart-define=TSUMUGI_MOCK_SERVER=127.0.0.1:8081
  ```

  `flutter test -d <设备>` 只支持 debug；profile 用 `flutter drive --profile --driver=test_driver/integration_test.dart --target=...`。
- **导出**：系统保存界面（SAF / 文件 App）无法自动操作，测试把 `exportSaverProvider` 换成写入临时目录的实现，只校验生成的文件；
  真正的保存 / 分享界面仍需真机确认（#31）。
- **x86_64 模拟器**（2026-11 实测，Android 37 x86_64）：QuickJS 原生库与 libmpv 都能构建并加载。但 media_kit 检测到模拟器后强制软件渲染，
  libmpv 的视频输出无法创建 GLES 2 EGL 上下文（`Could not create EGL context for GLES 2.x`），**视频播放只能在真机上测**。
- **CI**（`.github/workflows/device-tests.yml`）：Android 模拟器（ubuntu runner + KVM，API 35 x86_64）与 iOS 模拟器（macos runner）
  各一个任务，运行上表标为 CI 的测试；mock 服务器由 `tool/ci/start_mock_server.sh` 在 runner 上启动。只在推送 main 与手动触发
  （`workflow_dispatch`）时运行，**不是必须通过的检查**，不拖慢 PR；失败时上传 mock 服务器日志。

已知限制：不支持 EUC-JP / ISO-2022-JP（缺 JIS X 0212 索引与有状态解码器，遇到时按 utf-8 解码并记录日志）；
请求方向仍只用 UTF-8 编码（模板 `{{keyword}}` 的 URL 编码、表单与请求体），只接受 GBK 编码参数的站点暂无法搜索。
Cookie Jar 在按源的 `SourceSession` 中，按源持久化在应用支持目录（§5.3「会话持久化」）。

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
- **暂时停用**（[#29](https://github.com/Shiroha23/Tsumugi/issues/29)）：被放弃的 worker 可能仍占着线程（见 §6.1），因此看门狗放弃 worker 后，
  该源在 `hangCooldown`（默认 2 min）内不新建 worker；被放弃、尚未退出的 worker 在一个源达到 `maxStuckWorkers`（2）个
  或全进程达到 `maxStuckWorkersGlobal`（4）个时也不再新建，直到其中有 worker 退出（经独立的 onExit 端口得知）。
  - 记录按 `hangKey`（脚本源为 `script:<sourceId>`，声明式 `js:` 为片段模块源码）保存在**进程级**的表里，不随实例释放清零；
    首次加载与重建都检查，所以加载阶段卡住后反复新建实例（失败的创建不缓存）、换设置重建实例同样受限。
  - 停用期间 `ScriptSource` / 声明式源的调用以 `SourceSuspendedException`（`SourceException` 的子类，`E_LIMIT`）立即失败：
    本源原因显示「某源暂时不可用」并建议禁用或删除；全进程原因（可能来自其他源）显示「暂时无法启动脚本源」，不归咎于本源。
    后者意味着多个卡死的源可以暂时阻止其他脚本源**新建** worker（已在运行的 worker 不受影响），这是为限制线程占用做的取舍。
  - 条件解除后下一次调用自动重建；重建时重新加载超限 / 再次卡住不会作废实例，冷却后可再试。
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
5. **视频播放器的许可证、平台可用性与请求边界** —— M4 已验证，结论见 §6.4。

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
  交互式宿主调用（`ui.openWebView`）进行中时暂停，改按 `interactiveTime` 计时（§5.3）。
- **内存 / 栈**：`JSRuntimeConfig.memoryLimit` / `maxStackSize`，超限 → `E_LIMIT`。
- 已知限制：**递归深度偏低**（2026-11 release 实测，`integration_test/script_stack_depth_test.dart`）：默认 512 KB 栈上限下
  简单递归在 Windows 约 107 层、Android 约 487 层（Windows 的 QuickJS 原生库每层栈帧明显更大），已写入 source-spec §4.4。
  栈上限必须小于执行线程的栈，而脚本所在的 Dart isolate 线程栈大小不可配置，因此不能直接调大；
  改到栈更大的专用线程上执行需要宿主同步回调跨线程，当前 Dart FFI 不支持，暂不实施（[#41](https://github.com/Shiroha23/Tsumugi/issues/41)）。
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
  因此 `pubspec.yaml` 把 qjs 固定为 `0.2.3`，升级时须复查结构布局；`test/core/engine/script/native_stack_test.dart`
  经同一指针调用 `JS_SetMaxStackSize`，确认栈上限真的作用于 JS 递归，布局失效时会失败
  （线程迁移导致的误报本身无法在测试中稳定复现）。
  不向上游提需求，等待上游自行公开该 API 后删除此文件（[#28](https://github.com/Shiroha23/Tsumugi/issues/28)）。
- **worker 无法被强制终止**：不能用 `Isolate.kill(priority: immediate)`——worker 往往正处于 QuickJS → Dart 的
  FFI 回调中，在那里被强制终止会让整个进程崩溃（已实测）。因此看门狗只做 `kill(beforeNextEvent)`：worker 回到事件循环时退出，
  一直卡住的 worker 只能放弃（占用一个线程直到进程退出）。
- **部分原生内建函数不检查中断**：QuickJS-ng 某些内建函数（如 `Array.prototype.flat` 作用于
  `length` 极大的类数组对象）在 C 循环中不检查中断，CPU / 总时长限制对其无效，可能长时间无法返回
  （未实测，依据引擎源码判断）。放进 worker isolate 也不够：isolate 卡在原生代码中时 Dart 无法终止它。
  根治需要给引擎打补丁（在这些循环中加入中断检查）或把脚本放进可被强制结束的独立进程；
  在此之前，恶意源最坏能卡死其所在的 worker（[#29](https://github.com/Shiroha23/Tsumugi/issues/29)）。
  缓解：看门狗放弃卡死的 worker 后该源暂时停用，并按源、按进程限制被放弃 worker 的数量（§5.5），恶意源不能借此反复占用线程；
  其他源的数据隔离不受影响，但全进程上限触发时它们暂时不能新建 worker。
  验证页打开期间看门狗按交互等待的上限计时，这种卡死要到验证页关闭或该上限到期后才会被发现。
- 同一运行时上的调用**串行执行**（宿主 Promise 需要归属到具体调用）。如需单源并发，可按调用开多个运行时。
- HTML 句柄的 DOM 不在 JS 堆内，只能靠句柄数与解析文本量的上限间接约束（source-spec §4.2.1）。
- 源脚本**不支持顶层 await**（模块同步求值）；已写入 source-spec §4.1。
- 移动端：Android 已在真机上手动验证（2026-11，漫画 / 小说 / 脚本源 / WebView）；iOS 仍只验证到能编译（[#31](https://github.com/Shiroha23/Tsumugi/issues/31)）；
  移动端自动化集成测试尚未建立（[#32](https://github.com/Shiroha23/Tsumugi/issues/32)）。
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

### 6.3 文本编码选型结论（#22，2026-11）

**自实现 [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/) 的解码器（纯 Dart），不引入编码库。**
浏览器按这份标准解码网页，与之一致就能得到和浏览器相同的结果（如 `gb2312` / `gbk` 标签按 GB18030 解码、
`latin1` / `ascii` 按 windows-1252、Big5 即 Big5-HKSCS）。

| 方案 | 覆盖 | 许可证 | 结论 |
|---|---|---|---|
| **自实现 + WHATWG 索引** ✅ | GB18030（含四字节区间）、Big5、Shift_JIS、EUC-KR、UTF-16、全部单字节编码 | 索引数据：WHATWG 标准中并入源码的部分按 BSD-3 授权（与 GPL-3.0 兼容） | 选用 |
| [`enough_convert`](https://pub.dev/packages/enough_convert) | GBK、Big5、单字节；无 Shift_JIS / EUC-KR，无 GB18030 四字节 | MPL-2.0 | 覆盖不足；非法字节默认抛异常 |
| [`charset`](https://pub.dev/packages/charset) | GBK、Shift_JIS、EUC-KR、单字节；无 Big5 | BSD-3 | 覆盖不足，最后发版 2023 |
| 平台 API（ICU / iconv） | 全 | — | 三平台不一致，需原生桥接 |

- `lib/core/encoding/whatwg_indexes.dart` 由 `tool/encoding/gen_whatwg_indexes.dart` 从 WHATWG 索引文件生成
  （文件头记录各索引的 Identifier）；多字节索引按「码点差值 → zigzag varint → zlib（`archive` 包）→ base64」
  压缩，源码约 130 KB，首次用到某个编码时解压（几毫秒）。
- 解码算法逐条照搬标准（含错误时「把 ASCII 字节放回输入流」等细节），非法字节输出 U+FFFD，从不抛异常。
- 与 Python `gb18030` / `big5hkscs` / `cp932` / `cp949` 编解码器对全部可编码字符做过交叉比对，
  差异只在标准有意不同之处（GB18030-2022 的 PUA 调整、cp932 / HKSCS 的单向兼容映射）。
- 只实现解码；请求方向（编码 GBK 表单 / 查询参数）为后续工作。
- 测试：`test/core/encoding/`、`test/core/network/net_response_test.dart`，以及 mock 服务器的 GBK / Big5 虚构页面
  （`test/fixtures/mock_site/encoding/`）。

### 6.4 视频播放选型结论（M4，2026-11）

**结论：采用 [`media_kit`](https://pub.dev/packages/media_kit) 1.2.6（libmpv），三平台只引入视频所需的
`media_kit_libs_{windows,android,ios}_video`；播放器的所有网络请求经本地媒体代理走该源的 `SourceHttpClient`。**
四个关键问题（许可证、平台、请求边界、体积）都有可行答案，没有走不通的项；遗留风险与后续工作见 §6.4.6。

#### 6.4.1 许可证

media_kit 的 Dart / 插件代码都是 MIT；许可证问题在它下载的**预编译 libmpv / FFmpeg**。逐个平台核对了插件实际固定的
下载地址与构建配置：

| 平台 | 插件固定的二进制 | mpv | FFmpeg | nonfree | 依据 |
|---|---|---|---|---|---|
| Windows | `media-kit/libmpv-win32-video-build` 发布 `2023-09-24` 的 `mpv-dev-x86_64-20230924-git-652a1dd.7z`（MD5 写死在插件 CMake 中） | `-Dgpl=false`（LGPL-2.1+） | `--disable-gpl --disable-nonfree --enable-version3` → **LGPL-3.0+** | 无 | **二进制实测**：`libmpv-2.dll` 内嵌的配置串，以及 `libavcodec license: LGPL version 3 or later`（libavformat / avutil / avfilter / swscale / swresample 相同） |
| Android | `media-kit/libmpv-android-video-build` `v1.1.7` 的 `default-<abi>.jar`（MD5 写死在插件 build.gradle） | `-Dgpl=false` | `default` 构建脚本：`--disable-gpl --disable-nonfree --enable-version3` → **LGPL-3.0+** | 无 | **二进制实测**：APK 中 `libmpv.so`（静态包含 FFmpeg）的配置串与 `LGPL version 3 or later`；构建脚本 `buildscripts/flavors/default.sh`、`scripts/mpv.sh` 一致 |
| iOS | `media-kit/libmpv-darwin-build` `v0.6.0` 的 `ios-universal-video-default`（sha256 写死在插件 Makefile） | `0.36.0`，`-Dgpl=false` | `6.0`，`default` flavor：无 `--enable-gpl` / `--enable-nonfree`，有 `--enable-version3` → **LGPL-3.0+** | 无 | **二进制实测**（M4-B，2026-11）：下载插件固定的压缩包（sha256 一致），`Avcodec.framework` 内嵌 `FFmpeg version 6.0` 与 `LGPL version 3 or later`，`Mpv.framework` 内嵌 `mpv 0.36.0` 与 `-Dgpl=false`；`v0.6.0` 标签处的 `scripts/ffmpeg/meson.build`、`downloads.lock` 一致 |

三个平台带 GPL 的版本（`encoders-gpl` / `encodersgpl`，含 x264）都**没有**被插件使用。**libplacebo 三个平台都没有启用**
（Windows / Android 的 mpv 配置为 `-Dlibplacebo=disabled`，iOS 的依赖锁文件中没有它）。

**逐项核对（M4-B，2026-11）**：从插件固定的二进制与构建仓库的确切标签核对每个随包组件的版本、许可证与源码地址，
结果在仓库根目录的 `THIRD_PARTY_NOTICES.md`（逐平台的表），源码下载清单在 `tool/release/native_sources.tsv`（带 sha256）。
要点：

- **Android / iOS**：构建仓库按标签固定了每个依赖的版本（`buildscripts/include/depinfo.sh` / `downloads.lock`），
  二进制中的版本串与之一致（如 Android FriBidi 1.0.12、dav1d 1.2.0、FFmpeg n6.0；iOS libpng 1.6.40 由 FreeType 的 meson
  回退子项目引入，不在锁文件里）。对应源码可以确切取得。
- **Windows**：构建脚本（shinchiro/mpv-winbuild-cmake 的分支）对多数依赖不固定版本，构建时取各自 git 的最新提交。
  确切的只有 mpv `652a1dd`、FFmpeg `n6.0`，以及二进制版本串给出的 FriBidi 1.0.13、libsoxr 0.1.3 等；
  **其余依赖（libass、HarfBuzz、FreeType、Mbed TLS、libxml2、uchardet、libjxl、libvpl、libwebp、zimg、shaderc、SPIRV-Cross、
  lcms2、libarchive、mujs 等）的确切提交没有记录**。更麻烦的是，发布 `2023-09-24` 时 media-kit 的定制脚本
  （只保留视频所需解码器等）**不在构建仓库的 git 历史中**：标签所在的 `version` 分支只有一个版本号文件，`master` 上的定制提交是
  2024-02 才提交的（FFmpeg 已换成别的提交）。现存最准确的记录是二进制内嵌的 mpv / FFmpeg 配置串，已提取到
  `tool/release/windows_libmpv_build_config.txt`。因此 **Windows 无法提供与二进制逐字节对应的全部源码**，只能尽力而为
  （见下文第 2 点），根本解决要靠自建 libmpv（§6.4.6 后续 2）。
- **ANGLE**（Windows，来自 `alexmercerind/flutter-windows-ANGLE-OpenGL-ES` `v1.0.1` 的自编译包）：`libEGL` / `libGLESv2` 的版本资源为
  `2.1.18844 git hash: 2693b03eba82`（google/angle `2693b03eba82a424a19febaacaab4115a45b7682`，2022-07）；SwiftShader 5.0.0 与
  Vulkan Loader 是 ANGLE 在该提交的第三方依赖；`zlib.dll` 为 zlib 1.2.12。
- **`d3dcompiler_47.dll`**（微软可再分发组件，非开源）：**不再随包分发**（`windows/CMakeLists.txt` 从插件的打包列表中排除），
  ANGLE 改用 Windows 10 起系统自带的同名 DLL。
- **`WebView2Loader.dll`**（Windows，`flutter_inappwebview_windows` 经 NuGet 取得的 Microsoft.Web.WebView2 SDK，M3 起随包）：
  微软的闭源二进制，SDK 许可证为 BSD-3 风格的宽松条款，允许再分发；没有源码。**保持以动态库随包**（已决定，2026-11）：
  改为静态链接 `WebView2LoaderStatic.lib` 同样把闭源代码放进程序，并不更合规。在「关于」页与 `THIRD_PARTY_NOTICES.md` 中注明是
  微软闭源组件、按其条款再分发。
- 应用自身的原生库：QuickJS-ng 0.17.0（MIT，经 `qjs` 0.2.3 从源码构建）、SQLite（公有领域，`sqlite3` 包）。

新增的传递依赖 `wakelock_plus`、`package_info_plus`、`http`（BSD-3）与 `image`、`synchronized`、`safe_local_storage`、
`uri_parser`、`universal_platform`（MIT）都是宽松许可证。

**与 GPL-3.0 兼容**：LGPL-2.1+ / LGPL-3.0+ 的库可以并入 GPL-3.0 作品（LGPL-2.1 §3 允许改用 GPL；LGPL-3.0 即 GPL-3.0 加附加许可），
Apache-2.0 与 GPL-3.0 兼容。**再分发（CI 产物、Release）需要满足**：

1. 随安装包附带 GPL-3.0、LGPL-2.1 / LGPL-3.0 全文与各第三方组件的版权声明。**落实**：应用内「设置 → 关于」页显示版本、
   GPL-3.0 声明与源码仓库地址，「第三方许可证」用 Flutter 的 `showLicensePage`——Dart 包与 Flutter 引擎的许可证由 Flutter
   自动收集，原生组件的许可证全文放在 `assets/licenses/`，启动时经 `LicenseRegistry.addLicense` 注册
   （`lib/features/settings/about/native_licenses.dart`）。仓库根目录的 `THIRD_PARTY_NOTICES.md` 列出原生组件、版本、许可证与源码地址。
2. 提供**对应源码**：本项目源码 + 所用 libmpv / FFmpeg 及其依赖的源码与构建脚本，写明确切版本。上游链接不一定长期可用
   （Windows 构建仓库已归档），**每次发布时把这些源码包一并上传到本项目的 Release**（GPL-3.0 §6）。**落实**：
   `.github/workflows/release.yml`（推送 `v*` 标签时触发；`workflow_dispatch` 为 dry-run，只上传为构建产物）构建三平台安装包，
   并用 `tool/release/fetch_native_sources.sh` 按 `tool/release/native_sources.tsv` 下载各组件源码与构建脚本、校验 sha256、
   打成 `tsumugi-<版本>-native-sources.tar`（约 120 MB，其中两个版本的 HarfBuzz 源码各约 35 MB），与安装包上传到同一个 Release。
   清单收录：Android / iOS 构建仓库在确切提交处的存档、三平台的 mpv / FFmpeg、Android / iOS 锁定的全部依赖、Windows 能确定版本的
   LGPL 组件，以及从 Windows 二进制提取的构建配置。**已决定（2026-11）**：
   - Windows 构建仓库没有许可证文件（即保留所有权利），**不收其存档**，只在 `SOURCES_README.md` / `THIRD_PARTY_NOTICES.md` 中给出上游
     归档仓库与确切提交（构建时的 `master` `f5a6f87`、归档时的 `master` `35a3be3`）；
   - Windows libmpv 的对应源码**只能尽力提供**（缺多数依赖的确切提交与当时的定制脚本，原因见上文），接受此状态，直到自建 libmpv
     （§6.4.6 后续 2）落地后提供完整的对应源码与构建脚本；
   - Windows 版本未知的宽松许可证依赖与 ANGLE（源码体积达 GB 级）只在 `THIRD_PARTY_NOTICES.md` 中给出上游地址。
3. LGPL 要求用户能替换库：Windows / Android 为动态库，天然满足；iOS 的 xcframework 内是动态 framework（Mach-O `MH_DYLIB`，
   M4-B 实测；此前误记为静态库），同样可以替换。此外整个应用以 GPL-3.0 提供完整源码与构建方式，用户也可以重新构建。

备选对比（2026-11 调研 pub.dev / GitHub）：

| 方案 | Win / Android / iOS | HLS | 请求头 | 许可证 | 结论 |
|---|---|---|---|---|---|
| **media_kit**（libmpv）✅ | ✓ / ✓ / ✓ | ✓（AES-128 由本项目的代理解密） | 全局 `http-header-fields`；本项目改用代理 | MIT + LGPL 预编译库 | 选用；Windows 预编译库停在 2023-09，见 §6.4.6 |
| [`fvp`](https://pub.dev/packages/fvp)（libmdk） | ✓ / ✓ / ✓ | 未声明 | 未声明 | 插件 BSD-3；**libmdk 闭源**，按 README 的 key 授权（“Free for Flutter users”） | 闭源原生库无法提供 GPL 要求的对应源码，**不兼容**，排除 |
| [`video_player`](https://pub.dev/packages/video_player)（ExoPlayer / AVPlayer） | ✗ / ✓ / ✓ | 平台播放器支持 | `httpHeaders`（各平台对分片请求的支持不一） | BSD-3（ExoPlayer Apache-2.0） | 无 Windows 实现 |
| `video_player` + [`video_player_win`](https://pub.dev/packages/video_player_win)（Media Foundation） | ✓ / ✓ / ✓ | **Windows 不支持 HLS** | 未声明 | BSD-3 | Windows 无 HLS，排除 |

#### 6.4.2 平台可用性

- **Windows**：已实际播放（`integration_test/video_playback_test.dart`，`flutter test integration_test/video_playback_test.dart -d windows`）：
  真实 libmpv 经代理播放 MP4 与 AES-128 加密（由代理解密）、需要 Referer 与 Cookie 的 HLS，覆盖播放、暂停、跳转、2 倍速与播放完成，
  画面 320×180、时长 6 s，并断言上游的每个请求都来自源客户端（虚构主机名、源的 UA，没有 libmpv 自己的 UA）。
  日志中的 `Failed to create EGL surface`（dxva2-egl 硬解互操作失败后回落）与 `Failed to create file cache` 不影响播放。
  完整界面（搜索 → 详情 → 播放页）的手动步骤见 PR 描述。
- **Android**：本机与 CI 都能构建 release APK。**真机自动化测试**（M4 字幕 PR 起）：`integration_test/video_playback_test.dart`
  可在设备上以 profile 模式运行——设备读不到电脑上的 `test/fixtures/`，先在电脑上
  `dart run tool/mock_server/main.dart --host 0.0.0.0 --port 8081 --test-control`，再
  `flutter drive --profile --driver=test_driver/integration_test.dart --target=integration_test/video_playback_test.dart -d <设备> --dart-define=TSUMUGI_MOCK_SERVER=<电脑局域网 IP>:8081`。
  测试中的 HTTP 连接都经自定义连接接到该服务器（虚构主机名照常可用），请求记录经 `/__test/*` 控制接口读取（`integration_test/test_mock.dart`）；
  `flutter test -d <设备>` 只支持 debug 模式。2026-11 在 Android 16 真机上全部通过（播放器 + 代理 9 项、播放页 2 项，含字幕）。
  只剩手机上的“USB 安装”确认需要人工点击。
- **Android 真机发现**（Android 16，HLS 测试素材；MP4 与单个 MPEG-TS 文件正常）：HLS 常常一开始就跳到结尾（首个进度 6.037 s → 播放完成，
  界面停在黑屏）。软解（`--dart-define=TSUMUGI_HWDEC=no`）同样出现，两个平台的 FFmpeg 都是 n6.0（Lavf 60.3.100），故与解码器、
  时间戳和 FFmpeg 版本无关。差别在 media_kit 的 Android 视频输出：拿到视频参数后才创建 Surface，随后重新初始化输出并 seek 到“当前位置”；
  这次 seek 落在 HLS 解复用器初始化期间，常常直接到达结尾（FFmpeg 随后报 “m3u8 list sequence may have been wrapped”）。
  这次 seek 停在分片边界（2.05 / 4.09 s）或结尾，之后再 seek 到 0 也不生效；Windows 的视频输出没有这一步，同样的 seek 在 Windows 上正常。
  排查过程排除了：代理（所有请求正常）、解码器（`hwdec=no` 同样复现）、MPEG-TS 时间戳（单个 TS 文件正常）、FFmpeg 版本（两平台相同）。
  上游已有同类问题（[media-kit#1417](https://github.com/media-kit/media-kit/issues/1417)，由 [media-kit#1294](https://github.com/media-kit/media-kit/pull/1294) 引入）。
- **处理：暂停打开 → 等待视频输出 → 重新打开**（`openVideo`，`shared/video/player_options.dart`）：打开时视频输出未就绪的
  （Android 上每个播放页的第一次播放），先暂停打开，等它就绪（最多 5 s）并稍候 0.5 s，再**重新打开**同一地址（带起始位置）：
  Surface 尺寸不变，media_kit 不再更换输出、也不再 seek；代理缓存了解密后的分片，几乎不增加网络请求。
  同一播放页内换集 / 换清晰度时输出已就绪，直接打开；Windows 上输出总是就绪。加载遮罩保留到播放器真正从起始位置开始播放
  （收到新媒体的时长或一次缓冲之后，位置到达起始位置附近）才撤下，期间不显示控件。
  真机验证（2026-11，Android 16）：PR #38 时从头播放 HLS 10 次中 10 次从 00:00 开始；M4 播放页 PR 中续播、换清晰度、自动下一集见 PR 描述。
- **media_kit_video fork 不可行**（[#49](https://github.com/Shiroha23/Tsumugi/issues/49)，M4 播放页 PR 中实测后放弃）：曾在
  [`Shiroha23/media-kit`](https://github.com/Shiroha23/media-kit) 的 `tsumugi/android-wid-seek` 分支只改 Android 的 `widListener`
  （位置 ≤ 0 或已播完时不执行那次 seek，思路同上游已关闭的 [media-kit#1453](https://github.com/media-kit/media-kit/pull/1453)），
  并去掉重新打开。真机上新开页面从头播放 HLS 6 次中仍有 5 次一开始就在 2.11 s 或结尾——确认装的是打过补丁的版本后，
  跳位仍发生在 Surface 到达、视频输出从 `null` 换成 `gpu` 之时，与是否执行 media_kit 的那次 seek 无关（推测为 mpv 更换输出时自己的刷新定位）。
  只改 `widListener` 绕不开这一步，因此回到上面的重新打开方案，`pubspec.yaml` 仍用 pub.dev 的 `media_kit_video` 2.0.1，不使用 fork。
- 另关闭了在两个平台上都建不起来的 mpv 磁盘缓存（`cache-on-disk=no`，是否启用的结论见 §6.4.3「播放器缓存」）。
- **诊断开关**（`shared/video/player_options.dart`）：
  - `--dart-define=TSUMUGI_VIDEO_LOG=true`：在 release 构建中开启详细日志——代理的逐个请求（编号 / 文件名、Range、状态、字节数、耗时，不含令牌）、
    播放器状态变化与实际解码路径；debug 构建默认开启。不开启时只输出 libmpv 的警告 / 错误、代理的失败原因与每次播放一行的启动摘要。
  - `--dart-define=TSUMUGI_HWDEC=<mpv hwdec 取值>`（如 `no`、`mediacodec-copy`）：覆盖 media_kit 默认的硬解设置，用于比较解码路径。
  - mock 服务器第 5、6 集为诊断用的单个 MPEG-TS 文件（时间戳从 1.4 s / 0 开始）。
- **iOS**：CI 编译（`flutter build ios --release --no-codesign`）；未在真机上运行（同 [#31](https://github.com/Shiroha23/Tsumugi/issues/31)）。

#### 6.4.3 请求头、Cookie 与主机白名单：本地媒体代理

播放器自带的网络栈（FFmpeg）只能设置一组全局 headers，Cookie 是静态的（不随 `Set-Cookie` 更新、不分主机），也无法限制访问哪些主机。
因此**不让播放器直接访问上游**，而是在应用内起一个只监听 `127.0.0.1` 的代理（`core/network/media/media_proxy.dart`）：

```
media_kit (libmpv / FFmpeg) ── http://127.0.0.1:<port>/<token>/<编号>/<文件名> ──▶ MediaProxy
                                                                   │ 会话：编号 → 上游地址（只登记见过的地址）
                                                                   ▼
                        SourceHttpClient.openStream（该源的白名单 / 每跳重定向检查 / Cookie Jar /
                                                     默认 headers / 会话 UA / StreamRef.headers / 限速）
```

**边界**：播放器能拿到的只有代理地址；代理只会替它请求“根地址或代理改写过的播放列表中出现的地址”，而且只把三类内容交给播放器——
改写过的 HLS 播放列表、文件头可识别的媒体容器、字幕播放列表中的 WebVTT。其他任何内容（包括播放器可能当成播放列表去跟随的格式）都不放行。

- **会话**：每次播放一个会话，令牌为 192 位随机数。会话内的地址按（地址, 用途, 解密参数）去重编号，播放器无法让代理请求任意地址。
  关闭会话后请求一律 404，进行中的上游请求被取消。
- **HLS 改写**（`hls_playlist.dart`）：只保留 RFC 8216 中播放器需要、且地址只出现在 `URI` 属性或下一行的标签
  （`EXT-X-DATERANGE`、`EXT-X-SESSION-DATA`、`EXT-X-CONTENT-STEERING`、`EXT-X-DEFINE`、`EXT-X-SKIP`、非标准标签与普通注释整行删除——
  它们可能用任意属性名携带地址，如插播广告的 `X-ASSET-LIST`）。每个 URI 行与 `URI="…"` 属性都基于播放列表的**最终地址（重定向之后）**
  解析后换成代理地址；非 http(s) 地址（`skd://`、`file:` 等）得到总是 403 的代理地址。
- **AES-128 由代理解密**：`EXT-X-KEY:METHOD=AES-128` 不交给播放器；代理经源取得密钥（每个会话按地址缓存，失败不缓存）与整段密文，
  按 IV（标签给出的，或媒体序号）做 AES-128-CBC 解密后，再按下一条识别明文。明文按分片缓存最近 4 段（同一分片的重复 / 并发请求只取一次上游），
  播放器的 `Range` 按明文返回 206 / 416——FFmpeg 会在分片内续传或定位，总从开头返回整段会让它卡在分片边界（Android 真机上出现过）。这样加密分片也能做内容检查，播放器侧不需要 FFmpeg 的
  `crypto` 协议。`SAMPLE-AES` 等其他方式的密钥地址照常改写，由播放器经代理取得（尚未用测试素材验证）。
- **内容识别**（`media_signature.dart`）：分片与根地址的响应必须以已知容器的文件头开头（MPEG-TS、ISO-BMFF / fMP4、Matroska / WebM、
  FLV、Ogg、ID3 / ADTS / MPEG 音频、AC-3、FLAC、AVI / WAV），开头一段中要有控制字节，且不能以 UTF-16 / UTF-32 字节序标记开头；
  字幕播放列表中的分片必须以 `WEBVTT` 开头。识别不了的一律 415——HLS 以外的 m3u / pls / DASH MPD / ffconcat / EDL、HTML 错误页、
  任何编码的文本都在此列。子播放列表必须以 `#EXTM3U` 开头，否则 502。从中间开始的区间请求先单独取资源开头 1 KB 识别（每个地址一次）。
- **类型与文件名由代理决定**：媒体一律 `application/octet-stream`、字幕 `text/vtt`、播放列表 `application/vnd.apple.mpegurl`，
  不透传上游的类型。代理地址中的文件名不参与查找（只按令牌与编号），只给播放器看；扩展名都是媒体或 HLS 的扩展名，
  播放器不会按扩展名把内容当成其他播放列表格式：
  - 子播放列表 `index.m3u8`，密钥 `key.bin`，字幕分片 `sub.vtt`。
  - **HLS 分片按内容命名**（同一个子播放列表中的分片、初始化分片与部分分片用同一个扩展名）：改写子播放列表时分片还没取，
    代理先探测 **FFmpeg 起播时用来探测格式的那个媒体地址**——有 `EXT-X-MAP` 时为初始化分片；否则点播为第一个分片，直播（没有
    `EXT-X-ENDLIST`）为倒数第 3 个分片（`live_start_index` 默认 -3，n8.0.1 `select_cur_seq_no`）；部分分片不算，只有部分分片时不探测。
    该地址以字节区间引用资源（`EXT-X-BYTERANGE`、`EXT-X-MAP` 的 `BYTERANGE`）时从区间起点读、不超过区间长度（上游必须按区间返回，否则探测失败）。
    探测只用区间请求取开头 1 KB；AES-128 加密的取密钥后只解密开头几块（CBC 可按块解密，不需要整段，不进明文缓存）；以 ID3 标签开头、
    其后的帧头超出 1 KB 时补读到帧头（上限 64 KB）。按识别出的容器决定扩展名：MPEG-TS → `ts`，ISO-BMFF / fMP4 → `mp4`，
    ADTS（含 ID3 前缀的打包音频）→ `aac`，MPEG 音频 → `mp3`，AC-3 → `ac3`，E-AC-3 → `eac3`，Matroska / WebM → `mkv`，Ogg → `ogg`，
    FLAC → `flac`，AVI → `avi`，WAV → `wav`，FLV → `flv`。识别成功后记在该播放列表上，刷新不再探测；失败（上游错误、超时、内容无法识别）
    时用 `ts`，每个播放列表最多探测 2 次（直播刷新时再试一次），之后固定为 `ts`；分片本身照常按上一条检查。探测走 `media` 通道，
    整个过程（含取密钥）受该播放列表请求的 `prepareTimeout` 与断开约束，超时即回落（取密钥若还有分片请求在等则继续，
    结果照常缓存；没有其他等待者时随之取消）。
    多码率时每个子播放列表多一次 1 KB 的请求。
  - 根地址仍按上游扩展名取常见媒体扩展名（`media.mp4` 等，`.m3u8` / `.m3u` 为 `index.m3u8`，其余 `media.bin`）：根地址不经 HLS 的
    分片检查，FFmpeg 按内容识别。
  - **为什么按内容**：FFmpeg 7.1.1 起 HLS 解复用器默认 `extension_picky=1`（`libavformat/hls.c` 的 `test_segment()`，按 n6.0 / n7.1.1 /
    n8.0.1 的源码核对）。每个分片地址（播放列表中的地址，不看重定向后的；`EXT-X-MAP` 初始化分片不检查）的扩展名必须在允许列表中：
    n7.1.1 用 `allowed_extensions`（`3gp,aac,avi,ac3,eac3,flac,mkv,m3u8,m4a,m4s,m4v,mpg,mov,mp2,mp3,mp4,mpeg,mpegts,ogg,ogv,oga,ts,vob,wav`，
    **没有 `vtt`**），n8.0 起改用 `allowed_segment_extensions`（再加 `vtt,webvtt,cmfv,cmfa,ec3,fmp4,html`）。检查时机：首次解析播放列表时
    只查允许列表（任何一个不通过，整份列表解析失败）；探测起播分片之后，按探测出的格式检查**全部**分片；刷新时按已确定的格式检查新分片。
    与格式的对应：mpegts 接受 `ts,m2t,m2ts,mts,mpg,m4s,mpeg,mpegts`（n8.0.1 另有 `html`）；mov/mp4 接受自身扩展名（含 `mp4`）及 TS 系扩展名
    （n8.0.1 另有 `cmfv,cmfa`）；aac 在 n7.1.1 只接受 `aac`，n8.0 起也接受 TS 系；mp3 为 `mp2,mp3,m2a,mpa`；eac3 为 `eac3,ec3`；
    matroska 为 `mkv,…,webm`；webvtt 在 n8.0 起为 `vtt,webvtt`。因此同一列表内用同一个扩展名。`flv` 不在允许列表中，`wav` 解复用器没有
    扩展名（n7.1.1 / n8.0.1 `wavdec.c`），这两种分片在新版上无论叫什么都会被拒（HLS 中本不常见）。n7.1.1 的允许列表没有 `vtt`，
    HLS 字幕分片在 7.1.x 上会被拒（与本项目的命名无关，升级时应直接用 8.0+）。FFmpeg 6.0 只对 `file` 协议检查扩展名（n6.0 `hls.c`
    中没有 `test_segment()`），按内容命名对它没有影响（探测时扩展名只是加分项，与内容一致）。
- **Range / HEAD**：媒体的 `Range` 原样转发（根地址的 `bytes=0-` 不转发，以便识别是否为播放列表；播放列表、密钥、加密分片不转发给上游）。
  HEAD 按 GET 取上游后只返回代理自己的响应头（播放列表为改写后的长度）。加密分片的 `Range` 由代理按明文处理（见上）。上游请求固定 `Accept-Encoding: identity`（`StreamRef.headers`
  不能覆盖）；上游仍压缩时只接受整段的 gzip（由 dart:io 解压，不带长度），其他编码 502。只透传 `Content-Length` / `Content-Range` /
  `Accept-Ranges`；`Set-Cookie` 已进 Jar，不透传；播放器自己的请求头（UA 等）一律不转发。
- **错误**：白名单外（含重定向到白名单外）→ 403；`E_CHALLENGE` → 403；超时 → 504；其他网络错误 → 502；上游 4xx / 5xx 原样返回。
  网络层错误记在 `MediaProxySession.lastFailure`，播放页在播放器报错时据此显示 `SourceErrorView`（人机验证 / 登录时提供「打开验证页」，
  完成后重新加载）。
- **取消与资源**：播放器任何时候断开都立即取消该请求的上游（包括限速排队、等响应头、识别格式期间）。dart:io 的 `HttpServer` 处理请求时
  暂停读取该连接，写入之前察觉不到断开（`HttpResponse.done` 不完成），因此代理经 `HttpServer.listenOn` 接上 `WatchedServerSocket`：
  每个连接都由它一直读取（数据仍按 dart:io 的节奏交付；已读取未交付的数据超过 64 KB 时暂停底层读取，形成 TCP 背压，此时暂时
  察觉不到断开），读到 EOF 或出错即通知该连接上正在处理的请求（按对方地址与端口对应）。对方半关闭（只关写方向）也视为断开：
  一般 HTTP 客户端发完请求后不会这样做，若有客户端这样做，它的请求会被取消。
  加密分片的明文与密钥由多个请求共用一次取数：每个等待的请求断开时只是不再等待，所有等待者都离开时取数本身被取消（未结束的
  被取消的取数不再复用，之后的请求重新取）。另有“开始发送响应体之前”的总时限
  `prepareTimeout`（默认 60 s，取响应头、识别、读完播放列表 / 密钥 / 加密分片），超时取消上游，用于上游迟迟不响应的情形；
  **等待限速令牌的时间不计入**（`openStream` 的 `onRateLimitWait` 在排队期间暂停计时，`PausableDeadline`），拿到令牌后才继续计时；
  共用的取数（明文、密钥）排队时，等它的请求的时限也一并暂停，取数实际进行的时间照常计入。
  上游连接：取消订阅响应体、`cancel()`、`NetCancellation` 与 `client.close()` 都会关闭上游 TCP 连接（dio 中止请求时 dart:io 销毁连接，
  有测试从上游 socket 一侧确认）。注意测试上游若用 dart:io 的 `HttpResponse` 写，连接被对方关闭后写入仍“成功”、`done` 也不报错，
  看不出连接已关闭，要接管 socket 判断。播放列表限 4 MB、密钥限
  4 KB（必须为 16 字节）、加密分片限 64 MB（整段在内存中解密），每个会话最多登记 20000 个地址。
- **`openStream`**：`SourceHttpClient` 新增的流式 GET / HEAD。白名单、重定向、Cookie、headers、限速、重试（只在拿到响应头之前）与挑战检测
  都与 `request` 一致，但不受 20 MB 上限；挑战检测只读开头 `scanBytes`（64 KB），之后与剩余部分拼接返回。超时限制等待响应头的时间与
  读取响应体时相邻两块数据的间隔；调用方取消订阅或 `cancel()` 时中止请求、释放连接。
- **限速**：每次播放的客户端用该源的 `SourceSession`，与源实例、图片加载共用令牌桶（§5.4）。代理按地址用途选通道：
  播放列表、根地址从开头开始的请求（每次都重新识别，可能是播放列表）与确认之前识别用的 1 KB 探测走 `source`，计入清单 `rateLimit`；
  分片（含字幕分片、加密分片的密文）、密钥（轮换密钥时每个分片一个，数量同样不由源作者的 `rateLimit` 估计）与已确认是媒体的根地址
  不从开头开始的请求（MP4 跳转时的区间请求）走 `media`，计入本源固定的媒体配额（突发 10、每秒 10）。
  **评估**：分片数由片长决定（2 s 分片 1 倍速约 0.5 个/s，跳转、多路音视频时短时突发几个），源作者无法据此设置 `rateLimit`；
  若计入 `rateLimit`，`1 / 3 s` 这样的源会每个分片排队数秒，播放必然卡顿，而分片多在 CDN 上，按站点礼貌限速的本意也不针对它们。
  另外两种方案：分片完全不限（异常播放列表——极短分片、大量地址——能让客户端无节制地请求）、清单新增可配置的媒体限速字段
  （改源格式，源作者同样不知道该填多少）。因此采用固定的媒体配额：正常播放远达不到，又给出硬上限。
  直播播放列表按目标时长刷新，计入 `rateLimit`；`rateLimit` 小于刷新频率的源上直播会落后，需由源作者调大。
  `prepareTimeout` 不含限速排队时间（见「取消与资源」），`rateLimit` 极小时打开播放只是变慢，不会因排队而 504；排队期间播放器放弃
  （断开）时请求立即取消，不消耗令牌。播放器自己的网络超时仍可能先到，届时它断开（请求随即取消）并自行重试。
- **播放器缓存**（结论：**不启用 mpv 磁盘缓存**，`cache-on-disk=no`）：media_kit 默认 `cache-on-disk=yes` 但不设 `cache-dir`，
  所以两个平台都报 “Failed to create file cache” 并回落到内存。当前为内存缓存：向前 / 向后各 32 MB（media_kit `bufferSize` 默认，
  `demuxer-max-bytes` / `demuxer-max-back-bytes`）。不启用磁盘缓存的理由：
  1. mpv 的磁盘缓存只是同一个解复用缓存的后备存储，**容量仍由上述两项决定**，不跨播放保留，重播不省流量；
     想要更大的回看范围，调大 `bufferSize` 即可，不必落盘。
  2. 落盘的是解密后的第三方内容明文；mpv 默认“创建后立即删除”（`cache-unlink-files=immediate`），但 Windows 上打开中的文件
     通常无法删除（未验证 mpv 在 Windows 上如何处理），崩溃 / 强杀后的残留需要另做启动清理。
  3. 代理已缓存解密后的最近 4 个分片与密钥，HLS 回看超出内存缓存时重新经代理取（受媒体配额约束）即可。

  需要重新考虑的情况：移动端内存吃紧需要降低 `bufferSize`、但又要保留回看时，再启用——目录为
  `getApplicationCacheDirectory()/mpv_cache/`（三平台均为应用私有缓存目录），上限由 `demuxer-max-bytes` / `demuxer-max-back-bytes` 决定，
  每次关闭播放器与应用启动时删除该目录。
- **播放器侧的深度防御**（`shared/video/player_options.dart`）：FFmpeg `protocol_whitelist` 只有 `http,tcp`；关闭 `ytdl` 与外挂字幕 / 音轨 /
  封面的自动加载。`content.subtitles` 的外挂字幕**不经代理、不交给播放器**（不用 `sub-add`），由 Dart 侧取回并显示（§6.4.7）。`access-references=no` 不可用——media_kit 打开媒体时自己写临时播放列表再 `loadlist`，该选项会让它失败（实测）。

限制：

- **DASH 暂不支持**（MPD 中 `BaseURL` / `SegmentTemplate` 等地址需要另外改写）：播放页跳过 `type: dash` 的流，代理拒绝 MPD。
- AES-128 与 `EXT-X-BYTERANGE` 同时使用、加密的低延迟部分分片（`EXT-X-PART`）暂不支持（对应地址总是 403）。
- 伪装成图片等其他格式的分片（文件头不是媒体容器）会被拒绝。
- 新版 FFmpeg（7.1.1+）的 HLS 分片扩展名检查：代理按每个子播放列表中 FFmpeg 起播时探测的那个媒体地址的内容命名（见上）。
  同一列表中容器不一致的分片（例如 `EXT-X-DISCONTINUITY` 前后换了容器）、探测失败而实际不是 TS / fMP4 的列表、FLV / WAV 分片，
  在新版上仍会被拒（FFmpeg 本身也按起播分片的格式检查整个列表）；7.1.x 上 HLS 字幕分片会被拒（允许列表没有 `vtt`）。
  当前三平台的 FFmpeg 为 6.0，不受影响。
- 代理只监听本机回环地址，其他本机程序没有令牌就无法使用。

#### 6.4.4 安装包体积

本机 release 构建（同一代码，加 / 不加视频依赖）：

| 产物 | 引入前 | 引入后 | 增量 |
|---|---|---|---|
| Windows `Release/` 目录 | 39.9 MB | 89.4 MB | +49.5 MB |
| Windows `Release/` 压缩（zip -9） | 16.5 MB | 36.8 MB | +20.3 MB |
| Android `app-arm64-v8a-release.apk` | 27.2 MB | 40.6 MB | +13.4 MB |
| Android `app-armeabi-v7a-release.apk` | 25.0 MB | 37.7 MB | +12.7 MB |
| Android `app-x86_64-release.apk` | 28.9 MB | 45.7 MB | +16.8 MB |
| Android 通用 APK（三个 ABI） | 78.5 MB | 121.3 MB | +42.7 MB |

（MB = 10⁶ 字节；Android 为 `flutter build apk --release [--split-per-abi]`。arm64 的增量主要是 `libmpv.so` 12.4 MB，含静态链接的 FFmpeg。）

Windows 增量的构成：`libmpv-2.dll` 29.8 MB；ANGLE / SwiftShader / Vulkan（`libGLESv2`、`libEGL`、`vk_swiftshader`、`vulkan-1`）
13.6 MB；`d3dcompiler_47.dll` 4.9 MB（M4-B 起不再打包，见 §6.4.1）；其余插件不到 0.5 MB。iOS 的对比见 PR 中 CI 产物的大小。

**只带视频所需组件**：只引入了三个目标平台的 `*_video` 包（不含 macOS / Linux 的库）。音频专用的 `*_audio` 包更小但不能播放视频；
M5 音乐复用同一 libmpv，不再增加体积。预编译库内部的组件无法按需裁剪，进一步瘦身只能自建 libmpv（只留需要的解码器 / 解复用器），
或 Android 只发 `arm64-v8a`（已按 ABI 拆分发布）。

#### 6.4.5 测试素材

`test/fixtures/mock_site/video/`：项目自制（FFmpeg `testsrc` 彩条 + 秒数计数器、`sine` 正弦音），随仓库按 GPL-3.0 发布，
共约 190 KB：`clip.mp4`（6 s，H.264 + AAC）；`hls/`（主 / 子播放列表、3 个 2 s 分片，AES-128 加密，密钥为虚构的
`tsumugi-test-key`）；`hls/mixed.m3u8`（手写，测试代理的拒绝路径）。代理的其他边界情形（UTF-16 播放列表、WebVTT、压缩编码、断开与取消等）
在 `test/core/network/media/media_proxy_test.dart` 中用测试内构造的上游响应覆盖。生成命令见该目录 README。mock 服务器新增
`/video/search`、`/video/show/1`、`/video/show/1/ep/1..4`、`/video/media/*`（支持 Range）与 `/video/protected/*`
（要求路径以 `/video/` 开头的 Referer，密钥另需 `vtoken` Cookie）；虚构源 `test/fixtures/sources/mock_video_declarative.json`。
多线路 / 多清晰度：JSON 接口 `/video/api/search`、`/video/api/show/2`（线路 A 走 `/video/protected/`，线路 B 走 `/video/media/`，各 3 集）、
`/video/api/play/<a|b>/<n>`（`720p` 为 AES-128 HLS，`360p` 为 MP4），配合虚构脚本源 `test/fixtures/sources/mock_video_script.json`
（脚本即 `test/fixtures/script/video/source.js`，测试检查两者一致）。集成测试用它在真实 libmpv 上覆盖播放页的换清晰度、自动下一集与续播。
视频下载（§4.5.1）另有：`hls/plain.m3u8`（明文 HLS，分片 `hls/plain/seg0-2.ts` 由 mock 服务器把加密分片即时解密得到）、
`hls/live.m3u8`（没有 `EXT-X-ENDLIST`）、`hls/sample_aes.m3u8`、`hls/master_plain.m3u8`（两个变体，带宽高的为明文，带字幕轨）；
`/video/media/*` 带强 `ETag` 与 `Last-Modified` 并按 `If-Range` 决定是否按区间返回（`MockServer.videoRevision` 改变内容版本），
`/video/noetag/*` 不带校验值。

#### 6.4.6 风险与后续拆分

风险：

- **预编译库陈旧，Windows 构建仓库已归档**：Windows 的 mpv / FFmpeg 为 2023-09 的版本，缺少此后的 FFmpeg 安全修复；播放的是第三方源
  提供的内容，属于不可信输入。代理已限制来源主机与内容类型，但无法防御解码器本身的漏洞。**应尽快换成维护中的 LGPL 构建（自建或 fork）**；
  Android（v1.1.7）与 iOS（v0.6.0）也落后于各自构建仓库的最新发布。media_kit 主仓库 2026-08 仍有提交，最近一次发版在 2025 年末。
- **`d3dcompiler_47.dll`**：`media_kit_libs_windows_video` 随 ANGLE 打包的微软可再分发组件（非开源，按 Windows SDK 的再分发条款）。
  Windows 10 起系统目录自带同名 DLL，可视为 GPL-3.0 的“系统库”。**M4-B 起不再打包**（`windows/CMakeLists.txt` 排除），
  ANGLE 使用系统自带的。Windows 11 上验证（2026-11）：`integration_test/video_playback_test.dart` 在不含该 DLL 的构建中通过
  （MP4 与 AES-128 HLS，解码 `d3d11va-copy`）；release 构建启动后进程加载的是 `C:\Windows\System32\d3dcompiler_47.dll`。
  release 构建的界面内手动播放尚未执行，**Windows 10 未测试**。
- **`WebView2Loader.dll`**（M3 起随包）：同为微软的闭源再分发组件，但没有系统自带的副本可用。**保持以动态库随包**（已决定，
  静态链接并不更合规），见 §6.4.1。
- **Windows libmpv 的对应源码不完整**：见 §6.4.1——除 mpv / FFmpeg 等少数组件外，依赖的确切提交与当时的定制脚本都没有记录，
  Release 中的源码包只能尽力而为；已决定接受到自建 libmpv（后续 2）落地为止。
- media_kit 主要由一人维护。播放器只出现在 `features/video/player/` 与 `shared/video/player_options.dart`，代理与播放器无关，
  必要时可以换播放器实现。

建议的 M4 后续拆分（各自独立的 PR）：

1. ~~**第三方许可证与源码分发**~~（M4-B 完成）：`THIRD_PARTY_NOTICES.md`、「关于」页的许可证列表、Release 工作流上传原生组件源码包、
   不再打包 `d3dcompiler_47.dll`，见 §6.4.1。升级 `media_kit_libs_*_video` 时须同步更新 `THIRD_PARTY_NOTICES.md`、
   `assets/licenses/` 与 `tool/release/native_sources.tsv`。
2. **原生库更新**（[#56](https://github.com/Shiroha23/Tsumugi/issues/56)）：上游所有发布仍是 FFmpeg 6.0。**当前决定（2026-11-18）：等待 media_kit 上游发布新的原生库包**，届时按本节第 1 项同步升级；在此之前已知风险是解码器缺少 2023 年以后的安全修复（媒体代理只能限制来源主机与内容类型）。同时观察 better_player：已评估可用（Android ExoPlayer / iOS AVPlayer，经本地代理播放正常），但其 Windows 实现是 libmpv 软件渲染，1080p60 时 raster p95 约 16.5 ms（media_kit 约 0.7 ms），因此等它改用 mpv 0.42 起提供的 D3D11 渲染接口后再评估迁移。两者都没有进展时，再考虑自建 libmpv，见该 issue。
3. ~~**播放页完善**~~（已完成，见 §5.2「视频播放」）：选集与线路、上一集 / 下一集（含播完自动下一集）、播放进度记忆与书架 / 历史接入、
   清晰度切换。
4. ~~**字幕**~~（已完成，见 §5.2「视频播放」与 §6.4.7）：外挂字幕（srt / vtt / ass）由 Dart 侧经源的网络层取回、解析并显示，
   HLS 字幕轨可选。未做：ASS 样式（位置、颜色、特效，[#54](https://github.com/Shiroha23/Tsumugi/issues/54)）、声明式引擎的 `subtitles` 键（[#53](https://github.com/Shiroha23/Tsumugi/issues/53)）。
   另：`openStream` 取消后上游连接“似乎没有断开”（[#52](https://github.com/Shiroha23/Tsumugi/issues/52)）经核实是测试上游的假象，
   连接实际已关闭，见 §6.4.3「取消与资源」。
5. **DASH**：**已决定（2026-11）：apiVersion 1 不支持**，已写入 source-spec §5。MPD 改写（`BaseURL`、`SegmentTemplate`、`SegmentList` 等）
   涉及代理的地址边界，推迟到有实际需求时单独评估（[#42](https://github.com/Shiroha23/Tsumugi/issues/42)）。
6. ~~**移动端交互**~~（已完成，见 §5.2「视频播放」）：横竖屏全屏、触控手势、屏幕常亮、切到后台时暂停。
   未做：音量 / 亮度手势（需新原生依赖）、转动手机自动进入全屏；iOS 真机（#31）。后台播放留给 M5。
7. ~~**限速与缓存**~~（已完成）：令牌桶移到按源的 `SourceSession`，源实例、图片加载与媒体代理共用；分片走每源固定的媒体配额；
   mpv 磁盘缓存评估后保持关闭（§6.4.3「限速」「播放器缓存」）。
8. ~~**media_kit_video fork**~~（[#49](https://github.com/Shiroha23/Tsumugi/issues/49)）：实测不可行，保留“重新打开”方案（§6.4.2）。
   上游修复 Android 输出初始化与 HLS 的冲突后，可去掉重新打开（升级 media_kit 时在真机上复测）。

#### 6.4.7 字幕（M4，2026-11）

**结论：外挂字幕（`VideoContent.subtitles`）由 Dart 侧经源的网络层取回、校验、解码、解析为纯文本时间轴，由 Flutter 显示；
不交给 libmpv。** HLS 流自带的字幕轨仍由 libmpv 经代理取得（只有 WebVTT，§6.4.3），但同样只取其文本、由 Flutter 显示。

比较的两条路：

| | (a) Dart 取回、解析、自己渲染 ✅ | (b) 经代理交给 libmpv 作为外挂字幕（`sub-add`） |
|---|---|---|
| 网络边界 | 一次性请求，经该源的 `SourceHttpClient`（白名单含每跳重定向、Cookie、默认 headers、限速），与图片同一路径 | 同样经源的网络层，但代理要新增“字幕文件”这一类内容并为它定义识别规则 |
| 解析不可信内容的代码 | Dart（内存安全），本项目自己的小解析器，有大小 / 条数上限 | FFmpeg 的 srt / webvtt / ass 解复用器与解码器 + **libass**（ASS 事件解析）；`[Fonts]` 中的内嵌字体交给 **FreeType** 解析，绘图指令（`\p`）交给 libass 光栅化。Windows 的 libass / FreeType 版本未记录、停在 2023-09（§6.4.1），无法评估其漏洞 |
| 编码 | 复用 `core/encoding`，GBK 等有确定的回退规则 | 依赖 mpv 的 `sub-codepage`（uchardet 猜测），无法套用 source-spec §5 的规则 |
| 显示 | 纯文本；ASS 的位置 / 颜色 / 特效丢失 | media_kit 默认 `libass: false`，本来就只取 `sub-text` 的纯文本由 Flutter 显示，样式同样丢失 |

(b) 在显示效果上没有收益（media_kit 不启用 libass 渲染），却把 ASS 的字体与绘图解析交给过期的原生库，扩大了播放器的攻击面；
(a) 只多一个小的 Dart 解析器。因此选 (a)，播放器侧保持 `sub-auto=no`、不调用 `sub-add`。

**取回**（`core/subtitle/subtitle_loader.dart`，`shared/video/subtitle_providers.dart`）：用与代理相同的方式为该源新建客户端
（该源的 `SourceSession`：Cookie、UA、令牌桶），`openStream` 走 `source` 通道（计入 `rateLimit`，每条字幕每集一个请求），
不经本地代理（代理只服务播放器）。整个请求（含限速排队、响应头与响应体）不超过 30 s（`openStream` 的超时只限制相邻两块数据的间隔，
慢速上游可以一直拖着），换集 / 离开页面时取消。非 2xx、白名单外、人机验证等与其他请求一样失败。`SubtitleRef` 没有 `headers`，只带清单的默认 headers。

**校验**（`core/subtitle/subtitle_parser.dart`，任何一项不满足即拒绝，提示“字幕加载失败”）：

- **大小**：响应体不超过 4 MB（`Content-Length` 超过时不读，读取中超过时中止）。带大量内嵌字体的 ASS 可能因此被拒，内嵌字体本来也不用。
- **编码**（source-spec §2.2）：`SubtitleRef.charset` → BOM（UTF-8 / UTF-16）→ `Content-Type` 的 charset → 整段是合法 UTF-8 时按 UTF-8 →
  否则按 GB18030（GBK / GB2312 的超集，中文字幕最常见的非 UTF-8 编码）。Big5、Shift_JIS 等需要源声明 `charset`。
  解码后含 U+0000 的（二进制、声明错误的 UTF-16 等）拒绝。
- **格式按内容识别**（不信任 `Content-Type` 与扩展名）：去掉 BOM 与开头空白后，以 `WEBVTT` 开头（其后为空白或结尾）→ vtt；
  以 `[Script Info]` 开头 → ass（含 SSA）；第一个非空行是序号、下一行是时间轴，或第一行即时间轴 → srt。识别不了的（HTML 错误页、
  JSON、播放列表等）拒绝；`SubtitleRef.format` 给出时必须与识别结果一致。
- **内容**：最多 20000 条，单条文字最多 2000 个字符（超出截断）；结束不晚于开始、时间无法解析的条目丢弃；一条都没有时拒绝。

**解析**：只取时间与文字。srt / vtt 去掉标签（`<i>`、`<font …>`、`<c.x>`、`<v 名字>`、时间戳标签，以及 srt 中常见的 `{\an8}`），
解码 vtt 的字符实体；vtt 跳过 `NOTE` / `STYLE` / `REGION` 块。ass 只读 `[Events]` 中按 `Format:` 定位的 `Dialogue:` 行的
`Start` / `End` / `Text`，忽略 `[Fonts]` / `[Graphics]`（不解码内嵌数据）与样式；`{…}` 覆盖标签全部去掉，`\N` 为换行，`\n`（软换行，只在 WrapStyle 2 下换行）与
`\h` 为空格，绘图模式（`\p1` 起到 `\p0`）中的文字（绘图指令）丢弃。同一时刻的多条按开始时间以换行连接显示。
去标签用线性的手写扫描（正则在大量未闭合的 `<` / `{` 上耗时超平方，几十 KB 的一行就能卡住数十秒）；
按位置取文字用结束时间的最大值线段树，一条很长的 cue（如整集水印）不会让每次查询回扫全部条目。

**HLS 字幕轨**：代理只把字幕播放列表中以 `WEBVTT` 开头的分片交给播放器（§6.4.3），libmpv 经 FFmpeg 的 WebVTT 解码器得到文本，
media_kit（`libass: false`）设 `sub-visibility=no`、只读 `sub-text`。WebVTT 没有字体 / 绘图，这一面在 M4 之前就已存在，字幕功能没有扩大它。

**测试**：`test/fixtures/mock_site/video/subs/`（自制的 srt / vtt / ass，含 GBK 编码的 srt、带内嵌字体段与绘图指令的 ass、
伪装成字幕的 HTML）与 `hls/sub.m3u8`、`hls/sub0-2.vtt`；mock 服务器 `/video/{media,protected}/subs/*` 与 HLS 字幕播放列表 `hls/master_sub.m3u8`，虚构脚本源 `mock_video_script.json` 的每集都带字幕。

## 7. 里程碑

| 阶段 | 内容 |
|---|---|
| M0 | 项目骨架、CI（三平台构建 + 测试）、JS 运行时技术验证 |
| M1 | 核心：网络层、声明式规则引擎、JS 沙箱、源管理、mock 服务器 |
| M2 | 漫画 MVP：搜索、详情、阅读器、书架、历史 |
| M3 | 小说：阅读器、排版、导出 |
| M4 | 视频：media_kit 播放器、选集、倍速、进度记忆 |
| M5 | 音乐：播放列表、后台播放、歌词（2026-11-18 决定暂缓，先做 M6） |
| M6 | 规则仓库订阅、下载管理（第一期：漫画 / 小说）、WebDAV 同步，见 §4.3–§4.6 |
| M6 第二期 | 视频下载与后台下载（Android 前台服务 / iOS 宽限时间），见 §4.5.1 |

## 8. 安全原则

- 源脚本运行在沙箱中，只能使用 `docs/source-spec.md` 定义的宿主 API。
- 禁止脚本访问文件系统、其他源的存储与 Cookie、任意原生能力。
- 单次脚本调用有 CPU 时间与内存上限，超时强制终止。
- 安装来自仓库的源时校验 sha256；安装/更新时向用户展示源的请求域名，新增的域名单独确认（§4.4）。
- 从 WebDAV 同步来的源与本地导入一样，必须经用户预览确认后才安装（§4.6）。
- 下载文件的路径只由哈希与序号构成，不使用源返回的字符串（§4.5）；视频下载存解密后的明文，只在应用私有目录，离线回放仍经本地媒体代理（§4.5.1）；WebDAV 密码只存系统安全存储（§4.6）。
