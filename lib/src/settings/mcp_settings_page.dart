import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/mcp_constants.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'mcp_platforms.dart';

/// 设置窗口的 MCP 页（#96「设置」、#67「设置 MCP 页（#96）」）。
/// 第一组为 MCP 开关、「允许操控电脑」开关（#140）、helper 路径与客户端配置复制；第二组按 [mcpPlatforms] 注册表列出接入平台，
/// 提供检测、安装与删除。开关只回报新值，由设置页经主引擎提交队列持久化；
/// helper 路径向原生读取 App 包内实际位置。
class McpSettingsPage extends StatefulWidget {
  /// enabled 为已加载草稿中的开关值；onChanged 接收用户切换后的新值；
  /// controlEnabled、onControlChanged 为「允许操控电脑」的值与切换回调（#140）；channel 为设置窗口通道；
  /// createService 按 helper 路径创建平台服务，缺省使用真实 CLI 与用户主目录。
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

  /// 作用：生成可直接粘贴到 MCP 客户端的配置。
  /// 参数 helperPath：helper 完整路径。
  /// 返回：缩进两格的 JSON 字符串 {"mcpServers": {"translateapp": {"command": 路径, "args": []}}}。
  static String clientConfig(String helperPath) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          McpConstants.serverName: {'command': helperPath, 'args': <String>[]},
        },
      });

  /// 作用：创建执行真实 CLI、读写用户主目录配置的平台服务。参数 helperPath：helper 路径。返回：服务实例。
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

  /// 各平台状态；未出现的平台视为检测中。
  final Map<String, McpInstallState> _states = {};

  /// 各平台最近一次失败的原文，保留到该平台下次操作。
  final Map<String, String> _errors = {};

  /// 安装或删除成功后需提示重启客户端的配置文件式平台。
  final Set<String> _restartHints = {};

  /// 正在安装（'install'）或删除（'remove'）的平台，期间禁用两个按钮并为当前按钮激活进度环（U-24）。
  final Map<String, String> _workingActions = {};

  /// 无参数；读取 helper 路径后创建平台服务并检测全部平台。
  @override
  void initState() {
    super.initState();
    _loadHelper();
  }

  /// 无参数；解除复制反馈计时器，防止页面销毁后回调触发 setState。
  @override
  void dispose() {
    _feedback?.cancel();
    super.dispose();
  }

  /// 无参数；读取 MCP helper 路径并在成功时探测全部已注册平台，失败时提供可重试提示。
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

  /// 作用：检测一个平台并刷新该行。参数 platform：注册项。
  /// 配置文件无法解析时状态记为未安装，并显示错误原文。
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

  /// 作用：执行安装或删除后重新检测。参数 platform：注册项；actionKey：操作类型（'install'/'remove'）；action：执行回调。
  /// 失败原文显示在该行下方；配置文件式平台成功后提示重启客户端。
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

  /// 作用：二次确认后删除（使用破坏性主按钮样式）。参数 platform：注册项。
  Future<void> _confirmRemove(McpPlatform platform) async {
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '从 ${platform.name} 删除 TranslateApp？',
      message: '只移除该平台中的 translateapp 条目，可随时重新安装。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed && mounted) {
      await _perform(platform, 'remove', _service!.remove);
    }
  }

  /// 无参数；把客户端配置写入剪贴板，按钮文字显示「已复制」1000ms（#96 待确认值）。
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

  /// 作用：生成统一玻璃材料与忙碌进度环的文字按钮，避免外层额外 GestureDetector 导致重复语义节点（U-25）。
  /// 参数 key：按钮键；label：按钮内容；onPressed：点击动作，null 为不可用；busy：是否显示 BusyRing 进度环。返回：按钮控件。
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

  /// 作用：生成一个平台行。参数 platform：注册项。返回：最小高 60 的行及其下方的失败原文。
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
                Icon(
                  Icons.error_outline,
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
            // 操控依赖 MCP 接口；「允许 agent 截图」关闭时该行禁用（#67「设置 MCP 页」）。
            NativeGlassSwitchTile(
              title: '允许操控电脑',
              value: widget.controlEnabled,
              onChanged: widget.enabled ? widget.onControlChanged : null,
            ),
            // 路径与复制按钮同行排布，让 MCP 页在 760×640 默认窗口内一屏完整展示无滚动条（#67）。
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
                          // 完整路径可选中复制，超长换行，不截断、不缩小字号。
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
                      // 隐藏的最长文案占位，反馈文字切换时按钮宽度不变。
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
