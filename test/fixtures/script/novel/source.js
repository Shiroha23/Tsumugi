// 虚构脚本小说源：页面来自 tool/mock_server（test/fixtures/mock_site/novel），
// 正文以受限 HTML 返回，每章末尾带一张虚构图片主机上的插图（下载与离线阅读的集成测试用）。
// 测试中 "script" 字段会被替换为本文件内容。

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export async function search(keyword, page) {
  const doc = tsumugi.html.parse(
    await tsumugi.http.get(`/novel/search?q=${encodeURIComponent(keyword)}`),
  );
  return {
    items: doc.select('.book').map((n) => ({
      id: n.selectFirst('h3 a').attr('href'),
      title: n.selectFirst('h3 a').text(),
      subtitle: n.selectFirst('.writer')?.text(),
    })),
    hasMore: false,
  };
}

export async function detail(id) {
  const doc = tsumugi.html.parse(await tsumugi.http.get(id));
  return {
    id,
    title: doc.selectFirst('h1').text(),
    author: doc.selectFirst('.writer')?.text(),
    description: doc.selectFirst('#intro')?.text(),
    units: doc
      .select('.catalog dd a')
      .map((a) => ({ id: a.attr('href'), title: a.text() })),
  };
}

export async function content(unitId) {
  const doc = tsumugi.html.parse(await tsumugi.http.get(unitId));
  const body = doc
    .select('#content p')
    .map((p) => `<p>${escapeHtml(p.text())}</p>`)
    .join('');
  const chapter = unitId.split('?')[0].split('/').pop();
  const page = unitId.includes('?p=') ? 2 : 1;
  return {
    html: true,
    text: `${body}<p><img src="http://img.example.com/static/novel/${chapter}-${page}.png" alt="插图 ${chapter}-${page}"></p>`,
    nextPageId: doc.selectFirst('a.next')?.attr('href'),
  };
}
