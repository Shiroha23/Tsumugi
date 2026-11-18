// 界面层调用控制（#65）测试用的虚构脚本源：行为由关键词 / 分类 id 决定。
// - "verify"：先打开验证页（测试中的假 ScriptUi 控制用户操作多久）；
// - "slow:<ms>"：请求 mock 服务器的 /slow，延迟 ms 毫秒；
// - "verify,slow:<ms>"：两者依次进行。

async function run(key) {
  for (const step of key.split(',')) {
    if (step === 'verify') await tsumugi.ui.openWebView('/login');
    if (step.startsWith('slow:')) await tsumugi.http.get('/slow?ms=' + step.slice(5));
  }
  return { items: [{ id: '/item/' + key, title: key }], hasMore: false };
}

export async function search(keyword, page) {
  return run(keyword);
}

export async function explore() {
  return [{ name: '验证', id: 'verify' }, { name: '慢', id: 'slow:3000' }, { name: '快', id: 'fast' }];
}

export async function exploreList(categoryId, page) {
  return run(categoryId);
}
