// 虚构脚本：逐项调用宿主 API，供 test/sources/script/ 下的测试使用。

export async function httpStatus(path) {
  try {
    await tsumugi.http.get(path);
    return 'ok';
  } catch (e) {
    return { code: e.code, status: e.status ?? null };
  }
}

export async function rawRequest(opts) {
  const r = await tsumugi.http.request(opts);
  return { status: r.status, url: r.url, body: r.body, type: r.headers['content-type'] ?? null };
}

export async function getJson(path) {
  return tsumugi.http.getJson(path);
}

export async function rethrow(path) {
  // 不捕获：宿主错误码与 status 原样透传到 Dart。
  await tsumugi.http.get(path);
}

export async function scriptThrows() {
  throw { code: 'E_LOGIN_REQUIRED', message: 'please log in' };
}

export async function scriptHttpError() {
  throw { code: 'E_HTTP', status: 418, message: 'teapot' };
}

export async function typeError() {
  return null.x;
}

export async function manyRequests(n) {
  let done = 0;
  for (let i = 0; i < n; i++) {
    try {
      await tsumugi.http.get('/echo?i=' + i);
      done++;
    } catch (e) {
      return { done, code: e.code };
    }
  }
  return { done, code: null };
}

export async function storageSet(key, value) {
  await tsumugi.storage.set(key, value);
}

export async function storageGet(key) {
  return tsumugi.storage.get(key);
}

export async function storageRemove(key) {
  await tsumugi.storage.remove(key);
}

export async function cookieSet(url, name, value) {
  await tsumugi.cookies.set(url, name, value);
}

export async function cookieGet(url) {
  return tsumugi.cookies.get(url);
}

export async function cookieGetCatch(url) {
  try {
    return await tsumugi.cookies.get(url);
  } catch (e) {
    return { code: e.code };
  }
}

export async function crypto() {
  const c = tsumugi.crypto;
  const key = '0123456789abcdef';
  const iv = 'fedcba9876543210';
  const cbc = c.aesEncrypt({ data: '纸鹤', key, iv, mode: 'CBC' });
  const ecb = c.aesEncrypt({ data: 'hello', key, mode: 'ECB', encoding: 'hex' });
  const gcm = c.aesEncrypt({ data: 'gcm text', key, iv: '000000000000', mode: 'GCM' });
  let badDecrypt = null;
  try {
    c.aesDecrypt({ data: 'AAAAAAAAAAAAAAAAAAAAAA==', key, iv, mode: 'CBC' });
  } catch (e) {
    badDecrypt = e.code;
  }
  return {
    md5: c.md5('abc'),
    sha1: c.sha1('abc'),
    sha256: c.sha256('abc'),
    hmac: c.hmacSha256('key', 'The quick brown fox jumps over the lazy dog'),
    b64: c.base64Encode('纸鹤'),
    unb64: c.base64Decode(c.base64Encode('纸鹤')),
    cbc,
    cbcBack: c.aesDecrypt({ data: cbc, key, iv, mode: 'CBC' }),
    ecb,
    ecbBack: c.aesDecrypt({ data: ecb, key, mode: 'ECB', encoding: 'hex' }),
    gcmBack: c.aesDecrypt({ data: gcm, key, iv: '000000000000', mode: 'GCM' }),
    badDecrypt,
  };
}

let stash = null;

export async function htmlApi() {
  const doc = tsumugi.html.parse(
    '<div id="a" class="x"><a href="/p/1">One</a><a href="q/2"> Two </a><p>t<b>b</b></p></div>',
    'http://comic.example.com/dir/page.html',
  );
  stash = doc;
  const links = doc.select('a');
  let forged = null;
  try {
    new links[0].constructor({}, 1);
  } catch (e) {
    forged = e.name;
  }
  return {
    count: links.length,
    texts: links.map((n) => n.text()),
    abs: links.map((n) => n.absUrl('href')),
    attr: links[0].attr('href'),
    missingAttr: links[0].attr('nope'),
    firstNone: doc.selectFirst('.none'),
    html: doc.selectFirst('p').html(),
    outer: doc.selectFirst('b').outerHtml(),
    xpathText: doc.xpath('//a/text()').map((n) => n.text()),
    xpathAttr: doc.xpath('//a/@href').map((n) => n.text()),
    nested: doc.selectFirst('#a').select('b').length,
    json: JSON.stringify({ node: doc.selectFirst('b') }),
    forged,
    hiddenRaw: typeof tsumugi.html.select,
    keys: Object.keys(tsumugi).sort(),
    frozen: Object.isFrozen(tsumugi) && Object.isFrozen(tsumugi.source),
    source: tsumugi.source,
  };
}

export async function staleNode() {
  try {
    return stash.text();
  } catch (e) {
    return 'stale: ' + e.message;
  }
}

export async function logAndToast() {
  const r = [tsumugi.log.info('hello', { a: 1 }), tsumugi.ui.toast('hi')];
  return r.map((v) => v == null);
}

export async function openWebView(url) {
  try {
    await tsumugi.ui.openWebView(url, { title: 'Login', doneWhenUrlMatches: '/members' });
    return 'done';
  } catch (e) {
    return e.code;
  }
}

let counter = 0;

export async function bump() {
  counter++;
  return counter;
}
