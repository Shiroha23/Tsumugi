// `flutter drive` 的驱动：在设备上以 profile / release 模式运行 integration_test/ 中的测试，
// 结果经 integration_test 插件回传（`flutter test` 只支持 debug 模式）。例：
//
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/video_playback_test.dart -d <设备> \
//     --dart-define=TSUMUGI_MOCK_SERVER=<电脑局域网 IP>:8081
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
