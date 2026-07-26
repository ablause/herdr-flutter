import 'dart:convert';
import 'dart:io';

/// Raised for any unusable plugin config. Every entry point refuses on it, so
/// the actions and the sidebar share one contract.
class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The plugin config, read from `$HERDR_PLUGIN_CONFIG_DIR/config.toml`.
class PluginConfig {
  const PluginConfig({
    this.togglePlacement = 'split',
    this.toggleDirection = 'right',
    this.autoOpen = false,
    this.serviceUri = '',
    this.logLimit = 5000,
    this.followLogs = true,
    this.paneLines = 3000,
    this.mouse = true,
    this.runCommand = '',
    this.runPlacement = 'split',
    this.runDirection = 'down',
  });

  final String togglePlacement;
  final String toggleDirection;
  final bool autoOpen;

  /// A VM Service URI to attach to instead of scanning panes.
  final String serviceUri;

  final int logLimit;
  final bool followLogs;

  /// How many scrollback lines to read per pane while discovering an app.
  final int paneLines;

  /// Whether the sidebar asks the terminal for click and wheel reports.
  ///
  /// It is what makes the tabs clickable, and it is also what takes click-drag
  /// text selection away from the pane, so it can be turned off.
  final bool mouse;

  /// The command that starts the app, when the scrollback cannot tell.
  final String runCommand;

  /// Where a launch opens a pane, when there is no previous run pane to reuse.
  final String runPlacement;
  final String runDirection;

  static const _placements = {'split', 'overlay', 'zoomed', 'tab'};
  static const _runPlacements = {'split', 'tab'};
  static const _directions = {'right', 'down'};

  static const _keys = {
    'toggle_placement',
    'toggle_direction',
    'auto_open',
    'service_uri',
    'log_limit',
    'follow_logs',
    'pane_lines',
    'mouse',
    'run_command',
    'run_placement',
    'run_direction',
  };

  /// Only the keys the sidebar scripts consume, so bash never parses TOML.
  Map<String, Object?> toShellJson() => {
    'toggle_placement': togglePlacement,
    'toggle_direction': toggleDirection,
    'auto_open': autoOpen,
  };

  static PluginConfig load({Map<String, String>? env}) {
    final dir = (env ?? Platform.environment)['HERDR_PLUGIN_CONFIG_DIR'];
    if (dir == null || dir.isEmpty) return const PluginConfig();
    final file = File('$dir/config.toml');
    if (!file.existsSync()) return const PluginConfig();
    return parse(file.readAsStringSync(), source: file.path);
  }

  /// A deliberately small subset of TOML: flat `key = value` pairs with string,
  /// integer and boolean values. Anything else is a config error rather than a
  /// silently ignored line.
  static PluginConfig parse(String text, {String source = 'config.toml'}) {
    final values = <String, Object>{};
    var lineNumber = 0;
    for (final rawLine in const LineSplitter().convert(text)) {
      lineNumber++;
      final line = _stripComment(rawLine).trim();
      if (line.isEmpty) continue;
      final split = line.indexOf('=');
      if (split <= 0) {
        throw ConfigException('$source:$lineNumber: expected `key = value`');
      }
      final key = line.substring(0, split).trim();
      final rawValue = line.substring(split + 1).trim();
      if (!_keys.contains(key)) {
        throw ConfigException('$source:$lineNumber: unknown key `$key`');
      }
      values[key] = _value(rawValue, source, lineNumber);
    }

    final placement = _string(values, 'toggle_placement', 'split', source);
    if (!_placements.contains(placement)) {
      throw ConfigException(
        '$source: toggle_placement must be one of ${_placements.join(', ')}',
      );
    }
    final direction = _string(values, 'toggle_direction', 'right', source);
    if (!_directions.contains(direction)) {
      throw ConfigException(
        '$source: toggle_direction must be one of ${_directions.join(', ')}',
      );
    }
    final runPlacement = _string(values, 'run_placement', 'split', source);
    if (!_runPlacements.contains(runPlacement)) {
      throw ConfigException(
        '$source: run_placement must be one of ${_runPlacements.join(', ')}',
      );
    }
    final runDirection = _string(values, 'run_direction', 'down', source);
    if (!_directions.contains(runDirection)) {
      throw ConfigException(
        '$source: run_direction must be one of ${_directions.join(', ')}',
      );
    }
    final logLimit = _int(values, 'log_limit', 5000, source);
    if (logLimit < 100) {
      throw ConfigException('$source: log_limit must be at least 100');
    }
    final paneLines = _int(values, 'pane_lines', 3000, source);
    if (paneLines < 100) {
      throw ConfigException('$source: pane_lines must be at least 100');
    }

    return PluginConfig(
      togglePlacement: placement,
      toggleDirection: direction,
      autoOpen: _bool(values, 'auto_open', false, source),
      serviceUri: _string(values, 'service_uri', '', source),
      logLimit: logLimit,
      followLogs: _bool(values, 'follow_logs', true, source),
      paneLines: paneLines,
      mouse: _bool(values, 'mouse', true, source),
      runCommand: _string(values, 'run_command', '', source),
      runPlacement: runPlacement,
      runDirection: runDirection,
    );
  }

  static String _stripComment(String line) {
    var inString = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') inString = !inString;
      if (char == '#' && !inString) return line.substring(0, i);
    }
    return line;
  }

  static Object _value(String raw, String source, int line) {
    if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
      return raw.substring(1, raw.length - 1);
    }
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    throw ConfigException(
      '$source:$line: value must be a quoted string, an integer or a boolean',
    );
  }

  static String _string(
    Map<String, Object> values,
    String key,
    String fallback,
    String source,
  ) {
    final value = values[key];
    if (value == null) return fallback;
    if (value is! String)
      throw ConfigException('$source: $key must be a string');
    return value;
  }

  static bool _bool(
    Map<String, Object> values,
    String key,
    bool fallback,
    String source,
  ) {
    final value = values[key];
    if (value == null) return fallback;
    if (value is! bool)
      throw ConfigException('$source: $key must be a boolean');
    return value;
  }

  static int _int(
    Map<String, Object> values,
    String key,
    int fallback,
    String source,
  ) {
    final value = values[key];
    if (value == null) return fallback;
    if (value is! int)
      throw ConfigException('$source: $key must be an integer');
    return value;
  }
}
