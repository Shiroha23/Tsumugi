#!/usr/bin/env bash
# CI：在后台启动带测试控制接口的 mock 服务器（.github/workflows/device-tests.yml），等到可以访问。
# 端口取 MOCK_PORT（默认 8081），日志写入 mock_server.log。进程在任务结束时由 runner 回收。
set -euo pipefail
port="${MOCK_PORT:-8081}"
# 先编译，避免首次 `dart run` 的构建时间被计入等待。
mkdir -p build
dart compile exe tool/mock_server/main.dart -o build/mock_server
nohup build/mock_server --port "$port" --test-control > mock_server.log 2>&1 &
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/"; then
    echo "mock server ready on 127.0.0.1:$port"
    exit 0
  fi
  sleep 1
done
echo "mock server did not start" >&2
cat mock_server.log >&2
exit 1
