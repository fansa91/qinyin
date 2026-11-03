import 'package:flutter/widgets.dart';

/// 桌面自适应断点（M3 窗口尺寸档），全 App 集中一处，各页共用，
/// 不要在页面里散落魔法数。
///
/// - compact（<600）：手机布局，底部导航 + 单列，逐字保持原样。
/// - medium（600–899）：侧边 NavigationRail + 列表多列 + 表单限宽。
/// - expanded（≥900）：在 medium 基础上，专辑页 / 播放页转双栏。
abstract final class Breakpoints {
  /// 进入中等档的最小宽度
  static const double medium = 600;

  /// 进入宽屏档的最小宽度
  static const double expanded = 900;

  /// 表单 / 列表类页面（我的、设置、下载管理、主题设置）的内容限宽
  static const double formMaxWidth = 800;
}

/// 窗口尺寸档位
enum WindowClass { compact, medium, expanded }

/// 当前窗口所处档位
WindowClass windowClassOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= Breakpoints.expanded) return WindowClass.expanded;
  if (width >= Breakpoints.medium) return WindowClass.medium;
  return WindowClass.compact;
}

/// 是否为非紧凑档（≥600：侧边导航、多列、限宽生效）
bool isWide(BuildContext context) =>
    windowClassOf(context) != WindowClass.compact;

/// 是否为宽屏档（≥900：专辑 / 播放页双栏生效）
bool isExpanded(BuildContext context) =>
    windowClassOf(context) == WindowClass.expanded;

/// 内容限宽居中容器：宽屏下把子内容限制在 [maxWidth] 内居中；
/// 紧凑档下屏幕宽度远小于限宽，约束不起作用，布局与不限宽时一致。
class ConstrainedCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ConstrainedCenter({
    super.key,
    required this.child,
    this.maxWidth = Breakpoints.formMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
