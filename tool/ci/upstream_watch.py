#!/usr/bin/env python3
"""每周上游检查（.github/workflows/upstream-watch.yml）。

检查本项目卡在上游的依赖有没有新进展，有变化时在本仓库对应的 issue 下评论一次：

- media_kit 原生库包 / 上游原生库构建的新发布、better_player 的 Windows 渲染方式、
  Windows 自建 libmpv（tool/libmpv_windows/sources.tsv）的 mpv / FFmpeg 新版本 → #56
- media_kit / media_kit_video 新版本 → #49
- qjs 新版本（以及是否公开了更新栈顶的 API）→ #28
- flutter_inappwebview 新的正式版 → #27、#30

只读上游，只在本仓库评论。评论里不放上游链接，也不写 owner/repo#N 形式的引用
（会在上游留下反向链接）。同一变化只评论一次：评论中带 `<!-- upstream-watch:KEY -->` 标记，
已有该标记就跳过。

环境变量：GH_TOKEN（gh 使用）、GITHUB_REPOSITORY、DRY_RUN=1（只打印不评论）。
不在 GitHub Actions 中（`GITHUB_ACTIONS` 不是 true）或没有 `GITHUB_REPOSITORY` 时总是 dry run。
只用 Python 标准库与 gh CLI。
"""
from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.request
from dataclasses import dataclass, field

# 只有在 GitHub Actions 中、且明确给出仓库时才真正评论；其他情况（例如本机运行）一律 dry run，
# 避免用本机已登录的 gh 意外发出评论。
IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"
REPO = os.environ.get("GITHUB_REPOSITORY") or "Shiroha23/Tsumugi"  # dry run 时只用于读取评论
DRY_RUN = (
    os.environ.get("DRY_RUN") == "1"
    or not IN_ACTIONS
    or not os.environ.get("GITHUB_REPOSITORY")
)
LOCKFILE = "pubspec.lock"
LIBMPV_WINDOWS_SOURCES = "tool/libmpv_windows/sources.tsv"

# 已经看过、不需要再提醒的上游状态（2026-11-19 的基线）。
KNOWN_NATIVE_RELEASES = {
    # 上游仓库 → 已知的最新发布（FFmpeg 均为 6.0）
    "media-kit/libmpv-android-video-build": ("Android 原生库构建", "v1.1.11"),
    "media-kit/libmpv-darwin-build": ("iOS / macOS 原生库构建", "v0.7.3"),
}
KNOWN_INAPPWEBVIEW_STABLE = "6.1.5"
BETTER_PLAYER_TEXTURE_BRIDGE = (
    "repos/jhomlala/betterplayer/contents/"
    "packages/better_player_windows/windows/texture_bridge.cpp"
)


@dataclass
class Finding:
    key: str  # 去重标记
    issues: list[int]
    text: str  # 一条 Markdown 列表项（不含上游链接）


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)
    checked: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def _retry(fn, attempts: int = 3):
    """网络操作最多试 3 次（间隔 2 s、4 s），仍失败时抛出最后一次的异常。"""
    for i in range(attempts):
        try:
            return fn()
        except Exception:  # noqa: BLE001
            if i == attempts - 1:
                raise
            time.sleep(2 * (i + 1))


