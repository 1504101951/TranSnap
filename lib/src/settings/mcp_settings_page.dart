import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/mcp_constants.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'mcp_platforms.dart';

class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.controlEnabled,
    required this.onControlChanged,
    required this.channel,
    this.createService = defaultService,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final bool controlEnabled;
  final ValueChanged<bool> onControlChanged;
  final MethodChannel channel;
  final McpPlatformService Function(String helperPath) createService;

  static String clientConfig(String helperPath) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          McpConstants.serverName: {'command': helperPath, 'args': <String>[]},
        },
      });

  static McpPlatformService defaultService(String helperPath) =>
      McpPlatformService(helperPath: helperPath);

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  static const _copyLabel = '复制客户端配置';
  static const _copiedLabel = '已复制';

  String? _helperPath;
  McpPlatformService? _service;
  bool _loadingHelper = true;
  String? _loadError;
  bool _copied = false;
  Timer? _feedback;

  final Map<String, McpInstallState> _states = {};

  final Map<String, String> _errors = {};

  final Set<String> _restartHints = {};

  final Map<String, String> _workingActions = {};

  @override
  void initState() {
    super.initState();
    _loadHelper();
  }

  @override
  void dispose() {
    _feedback?.cancel();
    super.dispose();
  }

  Future<void> _loadHelper() async {
    setState(() {
      _loadingHelper = true;
      _loadError = null;
    });
    try {
      final path = await widget.channel.invokeMethod<String>(
        MethodNames.mcpHelperPath,
      );
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        setState(() {
          _loadingHelper = false;
          _loadError = '未获取到 MCP helper 路径';
        });
        return;
      }
      setState(() {
        _helperPath = path;
        _service = widget.createService(path);
        _loadingHelper = false;
        _loadError = null;
      });
      for (final platform in mcpPlatforms) {
        _detect(platform);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingHelper = false;
        _loadError = error.message ?? '无法读取 MCP helper 路径';
      });
    }
  }

  Future<void> _detect(McpPlatform platform) async {
    setState(() => _states[platform.id] = McpInstallState.checking);
    McpInstallState state;
    try {
      state = await _service!.detect(platform);
    } on McpPlatformException catch (error) {
      state = McpInstallState.notInstalled;
      _errors[platform.id] = error.message;
    }
    if (mounted) setState(() => _states[platform.id] = state);
  }

  Future<void> _perform(
    McpPlatform platform,
    String actionKey,
    Future<void> Function(McpPlatform) action,
  ) async {
    if (_workingActions.containsKey(platform.id)) return;
    setState(() {
      _workingActions[platform.id] = actionKey;
      _errors.remove(platform.id);
      _restartHints.remove(platform.id);
    });
    try {
      await action(platform);
      if (platform is ConfigFileMcpPlatform) _restartHints.add(platform.id);
    } on McpPlatformException catch (error) {
      _errors[platform.id] = error.message;
    }
    if (!mounted) return;
    setState(() => _workingActions.remove(platform.id));
    await _detect(platform);
  }

  Future<void> _confirmRemove(McpPlatform platform) async {
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '从 ${platform.name} 删除 TranSnap？',
      message: '只移除该平台中的 transnap 条目，可随时重新安装。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed && mounted) {
      await _perform(platform, 'remove', _service!.remove);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: McpSettingsPage.clientConfig(_helperPath!)),
    );
    if (!mounted) return;
    _feedback?.cancel();
    setState(() => _copied = true);
    _feedback = Timer(GlassMetrics.feedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Widget _textButton(
    Key key,
    Widget label,
    VoidCallback? onPressed, {
    bool busy = false,
  }) => NativeGlassSurface(
    material: true,
    busy: busy,
    child: TextButton(key: key, onPressed: onPressed, child: label),
  );

  Widget _platformRow(McpPlatform platform) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall;
    final state = _states[platform.id] ?? McpInstallState.checking;
    final workingAction = _workingActions[platform.id];
    final idle = workingAction == null;
    final registered =
        state == McpInstallState.installed ||
        state == McpInstallState.pathChanged;
    final canInstall =
        idle && (registered || state == McpInstallState.notInstalled);
    final error = _errors[platform.id];
    return Column(
      key: ValueKey('mcp-platform-${platform.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(platform.name),
                    Text(state.label(platform), style: caption),
                    if (_restartHints.contains(platform.id) &&
                        platform is ConfigFileMcpPlatform)
                      Text(platform.restartHint, style: caption),
                  ],
                ),
              ),
              _textButton(
                ValueKey('mcp-install-${platform.id}'),
                Text(registered ? '重新安装' : '安装'),
                canInstall
                    ? () => _perform(platform, 'install', _service!.install)
                    : null,
                busy: workingAction == 'install',
              ),
              const SizedBox(width: GlassMetrics.actionGap),
              _textButton(
                ValueKey('mcp-remove-${platform.id}'),
                const Text('删除'),
                idle && registered ? () => _confirmRemove(platform) : null,
                busy: workingAction == 'remove',
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: GlassMetrics.space8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LineIcon(
                  LucideIcons.circleAlert,
                  size: GlassMetrics.icon,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: GlassMetrics.space4),
                Expanded(
                  child: Text(
                    error,
                    key: ValueKey('mcp-error-${platform.id}'),
                    style: caption?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = _helperPath == null ? null : _copy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NativeGlassGroup(
          title: 'MCP 接口',
          dividerIndent: 0,
          children: [
            NativeGlassSwitchTile(
              title: '允许 agent 截图',
              value: widget.enabled,
              onChanged: widget.onChanged,
            ),
            NativeGlassSwitchTile(
              title: '允许操控电脑',
              value: widget.controlEnabled,
              onChanged: widget.enabled ? widget.onControlChanged : null,
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: GlassMetrics.captionRowHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: GlassMetrics.space8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('helper 路径'),
                          const SizedBox(height: GlassMetrics.space4),
                          SelectableText(
                            _helperPath ?? '',
                            key: const ValueKey('mcp-helper-path'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: GlassMetrics.space12),
                    _textButton(
                      const ValueKey('mcp-copy-config'),
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          const ExcludeSemantics(
                            child: Opacity(opacity: 0, child: Text(_copyLabel)),
                          ),
                          Text(_copied ? _copiedLabel : _copyLabel),
                        ],
                      ),
                      copy,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        NativeGlassGroup(
          title: '接入平台',
          dividerIndent: 0,
          children: [
            if (_loadError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: GlassMetrics.space8,
                ),
                child: NativeGlassBanner(
                  message: _loadError!,
                  isError: true,
                  action: NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      onPressed: _loadHelper,
                      child: const Text('重试加载'),
                    ),
                  ),
                ),
              )
            else if (_service == null && _loadingHelper)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: GlassMetrics.space12,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: GlassMetrics.space8),
                    Text(
                      '正在检测接入平台…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else
              for (final platform in mcpPlatforms) _platformRow(platform),
          ],
        ),
      ],
    );
  }
}
