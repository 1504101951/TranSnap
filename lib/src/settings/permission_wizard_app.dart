import '../common/constants/glass_metrics.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';

import '../common/constants/channel_names.dart';
import '../common/constants/method_names.dart';
import '../common/utils/permission_utils.dart';

class PermissionWizardApp extends StatefulWidget {
  const PermissionWizardApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.settings),
  });

  final MethodChannel channel;

  @override
  State<PermissionWizardApp> createState() => _PermissionWizardAppState();
}

class _PermissionWizardAppState extends State<PermissionWizardApp>
    with WidgetsBindingObserver {
  bool _accessibility = false;

  bool _screenAccess = false;

  String? _busyMethod;

  bool get _busy => _busyMethod != null;

  String? _message;

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

  Future<void> _refresh() async {
    try {
      final status = await widget.channel.invokeMapMethod<Object?, Object?>(
        MethodNames.permissionWizardStatus,
      );
      if (!mounted || status == null) return;
      setState(() {
        _accessibility = status['accessibility'] == true;
        _screenAccess = status['screenAccess'] == true;
        if (_accessibility && _screenAccess) _message = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? '无法读取权限状态');
    }
  }

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

  Future<void> _skip() async {
    if (_busy) return;
    await widget.channel.invokeMethod<void>(MethodNames.finishPermissionWizard);
    await widget.channel.invokeMethod<void>(MethodNames.closePermissionWizard);
  }

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
