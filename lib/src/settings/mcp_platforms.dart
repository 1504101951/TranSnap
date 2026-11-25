import 'dart:convert';
import 'dart:io';

import '../common/constants/mcp_constants.dart';

enum McpPlatformKind { command, configFile }

enum McpInstallState {
  missing,
  checking,
  notInstalled,
  installed,
  pathChanged;

  String label(McpPlatform platform) => switch (this) {
    missing => '未检测到 ${platform.clientName}',
    checking => '检测中',
    notInstalled => '未安装',
    installed => '已安装',
    pathChanged => '路径已变化',
  };
}

sealed class McpPlatform {
  const McpPlatform({required this.id, required this.name});

  final String id;

  final String name;

  String get clientName;

  McpPlatformKind get kind;
}

class CommandMcpPlatform extends McpPlatform {
  const CommandMcpPlatform({
    required super.id,
    required super.name,
    required this.executable,
    required this.detectArgs,
    required this.addArgs,
    required this.removeArgs,
  });

  static const helperToken = '{helper}';

  final String executable;
  final List<String> detectArgs;
  final List<String> addArgs;
  final List<String> removeArgs;

  @override
  String get clientName => '$executable CLI';

  @override
  McpPlatformKind get kind => McpPlatformKind.command;
}

class ConfigFileMcpPlatform extends McpPlatform {
  const ConfigFileMcpPlatform({
    required super.id,
    required super.name,
    required this.clientName,
    required this.clientDirectory,
    required this.configFile,
    required this.restartHint,
  });

  @override
  final String clientName;

  final String clientDirectory;

  final String configFile;

  final String restartHint;

  @override
  McpPlatformKind get kind => McpPlatformKind.configFile;
}

const mcpPlatforms = <McpPlatform>[
  CommandMcpPlatform(
    id: 'claude-code',
    name: 'Claude Code',
    executable: 'claude',
    detectArgs: ['mcp', 'get', McpConstants.serverName],
    addArgs: [
      'mcp',
      'add',
      '-s',
      'user',
      McpConstants.serverName,
      '--',
      CommandMcpPlatform.helperToken,
    ],
    removeArgs: ['mcp', 'remove', '-s', 'user', McpConstants.serverName],
  ),
  ConfigFileMcpPlatform(
    id: 'claude-desktop',
    name: 'Claude 桌面',
    clientName: 'Claude 桌面',
    clientDirectory: 'Library/Application Support/Claude',
    configFile: 'claude_desktop_config.json',
    restartHint: '重启 Claude 后生效',
  ),
  CommandMcpPlatform(
    id: 'codex',
    name: 'Codex（CLI 与桌面 App 共用）',
    executable: 'codex',
    detectArgs: ['mcp', 'get', McpConstants.serverName, '--json'],
    addArgs: [
      'mcp',
      'add',
      McpConstants.serverName,
      '--',
      CommandMcpPlatform.helperToken,
    ],
    removeArgs: ['mcp', 'remove', McpConstants.serverName],
  ),
  CommandMcpPlatform(
    id: 'grok',
    name: 'Grok',
    executable: 'grok',
    detectArgs: ['mcp', 'list', '--json'],
    addArgs: [
      'mcp',
      'add',
      '-s',
      'user',
      McpConstants.serverName,
      CommandMcpPlatform.helperToken,
    ],
    removeArgs: ['mcp', 'remove', '-s', 'user', McpConstants.serverName],
  ),
];

class McpPlatformException implements Exception {
  const McpPlatformException(this.message);

  final String message;

  @override
  String toString() => message;
}

class McpPlatformService {
  McpPlatformService({
    required this.helperPath,
    String? home,
    Future<String> Function()? searchPath,
  }) : home = home ?? Platform.environment['HOME']!,
       _searchPath = searchPath ?? loginShellPath;

  final String helperPath;
  final String home;
  final Future<String> Function() _searchPath;
  Future<String>? _path;

  static Future<String> loginShellPath() async {
    const marker = '__TRANSNAP_PATH__';
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    final result = await Process.run(shell, [
      '-ilc',
      'printf "$marker%s" "\$PATH"',
    ]);
    final output = result.stdout as String;
    return output.substring(output.lastIndexOf(marker) + marker.length).trim();
  }

