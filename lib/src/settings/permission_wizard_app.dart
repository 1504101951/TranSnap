import '../common/constants/glass_metrics.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';

import '../common/constants/channel_names.dart';
import '../common/constants/method_names.dart';
import '../common/utils/permission_utils.dart';

/// 首次启动权限窗口；一页同时申请辅助功能与录屏，不写 TCC.db。
class PermissionWizardApp extends StatefulWidget {
  const PermissionWizardApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.settings),
  });

  /// 与原生设置桥共用的方法通道。
  final MethodChannel channel;

  /// 无参数；创建向导状态。
  @override
  State<PermissionWizardApp> createState() => _PermissionWizardAppState();
}

/// 管理授权状态刷新和申请中的交互；不直接修改系统权限数据库。
class _PermissionWizardAppState extends State<PermissionWizardApp>
    with WidgetsBindingObserver {
  /// 辅助功能是否已授权。
  bool _accessibility = false;

  /// 屏幕录制是否已授权。
  bool _screenAccess = false;

  /// 正在向系统申请的权限方法名；非空时禁用按钮，避免重复弹系统框。
  String? _busyMethod;

  bool get _busy => _busyMethod != null;

  /// 系统 API 失败时的可读说明。
  String? _message;

  /// 无参数；两项都授权后才能进入应用。
  bool get _canEnter => canEnterApp(
    accessibilityGranted: _accessibility,
    screenRecordingGranted: _screenAccess,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.permissionStatusChanged) {
        await _refresh();
      }
    });
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  /// 无参数；读取当前授权，异常时展示提示；不因未点「进入应用」而关窗。
  Future<void> _refresh() async {
    try {
      final status = await widget.channel.invokeMapMethod<Object?, Object?>(
        MethodNames.permissionWizardStatus,
      );
      if (!mounted || status == null) return;
      setState(() {
        _accessibility = status['accessibility'] == true;
        _screenAccess = status['screenAccess'] == true;
        // 两项权限均就绪后清除残留错误横幅，保持完成态清晰。
        if (_accessibility && _screenAccess) _message = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? '无法读取权限状态');
    }
  }

  /// alreadyGranted 为该项当前状态，method 为对应系统申请；申请前清空旧错误并锁定并发点击。
  Future<void> _request(bool alreadyGranted, String method) async {
    if (_busy) return;
    if (alreadyGranted) {
      setState(() => _message = null);
      await _refresh();
      return;
    }
    setState(() {
      _busyMethod = method;
      _message = null;
    });
    try {
      await widget.channel.invokeMethod<void>(method);
      await _refresh();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '申请权限失败，请重试。');
    } finally {
      if (mounted) setState(() => _busyMethod = null);
    }
  }

  /// 无参数；关闭向导，下次启动若仍缺权限会再弹出。
  Future<void> _skip() async {
    if (_busy) return;
    await widget.channel.invokeMethod<void>(MethodNames.finishPermissionWizard);
    await widget.channel.invokeMethod<void>(MethodNames.closePermissionWizard);
  }

  /// 无参数；两项都成功后进入菜单栏使用。
  Future<void> _enter() async {
    if (_busy || !_canEnter) return;
    await widget.channel.invokeMethod<void>(MethodNames.finishPermissionWizard);
    await widget.channel.invokeMethod<void>(MethodNames.closePermissionWizard);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// context 为窗口上下文；返回主体可滚动且底部操作固定的单页双按钮向导。
  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      title: '授权',
      home: NativeGlassWindowPage(
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(GlassMetrics.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 矮窗口或大字号下仅正文区滚动，底部取消与主操作保持固定可达（U-14）。
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '使用前需要两项权限',
                          style: TextStyle(
                            fontSize: 20,
                            height: 26 / 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: GlassMetrics.space8),
                        const Text('授权后 TranSnap 会出现在系统列表中。都完成后即可进入应用。'),
                        const SizedBox(height: GlassMetrics.space20),
                        _PermissionRow(
                          title: '辅助功能',
                          granted: _accessibility,
                          buttonLabel: '授权辅助功能',
                          busy: _busyMethod == MethodNames.openAccessibility,
                          onPressed: _busy
                              ? null
                              : () => _request(
                                  _accessibility,
                                  MethodNames.openAccessibility,
                                ),
                        ),
                        const SizedBox(height: GlassMetrics.space12),
                        _PermissionRow(
                          title: '屏幕录制',
                          granted: _screenAccess,
                          buttonLabel: '申请录屏权限',
                          busy: _busyMethod == MethodNames.requestScreenAccess,
                          onPressed: _busy
                              ? null
                              : () => _request(
                                  _screenAccess,
                                  MethodNames.requestScreenAccess,
                                ),
                        ),
                        if (_message != null) ...[
                          const SizedBox(height: GlassMetrics.space12),
                          NativeGlassBanner(message: _message!, isError: true),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: GlassMetrics.space16),
                Row(
                  children: [
                    NativeGlassSurface(
                      material: true,
                      child: TextButton(
                        onPressed: _busy ? null : _skip,
                        child: const Text('稍后'),
                      ),
                    ),
                    const Spacer(),
                    NativeGlassSurface(
                      material: true,
                      child: FilledButton(
                        onPressed: _busy || !_canEnter ? null : _enter,
                        child: const Text('进入应用'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// title 为权限名，granted 为当前状态，buttonLabel 为申请按钮文案，busy 为当前行正在申请。
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.title,
    required this.granted,
    required this.buttonLabel,
    required this.onPressed,
    this.busy = false,
  });

  final String title;
  final bool granted;
  final String buttonLabel;
  final VoidCallback? onPressed;
  final bool busy;

  /// context 为布局上下文；返回一行状态与次级申请按钮（主行动留给底部「进入应用」）。
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: GlassMetrics.space4),
              NativeGlassStatus(granted: granted),
            ],
          ),
        ),
        // 单行申请使用描边次级按钮，避免与底部「进入应用」主按钮视觉平级冲突（U-21）。
        NativeGlassSurface(
          material: true,
          busy: busy,
          child: OutlinedButton(
            onPressed: granted ? null : onPressed,
            child: Text(granted ? '已完成' : buttonLabel),
          ),
        ),
      ],
    );
  }
}
