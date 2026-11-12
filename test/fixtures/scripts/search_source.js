// 虚构源脚本：只调用宿主 API，数据来自测试注入的假 http.get（example.com）。
export async function search(keyword, page) {
  const body = await tsumugi.http.get(
    `/search?q=${encodeURIComponent(keyword)}&page=${page}`,
  );
  const data = JSON.parse(body);
  return {
    items: data.results.map((r) => ({ id: r.id, title: r.title.trim() })),
    hasMore: data.next != null,
  };
}

export async function detail(id) {
  // 连续多次宿主异步调用。
  const info = JSON.parse(await tsumugi.http.get(`/book/${id}`));
  const chapters = JSON.parse(await tsumugi.http.get(`/book/${id}/chapters`));
  return { id, title: info.title, chapters: chapters.length };
}

export async function content(unitId) {
  try {
    await tsumugi.http.get(`/chapter/${unitId}`);
  } catch (e) {
    // 宿主抛出的错误码在脚本侧可见，可原样上报。
    throw { code: e.code, message: `wrapped: ${e.message}` };
  }
}

export function hash(s) {
  // 同步宿主函数。
  return tsumugi.crypto.md5(s);
}
