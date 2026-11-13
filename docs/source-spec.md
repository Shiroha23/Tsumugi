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

#### 2.2.1 小说正文（`NovelContent`）

**纯文本**（`html` 省略或为 `false`）：按 `\n`（或 `\r\n`）切分为段落；每段去除首尾空白
（含全角空格 `U+3000` 与不换行空格 `U+00A0`），空段丢弃。段首缩进由阅读器统一添加，源不必、也不应自行缩进。

**受限 HTML**（`html = true`）：客户端解析后按白名单转换为自己的排版结构，**从不交给浏览器 / WebView 渲染**。

| 类别 | 标签 | 处理 |
|---|---|---|
| 块级 | `p` `div` `h1`–`h4` `blockquote` | 各自成段；`h1`–`h4` 为标题样式，`blockquote` 为引用样式 |
| 换段 | `br` | 结束当前段落（等同段落分隔） |
| 分隔线 | `hr` | 独立成块 |
| 行内 | `span` `em` `i` `strong` `b` `u` `s` `del` | `em`/`i` 斜体，`strong`/`b` 粗体，`u` 下划线，`s`/`del` 删除线，`span` 无样式 |
| 注音 | `ruby` `rt` `rp` | `rt` 以小号字紧随其基字显示，`rp` 丢弃 |
| 图片 | `img` | 只读取 `src` 与 `alt`；独立成块（段落内的图片会把段落拆开） |
| 整体丢弃（含内容） | `script` `style` `template` `noscript` `iframe` `frame` `frameset` `object` `embed` `applet` `svg` `math` `canvas` `audio` `video` `source` `track` `head` `title` `meta` `link` `base` `form` `input` `button` `select` `option` `textarea` | |
| 其他 | 任意其他标签（如 `a`、`font`、`table`、`li`） | 去掉标签、保留文字；`table` / `ul` / `ol` / `li` / `section` / `article` 等块级容器按段落边界处理 |

- **属性**：除 `img` 的 `src` / `alt` 外，所有属性（含 `style`、`class`、`id`、全部 `on*` 事件、`href`）一律丢弃。
- **`img src`**：相对地址基于清单 `baseUrl` 解析；解析后只接受 `http` / `https`（`data:`、`javascript:` 等丢弃整张图片）。
  图片经统一图片加载器下载，携带清单 `headers`，同样受主机白名单（§5）约束。
- **空白**：连续空白折叠为一个空格；每段首尾空白（含 `U+3000`、`U+00A0`）去除，空段丢弃。HTML 实体正常解码。

**章节内分页**：`nextPageId` 不为空时，客户端以它作为 `unitId` 再次调用 `content`，把各页正文按顺序拼接为一章。
出现以下情况时停止：`nextPageId` 为空、与已取过的页重复、等于详情中某个章节的 `id`（即“下一页”实为下一章），
或已取满 100 页。

**阅读位置**：小说的进度 `position` 是**章节内字符偏移**，以“各块按顺序以 `\n` 连接”的纯文本计算：
段落为其文字（`rt` 注音计入，缩进不计入），图片与分隔线各计 1 个字符。

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
      "headers": {},
      "charset": null                  // 可选：强制按此字符集解码响应，如 "gbk"（§5）
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
- `request.charset` 可选，用于 `Content-Type` / `<meta>` 缺失或声明错误的站点；必须是 §5 支持的字符集标签，
  否则创建源时报 `E_PARSE`。
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

每个规则（`search` / `explore` / `detail` / `content`）**只发一次请求**。同一页面内的间接取值用 `|>` 管道
（如 `css:script@text |> regex:...`）；需要多次请求才能拿到内容的站点（例如先取 iframe 地址再取 m3u8），
请改用 `script` 引擎（§4）。见 §8 第 1 项。

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

**返回值规范化**（客户端在解析为 §2 模型之前进行）：

