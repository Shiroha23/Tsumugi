# Tsumugi 源规范（apiVersion 1，草案）

> 状态：草案，待评审。规范一旦发布，破坏性改动必须提升 `apiVersion`，
> 客户端需同时支持当前与上一个 apiVersion。

本文定义第三方“源”的格式。一个源描述了如何从某个站点获取某一类媒体内容。
源分两种引擎：

- **declarative**：纯 JSON，用选择器表达式描述抓取规则，适合简单站点。
- **script**：JSON 清单 + 一段 JS，在沙箱中执行，适合需要加解密、签名、复杂分页的站点。

文中所有示例均使用虚构域名 `example.com`。

---

## 1. 源清单（Manifest）

```jsonc
{
  "apiVersion": 1,
  "id": "com.example.comic",      // 全局唯一，反向域名风格，[a-z0-9._-]
  "name": "示例漫画",
  "type": "comic",                // comic | novel | video | music
  "version": "1.0.0",             // 语义化版本，用于仓库更新判断
  "author": "someone",
  "description": "",
  "lang": "zh",                   // BCP 47
  "nsfw": false,
  "icon": "https://example.com/favicon.ico",
  "baseUrl": "https://example.com",
  "allowedHosts": ["example.com", "img.example.com"], // 网络白名单，见 §5
  "headers": { "User-Agent": "...", "Referer": "https://example.com/" },
  "rateLimit": { "requests": 5, "perSeconds": 1 },
  "timeoutMs": 15000,

  "settings": [                   // 可选：用户可调的源设置
    { "key": "quality", "label": "画质", "type": "select",
      "options": ["high", "low"], "default": "high" }
  ],

  "engine": "declarative",        // declarative | script
  "rules": { /* engine=declarative 时，见 §3 */ },
  "script": null                  // engine=script 时，JS 源码字符串或相对路径，见 §4
}
```

**校验规则**

- `id`、`name`、`type`、`version`、`baseUrl`、`engine` 必填。
- 所有请求的主机名必须属于 `baseUrl` 的主机或 `allowedHosts`（支持 `*.example.com` 通配）。
- 未知字段忽略（向前兼容），但会在调试面板中给出警告。

---

## 2. 统一数据模型

各引擎最终都产出以下结构（字段名即 JSON 键名）。

### 2.1 通用

```ts
type Headers = Record<string, string>;

interface PageResult<T> {
  items: T[];
  hasMore: boolean;
}

interface SearchItem {
  id: string;            // 源内唯一，通常是详情页相对 URL
  title: string;
  cover?: string;
  coverHeaders?: Headers;
  subtitle?: string;     // 作者 / 歌手 / 更新状态 等
  tags?: string[];
}

interface Detail {
  id: string;
  title: string;
  cover?: string;
  author?: string;
  description?: string;
  tags?: string[];
  status?: "ongoing" | "completed" | "unknown";
  updatedAt?: string;    // ISO 8601
  units: Unit[];         // 章节 / 剧集 / 曲目
  // video 可有多个线路：
  groups?: { name: string; units: Unit[] }[];
}

interface Unit {         // 章节 / 剧集 / 曲目的统一抽象
  id: string;
  title: string;
  index?: number;
  updatedAt?: string;
}
```

### 2.2 按类型的内容（content）

```ts
// comic
interface ComicContent {
  images: { url: string; headers?: Headers }[];
}

// novel
interface NovelContent {
  text: string;          // 纯文本，段落以 \n 分隔；或 html=true 时为受限 HTML
  html?: boolean;
  nextPageId?: string;   // 章节内分页
}

// video
interface VideoContent {
  streams: {
    url: string;
    type?: "hls" | "dash" | "mp4" | "auto";
    quality?: string;    // "1080p" 等
    headers?: Headers;
  }[];
  subtitles?: { url: string; lang?: string; format?: "srt" | "vtt" | "ass" }[];
}

// music
interface MusicContent {
  streams: { url: string; quality?: string; headers?: Headers }[];
  lyrics?: { format: "lrc" | "text"; content: string };
}
```

---

## 3. 声明式引擎（engine = "declarative"）

