import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/model/source_settings.dart';

Map<String, dynamic> fixtureJson() => jsonDecode(
  File('test/fixtures/sources/settings_comic.json').readAsStringSync(),
) as Map<String, dynamic>;

SourceManifest manifestWith(Map<String, Object?> changes) =>
    SourceManifest.fromJson({...fixtureJson(), ...changes});

List<String> settingErrors(List<Map<String, Object?>> settings) =>
    manifestWith({'settings': settings}).validate();

void main() {
  group('settings 校验（source-spec §1.1）', () {
    test('fixture 通过校验；未知类型不算错误', () {
      final m = SourceManifest.fromJson(fixtureJson());
      expect(m.validate(), isEmpty);
      expect(unknownTypeSettings(m).single.key, 'future');
      expect(editableSettings(m).map((s) => s.key), [
        'quality',
        'hd',
        'mirror',
      ]);
    });

    test('key 非法或重复', () {
      expect(
        settingErrors([
          {'key': 'a-b', 'label': 'x', 'type': 'switch'},
        ]).single,
        contains('[A-Za-z0-9_]'),
      );
      expect(
        settingErrors([
          {'key': '', 'label': 'x', 'type': 'switch'},
        ]),
        hasLength(1),
      );
      expect(
        settingErrors([
          {'key': 'k' * 65, 'label': 'x', 'type': 'switch'},
        ]),
        hasLength(1),
      );
      expect(
        settingErrors([
          {'key': 'a', 'label': 'x', 'type': 'switch'},
          {'key': 'a', 'label': 'y', 'type': 'text'},
        ]).single,
        contains('重复'),
      );
    });

    test('label 不能为空', () {
      expect(
        settingErrors([
          {'key': 'a', 'label': '  ', 'type': 'switch'},
        ]).single,
        contains('label'),
      );
    });

    test('select：options 为空 / 含空串 / 重复，default 不在 options 中', () {
      expect(
        settingErrors([
          {'key': 'a', 'label': 'x', 'type': 'select'},
        ]).single,
        contains('options 不能为空'),
      );
      expect(
        settingErrors([
          {
            'key': 'a',
            'label': 'x',
            'type': 'select',
            'options': ['', 'b'],
          },
        ]),
        hasLength(1),
      );
      expect(
        settingErrors([
          {
            'key': 'a',
            'label': 'x',
            'type': 'select',
            'options': ['b', 'b'],
          },
        ]).single,
        contains('重复'),
      );
      expect(
        settingErrors([
          {
            'key': 'a',
            'label': 'x',
            'type': 'select',
            'options': ['b', 'c'],
            'default': 'd',
          },
        ]).single,
        contains('不在 options 中'),
      );
    });

    test('default 类型不符', () {
      expect(
        settingErrors([
          {'key': 'a', 'label': 'x', 'type': 'switch', 'default': 'true'},
        ]).single,
        contains('布尔'),
      );
      for (final bad in [1, 'a\nb', 'x' * (maxSettingTextLength + 1)]) {
        expect(
          settingErrors([
            {'key': 'a', 'label': 'x', 'type': 'text', 'default': bad},
          ]),
          hasLength(1),
          reason: '${'$bad'.length} chars',
        );
      }
    });

    test('options 不是字符串时清单解析失败', () {
      expect(
        () => manifestWith({
          'settings': [
            {
              'key': 'a',
              'label': 'x',
              'type': 'select',
              'options': [1, 2],
            },
          ],
        }),
        throwsA(anything),
      );
    });
  });

  group('取值', () {
    final m = SourceManifest.fromJson(fixtureJson());

    test('"default": null 等同于省略', () {
      final m = manifestWith({
        'settings': [
          {'key': 'b', 'label': 'x', 'type': 'switch', 'default': null},
          {'key': 't', 'label': 'x', 'type': 'text', 'default': null},
        ],
      });
      expect(m.validate(), isEmpty);
      expect(effectiveSettings(m, const {}), {'b': false, 't': ''});
    });

    test('缺省 default：select 取 options[0]，switch 取 false，text 取 ""', () {
      final m = manifestWith({
        'settings': [
          {
            'key': 's',
            'label': 'x',
            'type': 'select',
            'options': ['p', 'q'],
          },
          {'key': 'b', 'label': 'x', 'type': 'switch'},
          {'key': 't', 'label': 'x', 'type': 'text'},
        ],
      });
      expect(effectiveSettings(m, const {}), {'s': 'p', 'b': false, 't': ''});
    });

    test('保存的有效值覆盖默认值；无效值、未知键、未知类型的值被忽略', () {
      final values = effectiveSettings(m, {
        'quality': 'low',
        'hd': 'yes', // 类型不对
        'mirror': 'a\nb', // 含换行
        'future': 9, // 未知类型不接受用户值
        'gone': 1, // 清单中没有
      });
      expect(values, {'quality': 'low', 'hd': true, 'mirror': '', 'future': 3});
    });

    test('sanitizeSettingValues 只保留仍然有效的值', () {
      expect(
        sanitizeSettingValues(m, {
          'quality': 'ultra',
          'hd': false,
          'mirror': '/m',
          'gone': 'x',
        }),
        {'hd': false, 'mirror': '/m'},
      );
    });

    test('text 拒绝所有控制字符与 U+2028 / U+2029', () {
      final text = m.settings.firstWhere((s) => s.key == 'mirror');
      for (final c in [
        '\u0000',
        '\t',
        '\v',
        '\f',
        '\x7F',
        '\u0085',
        ' ',
        ' ',
      ]) {
        expect(
          text.accepts('a${c}b'),
          isFalse,
          reason: c.codeUnitAt(0).toRadixString(16),
        );
      }
      expect(text.accepts('普通文本 /m?x=1'), isTrue);
      // 上限按 UTF-16 码元计：512 个 emoji = 1024 码元可以，再多一个不行。
      expect(text.accepts('😀' * 512), isTrue);
      expect(text.accepts('😀' * 513), isFalse);
    });

    test('升级时与旧清单相比类型变化的值被丢弃，即使对新类型合法', () {
      final v1 = manifestWith({
        'settings': [
          {
            'key': 'mode',
            'label': 'x',
            'type': 'select',
            'options': ['a', 'b'],
          },
          {'key': 'keep', 'label': 'x', 'type': 'text'},
        ],
      });
      final v2 = manifestWith({
        'settings': [
          {'key': 'mode', 'label': 'x', 'type': 'text'},
          {'key': 'keep', 'label': 'x', 'type': 'text'},
        ],
      });
      final stored = {'mode': 'b', 'keep': 'k'};
      expect(sanitizeSettingValues(v2, stored), stored, reason: '不比较时都合法');
      expect(sanitizeSettingValues(v2, stored, previous: v1), {'keep': 'k'});
    });
  });

  group('loginUrl（source-spec §1）', () {
    test('缺省为 baseUrl', () {
      final m = manifestWith({'loginUrl': null});
      expect(m.validate(), isEmpty);
      expect(m.loginUri, Uri.parse('https://example.com'));
    });

    test('相对地址基于 baseUrl 解析', () {
      final m = SourceManifest.fromJson(fixtureJson());
      expect(m.loginUri, Uri.parse('https://example.com/account/login'));
    });

    test('白名单内的绝对地址（含通配）可用', () {
      for (final url in [
        'https://example.com/login',
        'http://example.com/login',
        'https://passport.example.com/login?next=%2F',
      ]) {
        expect(
          manifestWith({'loginUrl': url}).validate(),
          isEmpty,
          reason: url,
        );
      }
    });

    test('白名单外、非 http(s)、协议相对地址指向他处时校验失败', () {
      for (final url in [
        'https://example.net/login',
        'https://example.com.evil.example.net/',
        '//example.org/login',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'data:text/html,hi',
        'about:blank',
        '',
        '   ',
        'https://',
        // 审查补充：userinfo、编码、反斜杠、前导制表符、片段等形式都解析为白名单外主机。
        'https://example.com@evil.example.net/',
        'https://example.com%2F@evil.example.net/',
        '/\\evil.example.net',
        '\t//evil.example.net',
        'https://evil.example.net#@example.com',
      ]) {
        final errors = manifestWith({'loginUrl': url}).validate();
        expect(errors.single, contains('loginUrl'), reason: url);
      }
    });
  });
}