- `cover`、图片 / 流 / 字幕的 `url` 为相对地址时基于 `baseUrl` 解析为绝对地址；`id`、unit `id`、`nextPageId` 保持原样。
- 清单 `headers` 合并到 `coverHeaders` 与图片 / 流的 `headers`（结果中的同名项优先）。
- `images` / `streams` 的元素可以直接写成 URL 字符串，等价于 `{ url }`。
- `explore()` 返回的数字 `id` 转为字符串；`detail()` 省略 `units` 时视为空数组。
- 返回值不符合 §2 结构 → `E_PARSE`（`images` / `streams` / `subtitles` 中既不是字符串也不是对象的元素同样报错，不会被静默丢弃）；
  未捕获的普通 JS 异常（没有 `code`）以及未知的 `code` 同样报告为 `E_PARSE`。
- 模块求值（加载）失败时同样保留错误码：顶层超限 → `E_LIMIT`，顶层 `throw { code, status }` 原样上报，其余 → `E_PARSE`。
- `script` 字段目前只支持内联源码（以相对路径引用的脚本返回 `E_UNSUPPORTED`）。

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
      charset?: string;                  // 强制按此字符集解码 text / json（如 "gbk"），默认自动识别（§5）
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

**细则**

- `tsumugi` 及其各命名空间、`tsumugi.source`（含 `settings`）均被冻结。`settings` 为用户设置值，未设置的键取清单默认值。
- `http.request`：`method` 不区分大小写，只允许上面列出的五种；`body` 为字符串时按 `text/plain` 发送，
  为对象 / 数组时按 JSON 发送；`body` 与 `form` 不能同时给出。非 2xx 响应**不抛出**，由脚本检查 `status`；
  `headers` 的名称为小写。`responseType: "json"` 时 `body` 为解析后的值（空响应体为 `null`，解析失败 → `E_PARSE`），
  `"bytes"` 时为 **base64 字符串**。`charset` 只影响 `text` / `json`，必须是 §5 支持的标签，否则抛出普通异常；
  `http.get` / `http.getJson` 总是自动识别。
- `http.get` / `http.getJson`：非 2xx 抛出 `E_HTTP`（带 `status`），`getJson` 解析失败 → `E_PARSE`。
- 所有 `http.*` 的错误码见 §6：网络错误 / 超时 → `E_NETWORK`，白名单外（含重定向）→ `E_HOST_NOT_ALLOWED`，
  人机验证页 → `E_CHALLENGE`，响应体过大 → `E_LIMIT`。
- `crypto`：字符串参数按 UTF-8 编码；摘要返回小写十六进制；`base64Decode` 与 `aesDecrypt` 的结果按 UTF-8 **严格**解码，
  不是合法 UTF-8 时 → `E_PARSE`。
  AES 的 `key` / `iv` 默认按 UTF-8，可用可选的 `keyEncoding` / `ivEncoding`（`"utf8"` | `"hex"` | `"base64"`）指定；
  `data` 的明文按 UTF-8、密文按 `encoding`（默认 `base64`）。key 必须为 16 / 24 / 32 字节；CBC 需要 16 字节 iv，
  CBC / ECB 使用 PKCS#7 填充；GCM 需要 iv（通常 12 字节），128 位认证标签附在密文末尾。
  参数非法抛出普通异常；解密失败（填充 / 标签 / 编码错误）→ `E_PARSE`。
- `storage`：值以 JSON 保存，`set(key, null)` 等同于 `remove(key)`；键长 1–256 字符，不能包含 NUL。
  长度单位为 Unicode 码点：单个值 JSON 编码后最多 1 Mi，单个源（键 + 值）总计最多 10 Mi，超出 → `E_LIMIT`。
  配额检查与写入是原子的（并发的 `set`、同一源的多个实例都不能共同超额）。写操作绑定发起它的调用：
  调用结束后才轮到的写入 / 删除被丢弃。卸载源时一并删除。