### 3.1 结构

```jsonc
"rules": {
  "search": {
    "request": {
      "url": "/search?q={{keyword}}&page={{page}}",
      "method": "GET",                 // GET | POST
      "body": null,                    // POST 时的模板字符串
      "headers": {}
    },
    "list": "css:.result-item",        // 列表节点
    "fields": {                        // 对每个列表节点求值
      "id": "css:a@href",
      "title": "css:.title@text",
      "cover": "css:img@data-src || css:img@src",
      "subtitle": "css:.author@text"
    },
    "hasMore": "css:.pagination .next" // 存在即为 true
  },

  "explore": [                         // 可选：发现页，多个分类
    { "name": "最新", "request": { "url": "/latest?page={{page}}" },
      "list": "...", "fields": { "...": "..." } }
  ],

  "detail": {
    "request": { "url": "{{id}}" },
    "fields": {
      "title": "css:h1@text",
      "cover": "css:.cover img@src",
      "author": "css:.author@text",
      "description": "css:.intro@text",
      "tags": "css:.tags a@text[]"
    },
    "units": {
      "list": "css:.chapter-list li",
      "fields": { "id": "css:a@href", "title": "css:a@text" },
      "reverse": true                  // 站点倒序列出时反转
    }
  },

  "content": {
    "request": { "url": "{{unitId}}" },
    // comic:
    "images": "css:.page img@data-src[]"
    // novel:  "text": "css:#content@text", "nextPageId": "css:a.next@href"
    // video:  "streams": "regex:\"url\":\"(.+?\\.m3u8)\"@1[]"
  }
}
```

**补充说明**

- `detail.request` 可省略，默认 `{ "url": "{{id}}" }`；`content.request` 可省略，默认 `{ "url": "{{unitId}}" }`。
- `list` 表达式总是取全部匹配（无需 `[]`），且不做默认提取：每个匹配节点（HTML 元素或 JSON 值）
  作为 `fields` 中各表达式的输入。
- 列表条目缺少 `id` 或 `title` 时跳过该条目；unit 缺少 `id` 时跳过。unit 的 `index` 为（反转后的）序号，从 0 开始。
- `hasMore`：结果非空即为 true（匹配到的节点即使没有文本也算），但单个值 `false` / `0` 视为 false（便于 JSON 接口）。省略时为 false。
- `explore` 分类的 id 为其在数组中的下标（`"0"`、`"1"`…）。
- `POST` 且规则未给出 `Content-Type` 时：`body` 以 `{` 或 `[` 开头按 `application/json`，否则按
  `application/x-www-form-urlencoded`。
- 清单 `headers` 会合并到每个请求，并附在封面（`coverHeaders`）、图片与流的 `headers` 上（§5）。

**`content` 的键（按清单 `type`）**

| type | 键 | 说明 |
|---|---|---|
| comic | `images` | 多值，图片 URL |
| novel | `text`、`nextPageId` | `text` 为多值时以 `\n` 连接；`nextPageId` 作为下一次 `content` 的 `unitId` |
| video | `streams` | 多值，流 URL；`type` 按扩展名推断（`.m3u8`→hls，`.mpd`→dash，`.mp4`→mp4，其余 auto） |
| music | `streams`、`lyrics` | `lyrics` 含 `[mm:ss` 时间标签时 `format` 为 `lrc`，否则为 `text` |

其他键忽略并在调试日志中警告。

### 3.2 模板变量

| 变量 | 可用位置 | 说明 |
|---|---|---|
| `{{keyword}}` | search | 已 URL 编码 |
| `{{page}}` | search / explore | 从 1 开始 |
| `{{id}}` | detail | SearchItem.id |
| `{{unitId}}` | content | Unit.id |
| `{{baseUrl}}` | 全部 | 清单中的 baseUrl |
| `{{setting.<key>}}` | 全部 | 用户设置值 |

相对 URL 一律基于 `baseUrl` 解析：请求地址，以及结果中的 `cover` / 图片 / 流地址都会解析为绝对 URL；
`id`、unit `id`、`nextPageId` 保持原样，在下一次请求时再解析。

