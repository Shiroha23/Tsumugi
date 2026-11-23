#!/usr/bin/env bash
# CI：在模拟器上逐个运行集成测试文件（.github/workflows/device-tests.yml）。
#
# 用法：tool/ci/run_device_tests.sh <设备 id> <测试文件…>
#   设备 id 以 emulator- 开头时按 Android 模拟器处理，否则按 iOS 模拟器（UDID）处理。
#
# 为什么逐个运行并设时限：偶尔 `flutter test` 装好应用后迟迟连不上设备上的测试进程，一个测试都没开始，
# 一直挂到任务的 60 分钟上限才被取消。这种挂起与测试内容无关，在 Android 和 iOS 上都出现过：
# 一次是 iOS 在 script_stack_depth_test 编译完成后挂住，另一次是 Android 在 app_flow_test 安装完成后挂住。
# 因此每个文件限时 FILE_TIMEOUT 秒（默认 900）。
#
# 重试：超时，或输出里出现「连不上测试程序 / 设备」这类基础设施错误（见 infra_failure）时，恢复设备后重试一次；
# 断言失败等真正的测试失败不重试，直接报失败。Android 模拟器上见过的基础设施错误：
#   - `Connecting to the VM Service timed out.`：flutter_tools 只等 5 秒连接经 adb forward 转发的 VM Service；
#   - `VmServiceDisappearedException`：连上后 VM Service 随即断开；
#   - `SocketException: Connection refused`（在 TestMock.start 里）：设备上 127.0.0.1:MOCK_PORT 没有监听，
#     即 adb reverse 规则已丢失，测试连不上电脑上的 mock 服务器。
# 这几种在同一次运行中接连出现，重跑整个任务即通过，说明是 adb 与模拟器之间的连接状态坏了，与测试内容无关。
# 所以 Android 上每个文件开始前都检查设备在线、清掉上一个文件残留的应用进程 / 端口转发 / logcat，
# 并重新建立 adb reverse；基础设施错误后再重启 adb 服务。失败时的诊断信息（adb 状态、logcat）
# 写入 DEVICE_LOG_DIR（默认 build/device_logs），由工作流作为 artifact 上传。
set -uo pipefail

device="$1"
shift
timeout_s="${FILE_TIMEOUT:-900}"
port="${MOCK_PORT:-8081}"
log_dir="${DEVICE_LOG_DIR:-build/device_logs}"
app_id="io.github.tsumugi.tsumugi"
mkdir -p "$log_dir"

is_android() { [[ "$device" == emulator-* ]]; }

adb_dev() { adb -s "$device" "$@"; }

# 等 Android 模拟器在线并启动完成，最多 120 秒。
wait_android_ready() {
  local i
  for i in $(seq 1 60); do
    if [[ "$(adb_dev get-state 2>/dev/null)" == "device" ]] &&
      [[ "$(adb_dev shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "::warning::$device 120 秒内没有就绪"
  adb devices -l
  return 1
}

# 每个文件开始前：清掉上一个文件留下的状态，重新建立到 mock 服务器的 adb reverse。
prepare_device() {
  if ! curl -fsS -o /dev/null "http://127.0.0.1:$port/"; then
    echo "::warning::电脑上的 mock 服务器（127.0.0.1:$port）没有响应"
  fi
  if ! is_android; then
    xcrun simctl bootstatus "$device" -b > /dev/null || true
    return 0
  fi
  wait_android_ready || return 0
  adb_dev shell am force-stop "$app_id" > /dev/null 2>&1 || true
  adb_dev forward --remove-all > /dev/null 2>&1 || true
  # 旧的 VM Service 地址留在 logcat 里可能被 flutter_tools 误读，先清空。
  adb_dev logcat -c > /dev/null 2>&1 || true
  adb_dev reverse tcp:"$port" tcp:"$port" > /dev/null
  if ! adb_dev reverse --list | grep -q "tcp:$port"; then
    echo "::warning::adb reverse tcp:$port 没有生效"
    adb_dev reverse --list
  fi
}

# 基础设施错误后的恢复：重启 adb 服务（端口转发与 reverse 随之清空，由 prepare_device 重建）。
recover_device() {
  if is_android; then
    echo "重启 adb 服务"
    adb kill-server || true
    adb start-server || true
    adb_dev wait-for-device || true
  else
    xcrun simctl bootstatus "$device" -b > /dev/null || true
  fi
}

# 把失败时的设备状态写进 DEVICE_LOG_DIR，供事后定位。
collect_diagnostics() {
  local name="$1"
  local out="$log_dir/$name"
  {
    echo "== date"; date -u
    echo "== mock server"; curl -sS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$port/" || true
    if is_android; then
      echo "== adb devices"; adb devices -l
      echo "== get-state"; adb_dev get-state || true
      echo "== reverse"; adb_dev reverse --list || true
      echo "== forward"; adb_dev forward --list || true
      echo "== app pid"; adb_dev shell pidof "$app_id" || true
    else
      echo "== booted simulators"; xcrun simctl list devices booted || true
    fi
  } > "$out.state.txt" 2>&1
  if is_android; then
    timeout 60 adb -s "$device" logcat -d -v time > "$out.logcat.txt" 2>&1 || true
  fi
}

# 运行一次，超过 timeout_s 秒就结束整个进程组。输出同时写入 $2。返回 flutter 的退出码；超时返回 124。
run_once() {
  local file="$1" log="$2"
  # 后台进程放进单独的进程组（子 shell 为组长），超时时连同 flutter 启动的子进程一起结束。
  set -m
  (
    flutter test "$file" -d "$device" \
      --dart-define=TSUMUGI_MOCK_SERVER=127.0.0.1:"$port" -r expanded 2>&1 | tee "$log"
    exit "${PIPESTATUS[0]}"
  ) &
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

# 输出里是否有「连不上测试程序 / 设备」的基础设施错误（而不是断言失败）。
infra_failure() {
  local log="$1"
  grep -qE 'Connecting to the VM Service timed out|VmServiceDisappearedException|The VM Service is not available on the test device|Unable to start the app on the device|Error: ADB exited|adb: device offline|device .* not found' "$log" && return 0
  # mock 服务器连接被拒，且发生在 TestMock.start（测试开始前）：adb reverse 丢失，见文件头。
  grep -q 'SocketException: Connection refused' "$log" && grep -q 'TestMock.start' "$log"
}

status=0
for file in "$@"; do
  name="$(basename "$file" .dart)"
  echo "::group::$file"
  prepare_device
  started=$SECONDS
  run_once "$file" "$log_dir/$name.1.log"
  code=$?
  reason=""
  if (( code == 124 )); then
    reason="超时"
  elif (( code != 0 )) && infra_failure "$log_dir/$name.1.log"; then
    reason="连不上设备上的测试程序（基础设施错误）"
  fi
  if [[ -n "$reason" ]]; then
    echo "::warning::$file ${reason}，恢复设备后重试一次"
    collect_diagnostics "$name.1"
    recover_device
    prepare_device
    run_once "$file" "$log_dir/$name.2.log"
    code=$?
  fi
  echo "$file 用时 $((SECONDS - started))s"
  echo "::endgroup::"
  if (( code != 0 )); then
    echo "::error::$file 失败（退出码 $code）"
    collect_diagnostics "$name.failed"
    status=1
  fi
done
exit "$status"