- `cookies`：只操作本源的 Cookie 域（与 `http` 共用）；`url` 可为相对地址，必须在白名单内（否则 `E_HOST_NOT_ALLOWED`）。
- `ui.openWebView`：`url` 必须在白名单内（否则 `E_HOST_NOT_ALLOWED`）；`doneWhenUrlMatches` 为正则字符串（最长 512 字符），
  主框架地址匹配时自动完成，否则由用户点「完成」。Promise 在用户完成且 Cookie 已写回本源后 resolve；
  用户取消 → `E_CHALLENGE`；平台不支持 WebView → `E_UNSUPPORTED`。WebView 中导航到白名单外的主机会被阻止，
  只同步白名单内主机的 Cookie（含 HttpOnly）。清单未设置 `User-Agent` 时，之后本源的请求使用 WebView 的 UA。
  **频率限制**：单次入口调用最多调用一次（第二次 → `E_LIMIT`）；应用不在前台、已有验证页打开、
  本源上次由脚本打开的验证页关闭后 30 s 内（用户取消后 2 min 内）都直接以 `E_CHALLENGE` 拒绝，不弹窗。
  WebView 的等待时间同样计入单次调用总时长（§4.4）；超时后验证页保持打开、Cookie 照常写回，但本次调用以 `E_LIMIT` 失败。
  需要较长时间的登录建议直接抛出 `E_LOGIN_REQUIRED`，由界面引导用户打开验证页后重试。
- `ui.toast` 与 `log.*` 为发出即忘，同步返回（返回值无意义）；参数中的非字符串值按 JSON 序列化，单条最长 4000 字符（超出截断）。
  `ui.toast` 每个源每 2 s 最多显示一条，应用不在前台时丢弃。

#### 4.2.1 `HtmlNode` 的跨边界表示

脚本运行在 worker isolate 中的 QuickJS 里，解析得到的 DOM 留在同一 worker 的宿主（Dart）侧，
脚本只持有**句柄**：

- 宿主侧维护“句柄（正整数）→ DOM 节点”表；`html.parse` 返回文档节点的句柄，`select` / `xpath`
  返回句柄数组，`text()` / `attr()` 等返回字符串。同一节点在一次调用内总是同一个句柄。
- 客户端在脚本之前执行的受信任 prelude 把句柄包装成 `HtmlNode` 对象（句柄存放在私有字段中）；
  原始的句柄函数不出现在 `tsumugi` 上，脚本也不能自行构造 `HtmlNode`。
- 这些方法都是**同步**的（与 `crypto` 一样在 worker 内执行，不经过主 isolate）。
- **句柄只在本次入口调用内有效**：调用结束后宿主释放全部 DOM，之后再使用旧的 `HtmlNode` 抛出异常。
  需要跨调用保存的数据请提取成字符串。
- 单次调用内最多 200 000 个句柄、累计解析 64 Mi 字符的文本，超出 → `E_LIMIT`（DOM 不在 JS 堆中，需单独限制）。
- `text()` 返回去除首尾空白的文本内容；`html()` 为内部 HTML，`outerHtml()` 含节点自身；
  文档节点的 `html()` / `outerHtml()` 均为整份文档。`absUrl(name)` 基于 `parse` 的 `baseUrl`（缺省为源的 `baseUrl`）解析属性值。
- `xpath()` 结果中的属性 / 文本 / 原子值被包装成文本节点，可用 `text()` 读取。
- `JSON.stringify(node)` 得到其 `outerHtml()`。

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
- 单次调用的 HTTP 请求数由宿主 `tsumugi.http.*` 计数（每次 `request` / `get` / `getJson` 计一次，
  自动重试与重定向不另计）；第 51 次请求以 `E_LIMIT` 拒绝（脚本可以 catch，但本次调用不能再发请求）。
  计数按入口调用重置。响应体大小由网络层强制（§5）。
