// 虚构脚本漫画源：页面来自 tool/mock_server（test/fixtures/mock_site/comic）。
// 测试中 "script" 字段会被替换为本文件内容。

export async function search(keyword, page) {
  const doc = tsumugi.html.parse(
    await tsumugi.http.get(
      `/comic/search?q=${encodeURIComponent(keyword)}&page=${page}`,
    ),
  );
  return {
    items: doc.select('.result-item').map((n) => ({
      id: n.selectFirst('a').attr('href'),
      title: n.selectFirst('.title').text(),
      cover: n.selectFirst('img')?.absUrl('data-src'),
      subtitle: n.selectFirst('.author')?.text(),
    })),
    hasMore: doc.selectFirst('.pagination .next') != null,
  };
}

export async function explore() {
  return [{ name: '全部', id: 'all' }];
}

export async function exploreList(categoryId, page) {
  return search('', page);
}

export async function detail(id) {
  const doc = tsumugi.html.parse(await tsumugi.http.get(id));
  const status = doc.selectFirst('.status')?.text();
  // 站点倒序列出章节。
  const units = doc
    .xpath("//ul[@class='chapter-list']/li/a")
    .map((a) => ({ id: a.attr('href'), title: a.text() }))
    .reverse()
    .map((u, i) => ({ ...u, index: i }));
  return {
    id,
    title: doc.selectFirst('h1').text(),
    cover: doc.selectFirst('.cover img').attr('src'),
    author: doc.selectFirst('.author').text(),
    description: doc.selectFirst('.intro').text(),
    tags: doc.select('.tags a').map((a) => a.text()),
    status: status === '连载中' ? 'ongoing' : 'unknown',
    units,
  };
}

export async function content(unitId) {
  const doc = tsumugi.html.parse(await tsumugi.http.get(unitId));
  const quality = tsumugi.source.settings.quality;
  return {
    images: doc.select('.page img').map((img) => ({
      url: img.absUrl('data-src'),
      headers: { 'X-Quality': quality },
    })),
  };
}
