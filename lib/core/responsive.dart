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

  /// 超宽参考线（≥1400）：网格继续增列、播放页内容封顶的判断参考
  static const double ultra = 1400;

  /// 表单 / 列表类页面（我的、设置、下载管理、主题设置）的内容限宽；
  /// 歌词 / 评论全量页同属阅读型内容，沿用同一限宽。
  static const double formMaxWidth = 800;

  /// 混合内容页限宽（首页、详情、电台、歌手）：网格增列 + 曲目
  /// 列表封顶共用，超宽窗口下内容居中在这个宽度内，不再无限拉伸。
  static const double listMaxWidth = 1200;

  /// 搜索页（浏览区 + 三页签结果列表）的内容限宽
  static const double searchMaxWidth = 960;

  /// 新鲜模式竖滑页（播放页 FreshPlayer / 推荐页滑动形态）在
  /// medium 档的居中列宽：竖滑页是手机形态，宽窗口下整列居中，
  /// 不横向拉伸封面与控件。
  static const double paneMaxWidth = 600;

  /// 桌面播放页双栏内容封顶：超宽窗口下两栏不再无限拉开
  static const double playerMaxWidth = 1440;

  /// 列表型底部弹层（队列、已加载列表、场景选择、评论抽屉）的
  /// 最大宽度：宽屏下居中成一张合理宽度的表，不再全宽拉伸。
  static const double sheetMaxWidth = 720;

  /// 菜单 / 选项型底部弹层（歌曲菜单、选歌单、音质选择）的最大宽度
  static const double menuSheetMaxWidth = 560;

  /// 歌单 / 专辑卡片网格的卡片最大宽：配合
  /// SliverGridDelegateWithMaxCrossAxisExtent，列数随可用宽度
  /// 自动增减（限宽容器内：约 358→2 列、736→4 列、1168→5 列），
  /// 卡片不会被拉宽。
  static const double cardMaxExtent = 230;
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