未定义的变量替换为空字符串并记录调试日志。请求主机必须在白名单内（§5），否则返回 `E_HOST_NOT_ALLOWED`。

### 3.3 选择器表达式

格式：`<引擎>:<选择器>[@<提取>][[]]`

| 引擎 | 示例 | 说明 |
|---|---|---|
| `css` | `css:.item > a@href` | CSS 选择器 |
| `xpath` | `xpath://div[@class='t']/text()` | XPath 1.0 |
| `json` | `json:$.data.list[*].name` | JSONPath（响应为 JSON 时） |
| `regex` | `regex:src="(.+?)"@1` | 对原始文本匹配，`@n` 取第 n 个捕获组 |
| `js` | `js:result.trim()` | 小段 JS 后处理，`result` 为上一步值；在同一沙箱中执行 |

**提取（`@`）**：`@text`（默认，去首尾空白）、`@html`、`@outerHtml`、`@<属性名>`、regex 的 `@<组号>`。

**多值**：末尾 `[]` 表示取全部匹配，返回数组；否则只取第一个。

**组合**：

- `A || B`：A 结果为空时用 B（回退）。
- `A |> B`：A 的结果作为 B 的输入（管道），例如 `css:script@text |> regex:var url='(.+?)'@1`。

表达式求值失败时返回空值，并在调试日志中记录，不抛出到 UI。

**细则**

- 默认提取：css / xpath 取文本（去首尾空白）；regex 取整个匹配（组 0）；json 取匹配值本身
  （字符串原样，数字 / 布尔转字符串，对象 / 数组序列化为 JSON）。`null` 视为空。
- `json` 不支持 `@提取`：JSONPath（RFC 9535）在过滤器中用 `@` 表示当前节点，如 `json:$.list[?@.score > 8].name[]`。
- `xpath` 的 `@提取` 只在 `@` 紧跟名称、`]`、`)`、`*` 或引号之后时识别，因此 `xpath://a/@href`
  是 XPath 属性轴，`xpath://a@href` 是提取，两者结果相同。XPath 结果可以是元素、属性、文本节点或原子值
  （如 `count(//li)`）。
- `||` / `|>` 只在其后紧跟 `<引擎>:` 时才是运算符，因此 JS 代码或正则中的 `||` 不会被切分。`|>` 优先级高于 `||`。
- 管道：中间步骤没有 `@提取` 时把原始节点传给下一步（如 `css:#intro |> css:b`）；上一步为多值时，
  css / xpath / json / regex 步骤对每个值分别求值后拼接。只要任一步骤带 `[]`，结果即为多值。
  css / xpath 的输入为字符串时按 HTML 解析，json 的输入为字符串时按 JSON 解析，regex 作用于元素时匹配其 outerHtml。
- 任一步骤为空（包括提取出的空字符串）或失败，整条管道为空，进而触发 `||` 回退。
- `js:` 之后是一个 **JS 表达式**（不是语句），其值即结果；`result` 为上一步的值（多值时为数组，
  作为首个步骤时：对整份响应为原始文本，对列表条目为其文本或 JSON 值），只能是 JSON 兼容值。返回数组即为多值，返回 `null` / `undefined` 即为空。
  同一个源的所有 `js:` 片段在同一个沙箱中执行（限制同 §4.4），沙箱中不提供 `tsumugi` 宿主 API，
  `eval` / `Function` 不可用。片段在加载源时统一编译，单个片段的语法错误只影响它自己。

---

## 4. 脚本引擎（engine = "script"）

### 4.1 入口

脚本是一个 ES2020 模块，导出以下异步函数（未实现的视为不支持该能力）。
模块不能 `import` 其他模块，也不支持顶层 `await`；`eval` 与 `Function` 构造器不可用。

```js
export async function search(keyword, page) { /* → PageResult<SearchItem> */ }
export async function explore() { /* → [{ name, id }]，可选 */ }
export async function exploreList(categoryId, page) { /* → PageResult<SearchItem> */ }
export async function detail(id) { /* → Detail */ }
export async function content(unitId) { /* → ComicContent | NovelContent | VideoContent | MusicContent */ }
```

