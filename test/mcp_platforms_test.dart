@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/settings/mcp_platforms.dart';

void main() {
  late Directory root;
  late Directory bin;
  late Directory home;
  late String helper;

  const fakeCli = r'''#!/bin/bash
cli=$(basename "$0"); store="$(dirname "$0")/$cli.registered"
args=(); skip=0
for a in "$@"; do
  if [ $skip = 1 ]; then skip=0; continue; fi
  case "$a" in -s) skip=1 ;; --json|--) ;; *) args+=("$a") ;; esac
done
case "${args[1]}" in
  get) [ -f "$store" ] || { echo "No MCP server named \"${args[2]}\"" >&2; exit 1; }
       echo "${args[2]}: command $(cat "$store")" ;;
  list) if [ -f "$store" ]; then echo "[{\"name\":\"transnap\",\"command\":\"$(cat "$store")\"}]"; else echo "[]"; fi ;;
  add) if [ "$cli" = claude ] && [ -f "$store" ]; then echo "MCP server ${args[2]} already exists" >&2; exit 1; fi
       printf '%s' "${args[3]}" > "$store" ;;
  remove) [ -f "$store" ] || { echo "No MCP server named \"${args[2]}\"" >&2; exit 1; }
          rm "$store" ;;
esac
''';

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-platforms-');
    bin = Directory('${root.path}/bin')..createSync();
    home = Directory('${root.path}/home')..createSync();
    helper = '${root.path}/TranSnap.app/Contents/MacOS/transnap-mcp';
    File(helper).createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  void installCli(String name) {
    final file = File('${bin.path}/$name')..writeAsStringSync(fakeCli);
    Process.runSync('/bin/chmod', ['+x', file.path]);
  }

  McpPlatformService service() => McpPlatformService(
    helperPath: helper,
    home: home.path,
    searchPath: () async => '${bin.path}:/usr/bin:/bin',
  );

  McpPlatform platform(String id) => mcpPlatforms.firstWhere((p) => p.id == id);

  test('注册表包含 Claude Code、Claude 桌面、Codex、Grok，且只有 Claude 桌面为配置文件式', () {
    expect(mcpPlatforms.map((p) => p.id), [
      'claude-code',
      'claude-desktop',
      'codex',
      'grok',
    ]);
    expect(
      mcpPlatforms
          .where((p) => p.kind == McpPlatformKind.configFile)
          .map((p) => p.id),
      ['claude-desktop'],
    );
  });

  for (final (id, cli) in [
    ('claude-code', 'claude'),
    ('codex', 'codex'),
    ('grok', 'grok'),
  ]) {
    test('$id：未检测到、安装、重复安装、路径变化与删除', () async {
      final mcp = service();
      final target = platform(id);
      expect(await mcp.detect(target), McpInstallState.missing);

      installCli(cli);
      expect(await mcp.detect(target), McpInstallState.notInstalled);
      await mcp.install(target);
      expect(await mcp.detect(target), McpInstallState.installed);
      expect(File('${bin.path}/$cli.registered').readAsStringSync(), helper);

      await mcp.install(target);
      expect(await mcp.detect(target), McpInstallState.installed);

      File('${bin.path}/$cli.registered').writeAsStringSync(
        '/Old/TranSnap.app/Contents/MacOS/transnap-mcp',
      );
      expect(await mcp.detect(target), McpInstallState.pathChanged);

      await mcp.remove(target);
      expect(await mcp.detect(target), McpInstallState.notInstalled);
      await expectLater(
        mcp.remove(target),
        throwsA(
          isA<McpPlatformException>().having(
            (e) => e.message,
            'message',
            contains('No MCP server'),
          ),
        ),
      );
    });
  }

  test('命令式平台找不到 CLI 时安装报未检测到', () async {
    await expectLater(
      service().install(platform('codex')),
      throwsA(
        isA<McpPlatformException>().having(
          (e) => e.message,
          'message',
          '未检测到 codex CLI',
        ),
      ),
    );
  });

  test('Claude 桌面：客户端目录缺失为未检测到；安装只写自身条目、保留其他内容并备份原文件', () async {
    final mcp = service();
    final target = platform('claude-desktop');
    expect(await mcp.detect(target), McpInstallState.missing);

    final directory = Directory(
      '${home.path}/Library/Application Support/Claude',
    )..createSync(recursive: true);
    expect(await mcp.detect(target), McpInstallState.notInstalled);

    final config = File('${directory.path}/claude_desktop_config.json');
    const original =
        '{"globalShortcut": "Alt+Space", "mcpServers": {"other": {"command": "/usr/bin/other"}}}';
    config.writeAsStringSync(original);
    await mcp.install(target);
    expect(await mcp.detect(target), McpInstallState.installed);
    final written =
        jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    expect(written['globalShortcut'], 'Alt+Space');
    expect(written['mcpServers'], {
      'other': {'command': '/usr/bin/other'},
      'transnap': {'command': helper, 'args': <Object?>[]},
    });
    expect(File('${config.path}.bak').readAsStringSync(), original);

    final moved = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    (moved['mcpServers'] as Map)['transnap'] = {
      'command': '/Old/transnap-mcp',
    };
    config.writeAsStringSync(jsonEncode(moved));
    expect(await mcp.detect(target), McpInstallState.pathChanged);

    await mcp.remove(target);
    expect(await mcp.detect(target), McpInstallState.notInstalled);
    expect((jsonDecode(config.readAsStringSync()) as Map)['mcpServers'], {
      'other': {'command': '/usr/bin/other'},
    });
  });

  test('Claude 桌面：没有配置文件时安装新建文件；配置不是 JSON 时检测报错并保留原文件', () async {
    final mcp = service();
    final target = platform('claude-desktop');
    final directory = Directory(
      '${home.path}/Library/Application Support/Claude',
    )..createSync(recursive: true);
    final config = File('${directory.path}/claude_desktop_config.json');

    await mcp.install(target);
    expect(jsonDecode(config.readAsStringSync()), {
      'mcpServers': {
        'transnap': {'command': helper, 'args': <Object?>[]},
      },
    });
    expect(File('${config.path}.bak').existsSync(), isFalse);

    config.writeAsStringSync('{not json');
    await expectLater(
      mcp.detect(target),
      throwsA(
        isA<McpPlatformException>().having(
          (e) => e.message,
          'message',
          contains('不是有效的 JSON'),
        ),
      ),
    );
    expect(config.readAsStringSync(), '{not json');
  });

  test('安装前清除 helper 的 com.apple.quarantine；属性不存在时安装照常成功', () async {
    Process.runSync('/usr/bin/xattr', [
      '-w',
      'com.apple.quarantine',
      '0081;00000000;Safari;',
      helper,
    ]);
    installCli('grok');
    final mcp = service();
    await mcp.install(platform('grok'));
    final remaining = Process.runSync('/usr/bin/xattr', [
      '-p',
      'com.apple.quarantine',
      helper,
    ]);
    expect(remaining.exitCode, isNot(0));

    await mcp.install(platform('grok'));
    expect(await mcp.detect(platform('grok')), McpInstallState.installed);
  });
}
