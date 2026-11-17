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
      ]) {
        final errors = manifestWith({'loginUrl': url}).validate();
        expect(errors.single, contains('loginUrl'), reason: url);
      }
    });
  });
}
