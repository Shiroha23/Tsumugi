// 虚构脚本源：搜索需要登录（tool/mock_server 的 /members-only/…）。
// 未登录时用 tsumugi.ui.openWebView 打开 /login，用户手动登录后自动完成并重试一次；
// 用户取消或被频率限制时向界面报告 E_LOGIN_REQUIRED。

async function fetchSearch(keyword, page) {
  return tsumugi.http.request({
    url: `/members-only/comic/search?q=${encodeURIComponent(keyword)}&page=${page}`,
  });
}

export async function search(keyword, page) {
  let r = await fetchSearch(keyword, page);
  if (r.status === 401) {
    try {
      await tsumugi.ui.openWebView('/login', {
        title: '登录 Mock 站点',
        doneWhenUrlMatches: '/members$',
      });
    } catch (e) {
      throw { code: 'E_LOGIN_REQUIRED', message: '需要登录：' + (e.message || e.code) };
    }
    tsumugi.ui.toast('登录成功');
    r = await fetchSearch(keyword, page);
  }
  if (r.status !== 200) throw { code: 'E_HTTP', status: r.status, message: 'search failed' };
  const doc = tsumugi.html.parse(r.body);
  return {
    items: doc.select('.result-item').map((n) => ({
      id: n.selectFirst('a').attr('href'),
      title: n.selectFirst('.title').text(),
      cover: n.selectFirst('img')?.absUrl('data-src'),
    })),
    hasMore: doc.selectFirst('.pagination .next') != null,
  };
}

export async function detail(id) {
  const doc = tsumugi.html.parse(await tsumugi.http.get(id));
  const units = doc
    .xpath("//ul[@class='chapter-list']/li/a")
    .map((a) => ({ id: a.attr('href'), title: a.text() }))
    .reverse()
    .map((u, i) => ({ ...u, index: i }));
  return { id, title: doc.selectFirst('h1').text(), units };
}

export async function content(unitId) {
  const doc = tsumugi.html.parse(await tsumugi.http.get(unitId));
  return { images: doc.select('.page img').map((img) => ({ url: img.absUrl('data-src') })) };
}
