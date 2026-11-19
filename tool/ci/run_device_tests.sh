#!/usr/bin/env bash
# CI：在模拟器上逐个运行集成测试文件（.github/workflows/device-tests.yml）。
#
# 用法：tool/ci/run_device_tests.sh <设备 id> <测试文件…>
#
# 为什么逐个运行并设时限：偶尔 `flutter test` 装好应用后迟迟连不上设备上的测试进程，一个测试都没开始，
# 一直挂到任务的 60 分钟上限才被取消。这种挂起与测试内容无关，在 Android 和 iOS 上都出现过：
# 一次是 iOS 在 script_stack_depth_test 编译完成后挂住，另一次是 Android 在 app_flow_test 安装完成后挂住。
# 因此每个文件限时 FILE_TIMEOUT 秒（默认 900）；只有超时才重试一次，测试失败不重试，直接报失败。
set -uo pipefail

device="$1"
shift
timeout_s="${FILE_TIMEOUT:-900}"
port="${MOCK_PORT:-8081}"

# 运行一次，超过 timeout_s 秒就结束整个进程组。返回 flutter 的退出码；超时返回 124。
run_once() {
  local file="$1"
  # 后台进程放进单独的进程组，超时时连同 flutter 启动的子进程一起结束。
  set -m
  flutter test "$file" -d "$device" \
    --dart-define=TSUMUGI_MOCK_SERVER=127.0.0.1:"$port" -r expanded &
  local pid=$!
  set +m
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout_s )); then
      echo "::warning::$file 超过 ${timeout_s}s 没有结束，结束进程"
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 10
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$pid"
}

status=0
for file in "$@"; do
  echo "::group::$file"
  run_once "$file"
  code=$?
  if (( code == 124 )); then
    echo "::warning::$file 超时，重试一次"
    run_once "$file"
    code=$?
  fi
  echo "::endgroup::"
  if (( code != 0 )); then
    echo "::error::$file 失败（退出码 $code）"
    status=1
  fi
done
exit "$status"
