/// Spec #1 的逻辑点尺寸；控件、材料及窗口命中布局均从这些数值派生。
abstract final class GlassMetrics {
  static const controlRadius = 8.0;
  static const primaryRadius = 10.0;
  static const panelRadius = 16.0;
  static const menuRadius = 10.0;
  static const menuItemRadius = 6.0;
  static const buttonHeight = 28.0;
  static const buttonMinWidth = 64.0;

  /// 设置页快捷键录制按钮统一最小宽度，对齐不同字符宽度的组合显示（#67）。
  static const shortcutButtonMinWidth = 128.0;
  static const primaryHeight = 32.0;
  static const primaryMinWidth = 72.0;
  static const hitSize = 32.0;
  static const icon = 16.0;
  static const iconGap = 6.0;
  // 相邻破坏性操作之间保留空白，避免编辑与删除命中区相接。
  static const actionGap = 8.0;
  static const cropHandle = 8.0;
  static const cropHandleHitRadius = 12.0;
  static const cropEdgeHitRadius = 6.0;
  static const dropdownMinWidth = 120.0;
  static const dropdownMaxWidth = 240.0;
  static const menuMinWidth = 160.0;
  static const menuMaxWidth = 320.0;
  static const appearanceSegmentWidth = 76.0;
  static const navigationWidth = 72.0;
  // 设置窗口左侧两级导航（#67）：宽度、内边距、一级与二级行高、二级缩进。
  static const sidebarWidth = 200.0;
  static const sidebarPadding = 12.0;
  static const sidebarSectionHeight = 32.0;
  static const sidebarItemHeight = 28.0;
  static const sidebarItemIndent = 28.0;
  // 设置子页标题字号。
  static const pageTitleFont = 20.0;
  static const switchWidth = 36.0;
  static const switchHeight = 20.0;
  static const switchThumb = 16.0;

  /// Apple 果冻开关按下态滑块横向拉伸宽度（#67、#144）。
  static const switchThumbPressedWidth = 21.0;
  static const sliderHeight = 32.0;
  static const sliderTrack = 6.0;
  static const sliderThumbRadius = 8.0;
  static const pagePadding = 22.0;
  static const panelPadding = 16.0;
  static const groupGap = 20.0;
  static const rowHeight = 40.0;
  static const captionRowHeight = 60.0;
  static const labelGap = 6.0;
  static const bodyFont = 13.0;
  static const bodyLine = 18.0;
  static const captionFont = 12.0;
  static const captionLine = 17.0;

  /// 设置页静态样式数值（#67 第 14 条）：行间细线、状态标签与侧边栏图标块。
  static const groupDividerThickness = 0.5;
  static const statusHeight = 18.0;
  static const statusRadius = 9.0;
  static const statusPaddingX = 8.0;
  static const statusDotSize = 6.0;
  static const statusDotGap = 5.0;
  static const statusFont = 11.0;
  static const sidebarIconBox = 22.0;
  static const sidebarIconRadius = 6.0;
  static const sidebarIconSize = 12.0;
  static const sidebarSelectionInset = 6.0;
  static const toolbarPadding = 8.0;
  static const toolbarThickness = hitSize + toolbarPadding * 2;
  // 采集结果工具栏相邻操作间距（视频结果为底部横排、长截图为右侧纵排），按Spec #67与原生承载尺寸保持一致。
  static const captureResultActionGap = 12.0;
  static const toastGap = 8.0;
  static const feedbackDuration = Duration(milliseconds: 1000);

  /// 错误提示气泡默认停留时长；悬停期间暂停并在移开后重计（#144）。
  static const errorFeedbackDuration = Duration(milliseconds: 2000);
  static const transition = Duration(milliseconds: 120);
  static const hoverOpacity = 0.06;
  static const pressedOpacity = 0.12;

  /// 全局 4pt 间距阶梯、按钮按下微缩比例、焦点框与最小触控/滚动约束（#67、#144）。
  static const space4 = 4.0;
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space16 = 16.0;
  static const space20 = 20.0;
  static const space24 = 24.0;
  static const buttonPressedScale = 0.96;
  static const focusRingWidth = 2.0;
  static const minTouchTarget = 24.0;
  static const menuMaxHeight = 320.0;
  static const sliderOverlayRadius = 14.0;
  static const sliderThumbBorderWidth = 1.5;

  /// 方案 A 桌面工艺扩展度量：分组卡片眉标与轮廓、行图标锚点、机械键帽（#67、#144）。
  static const groupHeaderFont = 11.5;
  static const groupHeaderGap = 5.0;
  static const groupBorderWidth = 0.5;
  static const rowIconBox = 28.0;
  static const rowIconRadius = 8.0;
  static const rowIconSize = 15.0;
  static const rowIconGap = 12.0;
  static const keycapMinWidth = 22.0;
  static const keycapHeight = 20.0;
  static const keycapRadius = 5.0;
  static const keycapGap = 4.0;
}