def http_bytes(url: str, timeout: int = 60) -> bytes:
    def once() -> bytes:
        req = urllib.request.Request(url, headers={"User-Agent": "tsumugi-upstream-watch"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()

    return _retry(once)


def http_json(url: str) -> dict:
    return json.loads(http_bytes(url, timeout=30))


def gh(*args: str) -> str:
    return _retry(lambda: subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True
    ).stdout)


def locked_versions(path: str = LOCKFILE) -> dict[str, str]:
    """pubspec.lock 中各包的版本。"""
    out: dict[str, str] = {}
    current = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^  ([a-z0-9_]+):\s*$", line)
            if m:
                current = m.group(1)
                continue
            m = re.match(r'^    version: "([^"]+)"', line)
            if m and current:
                out[current] = m.group(1)
    return out


def pub_info(package: str) -> tuple[str, str, str, str]:
    """(正式版, 正式版发布日期, 最新版本（含预发布）, 其发布日期)。"""
    d = http_json(f"https://pub.dev/api/packages/{package}")
    newest = d["versions"][-1]
    return (
        d["latest"]["version"],
        d["latest"]["published"][:10],
        newest["version"],
        newest["published"][:10],
    )


def check_pub(report: Report, locked: dict[str, str]) -> None:
    groups = [
        (["media_kit_libs_windows_video", "media_kit_libs_android_video",
          "media_kit_libs_ios_video"], [56],
         "需要确认新版本内置的 libmpv / FFmpeg 版本（是否新于 FFmpeg 6.0），再决定是否升级"),
        (["media_kit", "media_kit_video"], [49],
         "需要在 Android 真机上回归 HLS 起播（含加密、需要 Referer / Cookie 的流），确认后才能去掉“重新打开”的变通做法"),
    ]
    for packages, issues, advice in groups:
        for p in packages:
            try:
                _, _, newest, date = pub_info(p)
            except Exception as e:  # noqa: BLE001
                report.errors.append(f"pub.dev `{p}`：{e}")
                continue
            report.checked.append(f"`{p}` {newest}（项目使用 {locked.get(p, '?')}）")
            if newest != locked.get(p):
                report.findings.append(Finding(
                    f"pub:{p}@{newest}", issues,
                    f"`{p}`：{locked.get(p, '?')} → **{newest}**（{date} 发布）。{advice}。",
                ))


def check_qjs(report: Report, locked: dict[str, str]) -> None:
    try:
        d = http_json("https://pub.dev/api/packages/qjs")
        newest = d["versions"][-1]
        version = newest["version"]
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"pub.dev `qjs`：{e}")
        return
    report.checked.append(f"`qjs` {version}（项目使用 {locked.get('qjs', '?')}）")
    if version == locked.get("qjs"):
        return
    public_api = "未能检查"
    try:
        data = http_bytes(newest["archive_url"])
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
            found = False
            for m in t.getmembers():
                if m.isfile() and m.name.endswith(".dart") and m.name.startswith("lib/"):
                    text = t.extractfile(m).read().decode("utf-8", "replace")
                    if re.search(r"(?i)updateStackTop", text):
                        found = True
                        break
            public_api = "**出现了** `updateStackTop` 相关代码，需人工确认是否为公开 API" if found \
                else "没有发现更新栈顶的 API"
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"`qjs` {version} 源码包：{e}")
    report.findings.append(Finding(
        f"pub:qjs@{version}", [28],
        f"`qjs`：{locked.get('qjs', '?')} → **{version}**（{newest['published'][:10]} 发布）。{public_api}。"
        "升级前须复查 `QJSABIRuntime` 的结构布局并运行 `test/core/engine/script/native_stack_test.dart`。",
    ))


def check_inappwebview(report: Report) -> None:
    try:
        stable, date, _, _ = pub_info("flutter_inappwebview")
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"pub.dev `flutter_inappwebview`：{e}")
        return
    report.checked.append(f"`flutter_inappwebview` 正式版 {stable}")
    if stable != KNOWN_INAPPWEBVIEW_STABLE:
        report.findings.append(Finding(
            f"pub:flutter_inappwebview-stable@{stable}", [27, 30],
            f"`flutter_inappwebview` 出现新的正式版 **{stable}**（{date} 发布，此前为 "
            f"{KNOWN_INAPPWEBVIEW_STABLE}）。可以评估从 6.2.0-beta.3 换回正式版、移除 Windows 上的协程宏，"
            "并顺带确认 Windows 关闭验证页时的 ERROR_NOT_READY 报错是否消失。",
        ))


def check_native_releases(report: Report) -> None:
    for repo, (label, known) in KNOWN_NATIVE_RELEASES.items():
        try:
            rel = json.loads(gh("api", f"repos/{repo}/releases/latest"))
        except Exception as e:  # noqa: BLE001
            report.errors.append(f"{label}的最新发布：{e}")
            continue
        tag, date = rel["tag_name"], rel["published_at"][:10]
        report.checked.append(f"media_kit {label} {tag}")
        if tag != known:
            report.findings.append(Finding(
                f"release:{repo}@{tag}", [56],
                f"media_kit 的{label}出了新发布 **{tag}**（{date}，此前为 {known}）。"
                "需要人工阅读它的发布说明 / 构建脚本，确认 FFmpeg 是否新于 6.0；"
                "pub.dev 上的原生库包更新后才能直接使用。",
            ))


def libmpv_windows_versions(path: str = LIBMPV_WINDOWS_SOURCES) -> dict[str, str]:
    """Windows 自建 libmpv 的组件 → 版本（sources.tsv 的前两列）。"""
    versions = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                cols = line.rstrip("\n").split("\t")
                versions[cols[0]] = cols[1]
    return versions


def _version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v))


