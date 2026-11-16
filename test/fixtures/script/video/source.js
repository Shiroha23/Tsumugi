// 虚构脚本视频源：JSON 接口来自 tool/mock_server（/video/api/*）。
// 两条线路（Detail.groups）、每集两个清晰度（StreamRef.quality）与外挂字幕（subtitles）。
// test/fixtures/sources/mock_video_script.json 内联了本文件，测试会检查两者一致。

export async function search(keyword, page) {
  if (page > 1) return { items: [], hasMore: false };
  const r = await tsumugi.http.getJson(
    `/video/api/search?q=${encodeURIComponent(keyword)}`,
  );
  return {
    items: r.list.map((x) => ({ id: x.id, title: x.title, subtitle: x.note })),
    hasMore: false,
  };
}

export async function detail(id) {
  const r = await tsumugi.http.getJson(id);
  const groups = r.lines.map((line) => ({
    name: line.name,
    units: line.episodes.map((e, i) => ({ id: e.id, title: e.title, index: i })),
  }));
  return {
    id,
    title: r.title,
    description: r.intro,
    units: groups[0].units,
    groups,
  };
}

export async function content(unitId) {
  const r = await tsumugi.http.getJson(unitId);
  return {
    streams: r.streams.map((s) => ({
      url: s.url,
      type: s.type,
      quality: s.quality,
    })),
    subtitles: (r.subtitles || []).map((s) => ({
      url: s.url,
      lang: s.lang,
      format: s.format,
    })),
  };
}