  Future<McpInstallState> detect(McpPlatform platform) async {
    switch (platform) {
      case CommandMcpPlatform():
        final executable = await _locate(platform.executable);
        if (executable == null) return McpInstallState.missing;
        final result = await _run(executable, platform.detectArgs);
        final output = '${result.stdout}';
        if (result.exitCode != 0) return McpInstallState.notInstalled;
        if (output.contains(helperPath)) return McpInstallState.installed;
        return output.contains(McpConstants.serverName)
            ? McpInstallState.pathChanged
            : McpInstallState.notInstalled;
      case ConfigFileMcpPlatform():
        if (!Directory(_clientDirectory(platform)).existsSync()) {
          return McpInstallState.missing;
        }
        final entry = _servers(
          await _readConfig(platform),
        )[McpConstants.serverName];
        if (entry == null) return McpInstallState.notInstalled;
        return entry is Map && entry['command'] == helperPath
            ? McpInstallState.installed
            : McpInstallState.pathChanged;
    }
  }

  Future<void> install(McpPlatform platform) async {
    await _clearQuarantine();
    switch (platform) {
      case CommandMcpPlatform():
        final executable = await _requireExecutable(platform);
        await _run(executable, platform.removeArgs);
        await _checked(executable, [
          for (final arg in platform.addArgs)
            arg == CommandMcpPlatform.helperToken ? helperPath : arg,
        ]);
      case ConfigFileMcpPlatform():
        final config = await _readConfig(platform);
        final servers = _servers(config);
        servers[McpConstants.serverName] = {
          'command': helperPath,
          'args': <String>[],
        };
        config['mcpServers'] = servers;
        await _writeConfig(platform, config);
    }
  }

  Future<void> remove(McpPlatform platform) async {
    switch (platform) {
      case CommandMcpPlatform():
        await _checked(await _requireExecutable(platform), platform.removeArgs);
      case ConfigFileMcpPlatform():
        final config = await _readConfig(platform);
        _servers(config).remove(McpConstants.serverName);
        await _writeConfig(platform, config);
    }
  }

  Future<String?> _locate(String name) async {
    final path = await (_path ??= _searchPath());
    for (final directory in path.split(':')) {
      if (directory.isEmpty) continue;
      final candidate = File('$directory/$name');
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }

  Future<String> _requireExecutable(CommandMcpPlatform platform) async {
    final executable = await _locate(platform.executable);
    if (executable == null) {
      throw McpPlatformException('未检测到 ${platform.clientName}');
    }
    return executable;
  }

  Future<ProcessResult> _run(String executable, List<String> args) async =>
      Process.run(
        executable,
        args,
        workingDirectory: home,
        environment: {'PATH': await (_path ??= _searchPath())},
      );

  Future<void> _checked(String executable, List<String> args) async {
    final result = await _run(executable, args);
    if (result.exitCode == 0) return;
    final message = '${result.stderr}'.trim().isNotEmpty
        ? '${result.stderr}'.trim()
        : '${result.stdout}'.trim();
    throw McpPlatformException(message);
  }

  Future<void> _clearQuarantine() async {
    final result = await Process.run('/usr/bin/xattr', [
      '-d',
      'com.apple.quarantine',
      helperPath,
    ]);
    final error = '${result.stderr}'.trim();
    if (result.exitCode == 0 || error.contains('No such xattr')) return;
    throw McpPlatformException(error);
  }

  String _clientDirectory(ConfigFileMcpPlatform platform) =>
      '$home/${platform.clientDirectory}';

  Future<Map<String, Object?>> _readConfig(
    ConfigFileMcpPlatform platform,
  ) async {
    final file = File('${_clientDirectory(platform)}/${platform.configFile}');
    if (!file.existsSync()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException catch (error) {
      throw McpPlatformException('${file.path} 不是有效的 JSON：${error.message}');
    }
    throw McpPlatformException('${file.path} 顶层不是 JSON 对象');
  }

  Map<String, Object?> _servers(Map<String, Object?> config) {
    final servers = config['mcpServers'];
    if (servers is Map<String, Object?>) return servers;
    return {};
  }

  Future<void> _writeConfig(
    ConfigFileMcpPlatform platform,
    Map<String, Object?> config,
  ) async {
    final file = File('${_clientDirectory(platform)}/${platform.configFile}');
    try {
      if (file.existsSync()) await file.copy('${file.path}.bak');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(config)}\n',
      );
      await temporary.rename(file.path);
    } on FileSystemException catch (error) {
      throw McpPlatformException('${error.message}：${error.path}');
    }
  }
}
