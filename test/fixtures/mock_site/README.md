# mock_site

`tool/mock_server/` 提供的虚构站点页面。全部内容均为虚构，不对应任何真实站点。
路由表见 `tool/mock_server/mock_server.dart` 顶部注释；页面中的 `{{keyword}}` / `{{page}}`
由服务器替换（HTML 转义）。

`encoding/` 下是 GBK / Big5 编码的虚构页面（原样按字节发送，见 `.gitattributes` 中的 `-text`），
用于测试非 UTF-8 网页的解码（docs/source-spec.md §5）。改动时请用对应编码保存，
例如 Python：`open(path, 'wb').write(text.encode('gbk'))`。
