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

### 3.2 模板变量

| 变量 | 可用位置 | 说明 |
|---|---|---|
| `{{keyword}}` | search | 已 URL 编码 |
| `{{page}}` | search / explore | 从 1 开始 |
| `{{id}}` | detail | SearchItem.id |
| `{{unitId}}` | content | Unit.id |
| `{{baseUrl}}` | 全部 | 清单中的 baseUrl |
| `{{setting.<key>}}` | 全部 | 用户设置值 |

相对 URL 一律基于 `baseUrl` 解析。

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

---

## 4. 脚本引擎（engine = "script"）

### 4.1 入口

脚本是一个 ES2020 模块，导出以下异步函数（未实现的视为不支持该能力）：

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

超限时终止脚本，返回错误 `E_LIMIT`。

---

## 5. 网络行为（两种引擎共同遵守）

- 每个源有独立的 Cookie 域、限速队列与默认 headers。
- 请求目标主机不在 `baseUrl` 主机或 `allowedHosts` 中时，拒绝请求并返回 `E_HOST_NOT_ALLOWED`。
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

脚本可 `throw { code: "E_LOGIN_REQUIRED", message: "..." }` 主动上报。

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
