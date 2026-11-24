import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/native_glass.dart';

import 'service_config.dart';

/// 编辑器只持有草稿；确定后父页自动提交完整服务事务与 Keychain 凭据。
class ServiceEditor extends StatefulWidget {
  const ServiceEditor({
    super.key,
    this.config,
    this.credentials = const {},
    this.hasCredentials = false,
  });

  final ServiceConfig? config;
  final Map<String, String> credentials;
  final bool hasCredentials;

  @override
  State<ServiceEditor> createState() => _ServiceEditorState();
}

/// 管理服务表单与连接测试草稿；仅在确定时返回完整配置和凭据变更。
class _ServiceEditorState extends State<ServiceEditor> {
  final _name = TextEditingController();
  final _base = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _appId = TextEditingController();
  final _tokens = TextEditingController();
  late String _id;
  late String _kind;
  bool _semantic = false;
  bool _testing = false;
  bool _nameEdited = false;
  bool _baseEdited = false;
  bool _obscureKey = true;
  bool _obscureAppId = true;
  String? _message;
  bool _messageIsError = false;

  /// 无参数；读取非敏感配置和本窗口草稿，不从 Keychain 取回密钥，无返回值。
  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _id = config?.id ?? 'service-${DateTime.now().microsecondsSinceEpoch}';
    _kind = config?.kind ?? 'baidu';
    _nameEdited = config != null;
    _baseEdited = config != null;
    _name.text = config?.displayName ?? ServiceConfig.kinds[_kind]!;
    _base.text = config?.baseUrl ?? ServiceConfig.endpoints[_kind]!;
    _model.text = config?.model ?? '';
    _tokens.text = '${config?.maxOutputTokens ?? 4096}';
    _semantic = config?.semanticPairs ?? false;
    _key.text = widget.credentials['apiKey'] ?? '';
    _appId.text = widget.credentials['appId'] ?? '';
  }

  /// 无参数；关闭窗口时释放包含凭据草稿的控制器，无返回值。
  @override
  void dispose() {
    for (final controller in [_name, _base, _model, _key, _appId, _tokens]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 无参数；验证表单，返回配置及非空凭据字段，空字段表示保留已保存值。
  ({ServiceConfig config, Map<String, String> credentials}) _draft() {
    final config = ServiceConfig(
      id: _id,
      kind: _kind,
      name: _name.text.trim(),
      baseUrl: _base.text.trim(),
      model: _model.text.trim(),
      semanticPairs: _semantic,
      maxOutputTokens: int.tryParse(_tokens.text) ?? 0,
    );
    // 配置校验在窗口中给出具体提示，网络测试不替代格式校验。
    config.validate();
    final credentials = <String, String>{
      if (_key.text.trim().isNotEmpty) 'apiKey': _key.text.trim(),
      if (_kind == 'baidu' && _appId.text.trim().isNotEmpty)
        'appId': _appId.text.trim(),
    };
    if (!widget.hasCredentials) config.validateCredentials(credentials);
    return (config: config, credentials: credentials);
  }

  /// test 决定测试草稿还是返回表单结果；测试只发送示例文本，不保存设置。
  Future<void> _submit({required bool test}) async {
    if (_testing) return;
    try {
      // 收集经过验证的草稿，凭据始终与普通配置分开传递。
      final draft = _draft();
      if (!test) {
        Navigator.pop(context, draft);
        return;
      }
      setState(() {
        _testing = true;
        _message = null;
        _messageIsError = false;
      });
      final translation = await const MethodChannel(ChannelNames.settings)
          .invokeMethod<String>(MethodNames.testService, {
            'config': draft.config.toMap(),
            'credentials': draft.credentials,
          });
      if (mounted) {
        setState(() {
          _message = '连接成功：$translation';
          _messageIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = switch (error) {
            PlatformException(:final message) => message ?? '操作失败，请重试。',
            FormatException(:final message) => message,
            _ => '操作失败，请重试。',
          };
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// obscure/tooltip/onToggle 为显隐状态、提示与切换回调；生成密码框右侧可见性切换装饰。
  InputDecoration _secretDecoration({
    required bool obscure,
    required String tooltip,
    required VoidCallback onToggle,
  }) => InputDecoration(
    suffixIconConstraints: const BoxConstraints(
      minWidth: GlassMetrics.hitSize,
      minHeight: GlassMetrics.hitSize,
    ),
    suffixIcon: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: GlassMetrics.icon,
      icon: Icon(
        obscure ? LucideIcons.eye : LucideIcons.eyeOff,
      ),
      onPressed: _testing ? null : onToggle,
    ),
  );

  /// context 为对话框上下文；返回服务字段、显隐切换、语义横幅与带忙碌态的测试连接入口。
  @override
  Widget build(BuildContext context) {
    final isModel = ServiceConfig.isModelKind(_kind);
    return PopScope(
      canPop: !_testing,
      child: NativeGlassDialog(
        title: Text(widget.config == null ? '添加翻译服务' : '编辑翻译服务'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NativeGlassDropdown<String>(
                label: '服务类型',
                value: _kind,
                items: widget.config == null
                    ? ServiceConfig.selectableKinds
                    : {_kind: ServiceConfig.kinds[_kind]!},
                onChanged: widget.config != null || _testing
                    ? null
                    : (value) => setState(() {
                        final previousKind = _kind;
                        _kind = value;
                        // 仅当名称或地址仍为默认模板或留空时跟随切换，保留用户手工填写的值（U-24）。
                        if (!_nameEdited ||
                            _name.text.trim().isEmpty ||
                            _name.text.trim() ==
                                ServiceConfig.kinds[previousKind]) {
                          _name.text = ServiceConfig.kinds[_kind]!;
                          _nameEdited = false;
                        }
                        if (!_baseEdited ||
                            _base.text.trim().isEmpty ||
                            _base.text.trim() ==
                                ServiceConfig.endpoints[previousKind]) {
                          _base.text = ServiceConfig.endpoints[_kind]!;
                          _baseEdited = false;
                        }
                        _message = null;
                        _messageIsError = false;
                      }),
              ),
              NativeGlassField(
                label: '配置名称',
                child: TextField(
                  key: const ValueKey('配置名称'),
                  controller: _name,
                  enabled: !_testing,
                  onChanged: (_) => _nameEdited = true,
                  decoration: const InputDecoration(),
                ),
              ),
              NativeGlassField(
                label: 'API Base URL',
                helper: '填写服务根地址；模型接口通常以 /v1 结尾。',
                child: TextField(
                  key: const ValueKey('API Base URL'),
                  controller: _base,
                  enabled: !_testing,
                  onChanged: (_) => _baseEdited = true,
                  decoration: const InputDecoration(),
                ),
              ),
              if (isModel)
                NativeGlassField(
                  label: '模型名称',
                  child: TextField(
                    key: const ValueKey('模型名称'),
                    controller: _model,
                    enabled: !_testing,
                    decoration: const InputDecoration(hintText: '填写服务商提供的模型 ID'),
                  ),
                ),
              if (_kind == 'baidu')
                NativeGlassField(
                  label: '百度 App ID',
                  helper: widget.hasCredentials ? '已保存，留空保留。' : null,
                  child: TextField(
                    key: const ValueKey('百度 App ID'),
                    controller: _appId,
                    enabled: !_testing,
                    obscureText: _obscureAppId,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: _secretDecoration(
                      obscure: _obscureAppId,
                      tooltip: _obscureAppId ? '显示 App ID' : '隐藏 App ID',
                      onToggle: () =>
                          setState(() => _obscureAppId = !_obscureAppId),
                    ),
                  ),
                ),
              NativeGlassField(
                label: _kind == 'baidu' ? '百度密钥' : 'API Key',
                // 模型服务的 API Key 可留空（#123）。
                helper: widget.hasCredentials
                    ? '已保存，留空保留；凭据保存在 macOS 钥匙串。'
                    : isModel
                    ? '可留空；凭据保存在 macOS 钥匙串。'
                    : '凭据保存在 macOS 钥匙串。',
                child: TextField(
                  key: ValueKey(_kind == 'baidu' ? '百度密钥' : 'API Key'),
                  controller: _key,
                  enabled: !_testing,
                  obscureText: _obscureKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: _secretDecoration(
                    obscure: _obscureKey,
                    tooltip: _obscureKey ? '显示密钥' : '隐藏密钥',
                    onToggle: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              if (isModel) ...[
                NativeGlassSwitchTile(
                  title: '按段落双语对照',
                  subtitle: '结合全文逐段翻译；段落缺失或乱序时提示重试。',
                  value: _semantic,
                  onChanged: _testing
                      ? null
                      : (value) => setState(() => _semantic = value),
                ),
              ],
              if (_kind == 'anthropic')
                NativeGlassField(
                  label: '最大输出 Token 数',
                  child: TextField(
                    key: const ValueKey('最大输出 Token 数'),
                    controller: _tokens,
                    enabled: !_testing,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(),
                  ),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: GlassMetrics.space12),
                  child: NativeGlassBanner(
                    message: _message!,
                    isError: _messageIsError,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          NativeGlassSurface(
            material: true,
            busy: _testing,
            child: TextButton(
              onPressed: _testing ? null : () => _submit(test: true),
              child: Text(_testing ? '正在测试…' : '测试连接'),
            ),
          ),
          NativeGlassSurface(
            material: true,
            child: TextButton(
              onPressed: _testing ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          NativeGlassSurface(
            material: true,
            child: FilledButton(
              onPressed: _testing ? null : () => _submit(test: false),
              child: const Text('确定'),
            ),
          ),
        ],
      ),
    );
  }
}
