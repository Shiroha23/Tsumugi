# video

视频测试素材与虚构页面，由 `tool/mock_server/` 提供（路由见 `mock_server.dart` 顶部注释）。

## 素材

全部由本项目用 FFmpeg 的内置测试信号生成（`testsrc` 彩条 + 秒数计数器、`sine` 正弦音），
不含任何第三方作品，随仓库按项目许可证（GPL-3.0）发布。

| 文件 | 内容 |
|---|---|
| `clip.mp4` | 320×180、15 fps、6 s；H.264 Constrained Baseline + AAC-LC 单声道 440 Hz；`faststart` |
| `hls/master.m3u8` | 主播放列表，指向 `index.m3u8` |
| `hls/index.m3u8`、`hls/seg0-2.ts` | 同样的画面（660 Hz 音），3 个 2 s 的 MPEG-TS 分片，AES-128 加密 |
| `hls/mixed.m3u8` | 手写：没有密钥的加密分片（密文无法识别为媒体）、白名单外分片、重定向到白名单外的分片、返回 JSON 文本的“分片”（测试代理的拒绝路径） |
| `hls/key.bin` | AES-128 密钥：ASCII `tsumugi-test-key`（16 字节，虚构，仅供测试），IV = 1 |

生成命令（FFmpeg 8.1，Windows；H.264 编码器 `h264_mf` 为 Windows 自带的 Media Foundation，
其他平台可换成 `libx264`，产物不同但等价）：

```sh
ffmpeg -f lavfi -i "testsrc=size=320x180:rate=15:duration=6" \
  -f lavfi -i "sine=frequency=440:sample_rate=22050:duration=6" \
  -c:v h264_mf -b:v 120k -g 30 -pix_fmt nv12 -c:a aac -b:a 32k -ac 1 \
  -movflags +faststart clip.mp4

# hls/ 目录内执行；keyinfo.txt 三行：key.bin / key.bin / 00000000000000000000000000000001
printf 'tsumugi-test-key' > key.bin
ffmpeg -f lavfi -i "testsrc=size=320x180:rate=15:duration=6" \
  -f lavfi -i "sine=frequency=660:sample_rate=22050:duration=6" \
  -c:v h264_mf -b:v 120k -g 30 -pix_fmt nv12 -c:a aac -b:a 32k -ac 1 \
  -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
  -hls_key_info_file ../keyinfo.txt -hls_segment_filename 'seg%d.ts' \
  -master_pl_name master.m3u8 index.m3u8
```

所有文件按字节保存（`.gitattributes` 中的 `-text`）。

## 页面

`search.html`、`show_1.html`、`episode.html` 是配合 `test/fixtures/sources/mock_video_declarative.json`
的虚构页面。第 3、4 集走 `/video/protected/`：请求必须带路径以 `/video/` 开头的 `Referer`，
第 4 集的密钥还要求打开详情页时种下的 `vtoken` Cookie，用来验证播放器请求经过源的网络层。