### 4.2 宿主 API（全局对象 `tsumugi`）

所有 I/O 均为异步。**除此之外不存在任何宿主能力**（无 `fetch`、无文件系统、无定时器以外的原生 API）。

```ts
declare const tsumugi: {
  source: { id: string; baseUrl: string; settings: Record<string, unknown> };

  http: {
    request(opts: {
      url: string;                       // 相对 URL 基于 baseUrl
      method?: "GET" | "POST" | "PUT" | "DELETE" | "HEAD";
      headers?: Headers;
      body?: string | Record<string, unknown>; // 对象时按 JSON 发送
      form?: Record<string, string>;     // application/x-www-form-urlencoded
      responseType?: "text" | "json" | "bytes";
      followRedirects?: boolean;         // 默认 true
    }): Promise<{ status: number; headers: Headers; url: string; body: any }>;
    get(url: string, headers?: Headers): Promise<string>;   // 便捷方法，返回文本
    getJson(url: string, headers?: Headers): Promise<any>;
  };

  html: {
    parse(text: string, baseUrl?: string): HtmlNode;
  };

  crypto: {
    md5(s: string): string;              // 返回 hex
    sha1(s: string): string;
    sha256(s: string): string;
    hmacSha256(key: string, s: string): string;
    base64Encode(s: string): string;
    base64Decode(s: string): string;
    aesDecrypt(opts: { data: string; key: string; iv?: string;
                       mode: "CBC" | "ECB" | "GCM"; encoding?: "base64" | "hex" }): string;
    aesEncrypt(opts: { /* 同上 */ }): string;
  };

  storage: {                             // 按源隔离的 KV，值需可 JSON 序列化
    get(key: string): Promise<any>;
    set(key: string, value: any): Promise<void>;
    remove(key: string): Promise<void>;
  };

  cookies: {                             // 仅限本源的 Cookie 域
    get(url: string): Promise<Record<string, string>>;
    set(url: string, name: string, value: string): Promise<void>;
  };

  ui: {
    // 请求用户在 WebView 中手动完成登录/验证，完成后 Cookie 自动写回本源
    openWebView(url: string, opts?: { title?: string; doneWhenUrlMatches?: string }): Promise<void>;
    toast(message: string): void;
  };

  log: { debug(...a: any[]): void; info(...a: any[]): void; error(...a: any[]): void };
};

interface HtmlNode {
  select(css: string): HtmlNode[];
  selectFirst(css: string): HtmlNode | null;
  xpath(expr: string): HtmlNode[];
  text(): string;
  html(): string;
  outerHtml(): string;
  attr(name: string): string | null;
  absUrl(attrName: string): string | null;
}
```

### 4.3 示例

```js
export async function search(keyword, page) {
  const doc = tsumugi.html.parse(
    await tsumugi.http.get(`/search?q=${encodeURIComponent(keyword)}&page=${page}`)
  );
  return {
    items: doc.select(".result-item").map(n => ({
      id: n.selectFirst("a").attr("href"),
      title: n.selectFirst(".title").text(),
      cover: n.selectFirst("img")?.absUrl("data-src"),
    })),
    hasMore: doc.selectFirst(".pagination .next") != null,
  };
}
```

### 4.4 沙箱限制

| 限制 | 默认值 |
|---|---|
| 单次入口函数调用的总时长 | 30 s（含网络等待） |
| 纯 CPU 执行时间 | 5 s |
| 内存 | 64 MB |
| 单次调用的 HTTP 请求数 | 50 |
| 单个响应体大小 | 20 MB |

超限时终止脚本，返回错误 `E_LIMIT`。补充说明：

- CPU 时间与总时长超限不可被脚本 `try/catch` 拦截。
- 内存与栈超限表现为**分配失败的异常**：未捕获时返回 `E_LIMIT`；脚本可以 catch 它继续执行，
  但超限的那次分配本身不会成功，内存上限始终有效。
- 触发 `E_LIMIT` 后，客户端会丢弃该源的 JS 运行时并重新求值模块，**模块级变量会被重置**。
  需要跨调用保存的数据请使用 `tsumugi.storage`。
