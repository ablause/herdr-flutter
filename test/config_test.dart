import 'package:herdr_flutter/src/config.dart';
import 'package:test/test.dart';

void main() {
  test('an empty file is all defaults', () {
    final config = PluginConfig.parse('');
    expect(config.togglePlacement, 'split');
    expect(config.toggleDirection, 'right');
    expect(config.autoOpen, isFalse);
    expect(config.logLimit, 5000);
    expect(config.serviceUri, '');
    expect(config.httpProfiling, isTrue);
  });

  test('recording the traffic can be turned off', () {
    expect(PluginConfig.parse('http_profiling = false').httpProfiling, isFalse);
    expect(
      () => PluginConfig.parse('http_profiling = "no"'),
      throwsA(isA<ConfigException>()),
    );
  });

  test('reads values, comments and blank lines', () {
    final config = PluginConfig.parse('''
# the sidebar
toggle_placement = "overlay"   # trailing comment
toggle_direction = "down"

auto_open = true
log_limit = 200
service_uri = "http://127.0.0.1:8181/abc=/"
''');
    expect(config.togglePlacement, 'overlay');
    expect(config.toggleDirection, 'down');
    expect(config.autoOpen, isTrue);
    expect(config.logLimit, 200);
    expect(config.serviceUri, 'http://127.0.0.1:8181/abc=/');
  });

  test('a hash inside a string is not a comment', () {
    final config = PluginConfig.parse('service_uri = "http://h/a#b=/"');
    expect(config.serviceUri, 'http://h/a#b=/');
  });

  test('an unknown key is an error, not a silent no-op', () {
    expect(
      () => PluginConfig.parse('toggle_plaement = "split"'),
      throwsA(isA<ConfigException>()),
    );
  });

  test('an invalid placement is rejected', () {
    expect(
      () => PluginConfig.parse('toggle_placement = "sideways"'),
      throwsA(isA<ConfigException>()),
    );
  });

  test('a mistyped value is rejected', () {
    expect(
      () => PluginConfig.parse('auto_open = yes'),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => PluginConfig.parse('log_limit = "many"'),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => PluginConfig.parse('log_limit = 10'),
      throwsA(isA<ConfigException>()),
    );
  });

  test('the shell view carries only what the scripts read', () {
    final json = const PluginConfig().toShellJson();
    expect(json.keys, ['toggle_placement', 'toggle_direction', 'auto_open']);
  });
}
