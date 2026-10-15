import 'package:PiliPlus/common/widgets/appbar/appbar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/keep_alive_wrapper.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart'
    show tabBarScrollPhysics;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/pages/history/base_controller.dart';
import 'package:PiliPlus/pages/history/controller.dart';
import 'package:PiliPlus/pages/history/widgets/item.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/history_archive.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.type});

  final String? type;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with AutomaticKeepAliveClientMixin, GridMixin {
  late final HistoryController _historyController;

  @override
  void initState() {
    super.initState();
    _historyController = Get.put(
      HistoryController(widget.type),
      tag: widget.type ?? 'all',
    );
  }

  HistoryController currCtr([int? index]) {
    try {
      index ??= _historyController.tabController!.index;
      if (index != 0) {
        return Get.find<HistoryController>(
          tag: _historyController.tabs[index - 1].type,
        );
      }
    } catch (_) {}
    return _historyController;
  }

  @override
  void dispose() {
    Get.delete<HistoryBaseController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final padding = MediaQuery.viewPaddingOf(context);
    Widget child = refreshIndicator(
      onRefresh: _historyController.onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        controller: _historyController.scrollController,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(
              top: 7,
              bottom: padding.bottom + 100,
            ),
            sliver: Obx(
              () => _buildBody(_historyController.loadingState.value),
            ),
          ),
        ],
      ),
    );
    if (widget.type != null) {
      return child;
    }
    return Obx(
      () {
        final enableMultiSelect =
            _historyController.baseCtr.enableMultiSelect.value;
        return popScope(
          canPop: !enableMultiSelect,
          onPopInvokedWithResult: (didPop, result) {
            if (enableMultiSelect) {
              currCtr().handleSelect();
            }
          },
          child: SimpleScaffold(
            appBar: MultiSelectAppBarWidget(
              visible: enableMultiSelect,
              ctr: currCtr(),
              child: _buildAppBar,
            ),
            body: Padding(
              padding: .only(left: padding.left, right: padding.right),
              child: Obx(() {
                final tabs = _historyController.tabs;
                if (tabs.isEmpty) {
                  return Column(
                    children: [
                      ?_buildArchiveTip,
                      Expanded(child: child),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ?_buildPauseTip,
                    ?_buildArchiveTip,
                    TabBar(
                      controller: _historyController.tabController,
                      onTap: (index) {
                        if (!_historyController
                            .tabController!
                            .indexIsChanging) {
                          currCtr().scrollController.animToTop();
                        } else {
                          if (enableMultiSelect) {
                            currCtr(
                              _historyController.tabController!.previousIndex,
                            ).handleSelect();
                          }
                        }
                      },
                      tabs: [
                        const Tab(text: '全部'),
                        ...tabs.map((item) => Tab(text: item.name)),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        physics: enableMultiSelect
                            ? const NeverScrollableScrollPhysics()
                            : tabBarScrollPhysics,
                        controller: _historyController.tabController,
                        horizontalDragGestureRecognizer:
                            CustomHorizontalDragGestureRecognizer.new,
                        children: [
                          KeepAliveWrapper(child: child),
                          ...tabs.map(
                            (item) => HistoryPage(type: item.type),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        );
      },
    );
  }

  AppBar get _buildAppBar => AppBar(
    title: const Text('观看记录'),
    actions: [
      IconButton(
        tooltip: '搜索',
        onPressed: () => Get.toNamed('/historySearch'),
        icon: const Icon(Icons.search_outlined),
      ),
      PopupMenuButton(
        itemBuilder: (_) {
          final stats = HistoryArchive.stats(_historyController.archiveMid);
          return <PopupMenuEntry>[
            PopupMenuItem(
              onTap: () => _historyController.baseCtr.onPauseHistory(context),
              child: Text(
                !_historyController.baseCtr.pauseStatus.value
                    ? '暂停观看记录'
                    : '恢复观看记录',
              ),
            ),
            PopupMenuItem(
              onTap: () => _historyController.baseCtr.onClearHistory(
                context,
                () {
                  _historyController.loadingState.value = const Success(null);
                  if (_historyController.tabController != null) {
                    for (final item in _historyController.tabs) {
                      try {
                        Get.find<HistoryController>(
                          tag: item.type,
                        ).loadingState.value = const Success(
                          null,
                        );
                      } catch (_) {}
                    }
                  }
                },
              ),
              child: const Text('清空观看记录'),
            ),
            PopupMenuItem(
              onTap: currCtr().onDelViewedHistory,
              child: const Text('删除已看记录'),
            ),
            const PopupMenuDivider(height: 12),
            PopupMenuItem(
              onTap: () => _historyController.onSyncArchive(),
              child: Text(
                stats.total > 0
                    ? '同步到本地存档（已存 ${stats.total} 条）'
                    : '同步到本地存档',
              ),
            ),
            PopupMenuItem(
              onTap: () => _showArchiveStatsDialog(stats),
              child: const Text('本地存档统计'),
            ),
            PopupMenuItem(
              onTap: () => _historyController.toggleOnlyLocal(),
              child: Row(
                children: [
                  Icon(
                    Pref.historyArchiveOnlyLocal
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  const Text('仅看本地存档', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
            PopupMenuItem(
              onTap: () => _historyController.toggleShowDeleted(),
              child: Row(
                children: [
                  Icon(
                    Pref.historyArchiveShowDeleted
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  const Text('显示官方已删除', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
            PopupMenuItem(
              onTap: () => _toggleAutoSync(),
              child: Row(
                children: [
                  Icon(
                    Pref.historyArchiveAutoSync
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  const Text('自动归档', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
            const PopupMenuDivider(height: 12),
            PopupMenuItem(
              onTap: () => _historyController.onVerifyArchive(),
              child: const Text('校验云端删除状态'),
            ),
            PopupMenuItem(
              onTap: () => _historyController.onClearArchive(),
              child: Text(
                '清空本地存档',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ];
        },
      ),
      const SizedBox(width: 6),
    ],
  );

  void _toggleAutoSync() {
    Pref.historyArchiveAutoSync = !Pref.historyArchiveAutoSync;
    SmartDialog.showToast(
      Pref.historyArchiveAutoSync ? '已开启自动归档' : '已关闭自动归档',
    );
  }

  void _showArchiveStatsDialog(
    ({int total, int deleted, int? earliest, int? latest}) stats,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地存档统计'),
        content: Text(
          '条目总数：${stats.total}\n'
          '官方已删除：${stats.deleted}\n'
          '最早记录：${stats.earliest == null ? '无' : DateFormatUtils.format(stats.earliest)}'
          '\n最近记录：${stats.latest == null ? '无' : DateFormatUtils.format(stats.latest)}'
          '\n\n存档保存在本机独立数据库中，'
          '不受「清除缓存」「重置数据」影响，'
          '可突破 B 站云端 3 个月限制。',
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(LoadingState<List<HistoryItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (index == response.length - 1) {
                    _historyController.onLoadMore();
                  }
                  final item = response[index];
                  return HistoryItem(
                    item: item,
                    ctr: _historyController,
                    onDelete: (kid, business) =>
                        _historyController.delHistory(item),
                  );
                },
                itemCount: response.length,
              )
            : HttpError(onReload: _historyController.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _historyController.onReload,
      ),
    };
  }

  PreferredSizeWidget? get _buildPauseTip {
    if (_historyController.baseCtr.pauseStatus.value) {
      final theme = Theme.of(context).colorScheme;
      return PreferredSize(
        preferredSize: const Size.fromHeight(38),
        child: Container(
          height: 38,
          color: theme.secondaryContainer.withValues(alpha: 0.8),
          padding: const EdgeInsets.only(left: 16, right: 6),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  strutStyle: const StrutStyle(height: 1, leading: 0),
                  style: TextStyle(
                    height: 1,
                    color: theme.onSecondaryContainer,
                  ),
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: theme.onSecondaryContainer,
                        ),
                      ),
                      const TextSpan(text: ' 历史记录功能已关闭'),
                    ],
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _historyController.baseCtr.onPauseHistory(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 10,
                  ),
                  child: Text(
                    '点击开启',
                    strutStyle: const StrutStyle(height: 1, leading: 0),
                    style: TextStyle(height: 1, color: theme.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return null;
  }

  PreferredSizeWidget? get _buildArchiveTip {
    // 仅在「仅看本地存档」或「云端加载失败兜底」时显示提示条，
    // 「云端到底无缝续接」属于正常合并模式，不显示横幅。
    if (!Pref.historyArchiveOnlyLocal &&
        !_historyController.cloudErrorRx.value) {
      return null;
    }
    final onlyLocal = Pref.historyArchiveOnlyLocal;
    final cloudError = _historyController.cloudErrorRx.value;
    final theme = Theme.of(context).colorScheme;
    return PreferredSize(
      preferredSize: const Size.fromHeight(38),
      child: Container(
        height: 38,
        color: theme.tertiaryContainer.withValues(alpha: 0.8),
        padding: const EdgeInsets.only(left: 16, right: 6),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                strutStyle: const StrutStyle(height: 1, leading: 0),
                style: TextStyle(
                  height: 1,
                  color: theme.onTertiaryContainer,
                ),
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.folder_special_outlined,
                        size: 18,
                        color: theme.onTertiaryContainer,
                      ),
                    ),
                    TextSpan(
                      text: onlyLocal
                          ? ' 正在查看本地永久存档'
                          : (cloudError ? ' 云端数据不可用，正在显示本地存档' : ' 云端已到底，继续显示本地存档'),
                    ),
                  ],
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onlyLocal
                  ? _historyController.toggleOnlyLocal()
                  : _historyController.onReload(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: 10,
                ),
                child: Text(
                  onlyLocal ? '切回云端' : (cloudError ? '重试云端' : '刷新'),
                  strutStyle: const StrutStyle(height: 1, leading: 0),
                  style: TextStyle(height: 1, color: theme.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => widget.type != null;
}