- 宿主函数只能在入口调用进行期间使用；调用结束后才执行到的宿主调用会被拒绝。
- 单次调用的 HTTP 请求数由宿主 HTTP API 计数（待接入）；响应体大小由网络层强制（§5）。

---

## 5. 网络行为（两种引擎共同遵守）

- 每个源有独立的 Cookie 域、限速队列与默认 headers。
- 请求目标主机不在 `baseUrl` 主机或 `allowedHosts` 中时，拒绝请求并返回 `E_HOST_NOT_ALLOWED`。
  **重定向的每一跳**同样检查；`followRedirects: false` 时直接返回 3xx 响应，由源自行处理。
  跨主机重定向时不转发源显式设置的 `Authorization` / `Cookie` 头（Cookie 域中的 Cookie 照常按主机附加）。
- `timeoutMs` 是单次尝试（连接 + 等待响应 + 读取响应体）的上限，不含限速排队；超时 → `E_NETWORK`。
- `rateLimit` 按令牌桶执行：允许突发 `requests` 个，之后每 `perSeconds / requests` 秒放行一个；
  重试与重定向的每一跳都计入。
- 幂等请求（GET / HEAD / PUT / DELETE / OPTIONS）在连接错误或 5xx 时最多自动重试 2 次（指数退避），
  超时与非幂等请求（POST / PATCH）不重试。
- 检测到人机验证页面（403 / 429 / 503 且带有验证页特征）时返回 `E_CHALLENGE`，不重试、不尝试绕过；
  UI 引导用户在 WebView 中手动完成后再重试（见 architecture §5.3）。
- 单个响应体超过 20 MB → `E_LIMIT`。
- 图片、音视频流的 headers 由内容结构中的 `headers` 字段携带给加载器/播放器。

## 6. 错误码

| 码 | 含义 |
|---|---|
| `E_NETWORK` | 网络错误 / 超时 |
| `E_HTTP` | 非 2xx 响应（附带 status） |
| `E_PARSE` | 解析失败 |
| `E_CHALLENGE` | 需要用户完成验证（UI 会提示打开 WebView） |
| `E_LOGIN_REQUIRED` | 需要登录 |
| `E_HOST_NOT_ALLOWED` | 请求了白名单外的主机 |
| `E_LIMIT` | 触发沙箱限制 |
| `E_UNSUPPORTED` | 源未实现该能力 |

脚本可 `throw { code: "E_LOGIN_REQUIRED", message: "..." }` 主动上报。脚本显式给出的 `code`
优先于一切按消息文本的推断。`E_HTTP` 可附带 `status`（100–599 的整数）：
`throw { code: "E_HTTP", status: 503, message: "..." }`；宿主 API 抛出的 `E_HTTP` 错误同样带有 `status`，
脚本可通过 `e.status` 读取。

---

## 7. 规则仓库（Repository）

仓库是一个可通过 HTTPS 访问的 `index.json`：

```jsonc
{
  "repoVersion": 1,
  "name": "某某的源仓库",
  "sources": [
    {
      "id": "com.example.comic",
      "name": "示例漫画",
      "type": "comic",
      "version": "1.0.0",
      "apiVersion": 1,
      "lang": "zh",
      "nsfw": false,
      "url": "sources/com.example.comic.json", // 相对 index.json
      "sha256": "…"                            // 清单文件的哈希，安装时校验
    }
  ]
}
```

客户端行为：

- 订阅仓库后定期检查更新，`version` 更高时提示更新。
- `apiVersion` 高于客户端支持的版本时，标记为“需要更新客户端”，不允许安装。
- 安装 / 更新时向用户展示该源会访问的主机列表。

---

## 8. 待定问题

- [ ] declarative 的 `content` 是否需要支持多步请求（例如先取 iframe 地址再取 m3u8）？还是要求改用 script？
- [ ] 小说的 `html=true` 允许哪些标签？
- [ ] 是否需要源签名（作者公钥）？
- [ ] 是否兼容导入 Legado 书源格式（作为转换器，而非原生支持）？