def check_libmpv_windows(report: Report) -> None:
    """自建的 Windows libmpv：mpv 新发布、FFmpeg 同一发布线的新补丁版本（安全修复）或新发布线。"""
    try:
        current = libmpv_windows_versions()
        mpv, ffmpeg = current["mpv"], current["ffmpeg"]
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"读取 {LIBMPV_WINDOWS_SOURCES}：{e}")
        return
    try:
        tag = json.loads(gh("api", "repos/mpv-player/mpv/releases/latest"))["tag_name"]
        report.checked.append(f"mpv 最新发布 {tag}（Windows 自建 {mpv}）")
        if _version_tuple(tag) > _version_tuple(mpv):
            report.findings.append(Finding(
                f"libmpv-windows:mpv@{tag}", [56],
                f"mpv 出了新发布 **{tag}**（Windows 自建为 {mpv}）。阅读发布说明（选项改名 / 删除、"
                "依赖版本要求）后，按 architecture §6.4.6 第 2 项更新 tool/libmpv_windows/。",
            ))
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"mpv 最新发布：{e}")
    try:
        tags = gh("api", "--paginate", "repos/FFmpeg/FFmpeg/tags", "--jq", ".[].name").split()
        releases = sorted(
            (_version_tuple(t), t) for t in tags if re.fullmatch(r"n\d+(\.\d+)+", t)
        )
        cur = _version_tuple(ffmpeg)
        same_line = [t for v, t in releases if v[:2] == cur[:2] and v > cur]
        newer_lines = [t for v, t in releases if v[:2] > cur[:2]]
        report.checked.append(f"FFmpeg 发布标签（Windows 自建 {ffmpeg}）")
        if same_line:
            report.findings.append(Finding(
                f"libmpv-windows:ffmpeg@{same_line[-1]}", [56],
                f"FFmpeg 同一发布线出了补丁版本 **{same_line[-1]}**（Windows 自建为 {ffmpeg}），"
                "通常含安全修复，应尽快更新 tool/libmpv_windows/sources.tsv 并重新发布。",
            ))
        if newer_lines:
            report.findings.append(Finding(
                f"libmpv-windows:ffmpeg-line@{newer_lines[-1]}", [56],
                f"FFmpeg 已有更新的发布线（最新 **{newer_lines[-1]}**，Windows 自建为 {ffmpeg}）。"
                "当前发布线停止维护前需要评估升级。",
            ))
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"FFmpeg 发布标签：{e}")


def check_better_player(report: Report) -> None:
    try:
        import base64
        content = json.loads(gh("api", BETTER_PLAYER_TEXTURE_BRIDGE))["content"]
        src = base64.b64decode(content).decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        report.errors.append(f"better_player Windows 渲染代码：{e}")
        return
    sw = "MPV_RENDER_API_TYPE_SW" in src
    gpu = any(k in src for k in ("MPV_RENDER_API_TYPE_D3D11", "GpuSurfaceTexture"))
    report.checked.append(
        "better_player Windows 渲染：" + ("软件渲染" if sw and not gpu else "有变化")
    )
    if gpu or not sw:
        report.findings.append(Finding(
            "better_player_windows:render-changed", [56],
            "better_player 的 Windows 渲染代码有变化（"
            + ("出现 D3D11 / GPU 纹理" if gpu else "不再是软件渲染接口")
            + "）。可以重跑 1080p60 对比（raster 耗时、CPU），再评估是否三端迁移。",
        ))


def existing_markers(issue: int) -> str:
    return gh("api", "--paginate", f"repos/{REPO}/issues/{issue}/comments",
              "--jq", ".[].body")


def post(report: Report) -> list[str]:
    by_issue: dict[int, list[Finding]] = {}
    for f in report.findings:
        for i in f.issues:
            by_issue.setdefault(i, []).append(f)
    posted = []
    for issue, items in sorted(by_issue.items()):
        try:
            seen = existing_markers(issue)
        except Exception as e:  # noqa: BLE001
            report.errors.append(f"读取 #{issue} 的评论：{e}")
            continue
        new = [f for f in items if f"<!-- upstream-watch:{f.key} -->" not in seen]
        if not new:
            continue
        body = "\n".join(
            ["### 上游周检", ""]
            + [f"- {f.text}" for f in new]
            + ["", "以上只是上游版本变化，是否解决问题需要验证。", ""]
            + [f"<!-- upstream-watch:{f.key} -->" for f in new]
            + ["", "_🤖 由每周上游检查（GitHub Actions）自动记录_"]
        )
        if DRY_RUN:
            print(f"--- 将评论 #{issue} ---\n{body}\n")
        else:
            # 发评论不重试：失败时可能其实已经发出，重试会重复评论。
            subprocess.run(["gh", "issue", "comment", str(issue), "--repo", REPO,
                            "--body", body], check=True)
        posted.append(f"#{issue}：{len(new)} 项")
    return posted


def main() -> int:
    report = Report()
    locked = locked_versions()
    check_pub(report, locked)
    check_qjs(report, locked)
    check_inappwebview(report)
    check_native_releases(report)
    check_libmpv_windows(report)
    check_better_player(report)
    posted = post(report)

    lines = ["## 上游周检", "", "### 检查项", *[f"- {c}" for c in report.checked]]
    lines += ["", "### 评论", *([f"- {p}" for p in posted] or ["- 无新变化"])]
    if report.errors:
        lines += ["", "### 未能完成的检查", *[f"- {e}" for e in report.errors]]
    summary = "\n".join(lines)
    print(summary)
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a", encoding="utf-8") as f:
            f.write(summary + "\n")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