- 一次入口调用结束（含超限）时，其进行中的网络请求被取消。

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
  UI 引导用户在 WebView 中手动完成后再重试（见 architecture §5.3）。`E_CHALLENGE` 与 `E_LOGIN_REQUIRED`
  的错误界面都提供「打开验证页」；完成后 Cookie 写回本源的 Cookie 域（图片请求共用），并自动重试。
- 单个响应体超过 20 MB → `E_LIMIT`。
- **响应文本解码**（声明式规则、`http.request` 的 `text` / `json`、`http.get` / `getJson`）按以下顺序确定字符集：
  1. 规则 `request.charset` / 脚本 `charset`（显式指定）；
  2. BOM（UTF-8 / UTF-16LE / UTF-16BE）；
  3. `Content-Type` 头的 `charset` 参数；
  4. HTML 文档（`Content-Type` 含 `html` / `xml` 或缺失时）前 4 KB 内第一个可识别的
     `<meta charset>` / `<meta http-equiv="Content-Type" content="…; charset=…">`，或 XML 声明的 `encoding`；
  5. UTF-8。

  字符集名称按 [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/#names-and-labels) 的标签规范化，
  不区分大小写：`gb2312` / `gbk` / `x-gbk` 等按 GB18030 解码，`iso-8859-1` / `latin1` / `ascii` 按 windows-1252，
  `big5-hkscs` 按 Big5，`sjis` / `windows-31j` 按 Shift_JIS，`ks_c_5601-1987` / `windows-949` 按 EUC-KR；
  另支持 UTF-16 与全部 WHATWG 单字节编码（iso-8859-*、windows-125*、koi8-* 等）。
  不支持 EUC-JP / ISO-2022-JP。不认识的名称跳过，继续下一步（最终按 UTF-8），并记录调试日志。
  非法字节一律替换为 U+FFFD，不会导致请求失败。`responseType: "bytes"` 与图片、音视频不经过解码。
  请求方向（URL 模板、表单、请求体）始终按 UTF-8 编码。
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

- [x] **declarative 的 `content` 是否支持多步请求？——已决定（2026-11）：apiVersion 1 不支持，改用 script。**
  - 同页内的间接取值已由 `|>` 覆盖；需要额外请求的站点几乎都同时需要签名、解密或 Cookie / Referer 链，
    用声明式语法表达会把规则变成一门小语言，而 `script` 引擎已提供这些能力与 §4.4 的限制。
  - 小说章节内分页由 `nextPageId` 覆盖。
  - 若将来确有需要，可在 apiVersion 2 增加
    `content.steps: [{ request, extract: { name: expr } }, ...]`（后续步骤以 `{{name}}` 引用），不影响现有源。
- [x] **小说的 `html=true` 允许哪些标签？——已决定（2026-11）：见 §2.2.1 的白名单。**
  - 正文由客户端转换为原生排版结构，不经过任何 HTML 渲染器，因此脚本、事件属性与样式无从执行；
    白名单只决定保留哪些排版语义（段落、标题、强调、注音、图片）。
  - 不支持 `style` / `class`：源之间的样式无法统一，且会与用户的字号、主题设置冲突。
  - 表格、列表等复杂结构只保留文字；如有需要，后续 apiVersion 可在不破坏现有源的前提下扩充白名单。
- [ ] 是否需要源签名（作者公钥）？——**推迟到 M6（规则仓库订阅）**。倾向不作强制要求：社区源作者多为匿名、
  更替频繁，签名体系难以建立；现有防线是沙箱、主机白名单与安装前展示访问主机。届时先评估“信任仓库”等更轻量的方案（[#33](https://github.com/Shiroha23/Tsumugi/issues/33)）。
- [ ] 是否兼容导入 Legado 书源格式（作为转换器，而非原生支持）？——**推迟到 M3 之后**，作为独立功能评估：
  依赖小说功能成熟，且转换覆盖率有限（[#34](https://github.com/Shiroha23/Tsumugi/issues/34)）。
