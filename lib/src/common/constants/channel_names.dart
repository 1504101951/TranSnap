/// Dart 使用的平台通道名协议值；与 Swift AppConstants 同名值字面量一致，改名须两端同步。
abstract final class ChannelNames {
  /// 附属引擎入口的独立就绪确认通道。
  static const windowStartup = 'transnap/window_startup';

  /// 连续采集与媒体输出的独立窗口通道。
  static const capture = 'transnap/capture';

  /// 录制结果中的系统播放器视图。
  static const captureVideoPreview = 'transnap/capture_video_preview';

  static const appearance = 'transnap/appearance';

  /// 主引擎平台通道与事件通道；macOS 与 Windows 原生实现同一协议。
  static const platform = 'transnap/platform';

  static const platformEvents = 'transnap/platform/events';

  static const screenshot = 'transnap/screenshot';

  static const settings = 'transnap/settings';
}
