import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models_new/history/data.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/models_new/history/tab.dart';
import 'package:PiliPlus/pages/common/multi_select/multi_select_controller.dart';
import 'package:PiliPlus/pages/history/base_controller.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/history_archive.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class HistoryController
    extends MultiSelectController<HistoryData, HistoryItemModel>
    with GetSingleTickerProviderStateMixin {
  HistoryController(this.type);

  late final baseCtr = Get.put(HistoryBaseController());

  Account get account => baseCtr.account;

  final String? type;
  TabController? tabController;
  late RxList<HistoryTab> tabs = <HistoryTab>[].obs;

  int? max;
  int? viewAt;

  /// 数据源是否已切换到本地存档
  bool _localSource = false;

  bool get isLocalSource => _localSource;

  /// 云端是否加载失败（用于提示条区分显示）
  bool _cloudError = false;

  bool get cloudError => _cloudError;

  /// 数据源状态响应式镜像（供「本地存档提示条」实时显示）
  final RxBool localSourceRx = false.obs;

  /// 云端加载失败状态响应式镜像
  final RxBool cloudErrorRx = false.obs;

  void _setLocalSource(bool value) {
    _localSource = value;
    localSourceRx.value = value;
  }

  void _setCloudError(bool value) {
    _cloudError = value;
    cloudErrorRx.value = value;
  }

  /// 已展示过的条目 key（与本地存档去重，避免重复）
  final Set<String> _shownKeys = {};

  /// 本地存档分页游标
  int? _archiveCursorViewAt;
  String? _archiveCursorKey;

  bool _autoSyncStarted = false;

  @override
  RxInt get rxCount => baseCtr.checkedCount;

  @override
  RxBool get enableMultiSelect => baseCtr.enableMultiSelect;

  /// 本地存档是否可用（已登录）
  bool get archiveEnabled => HistoryArchive.isEnabled(account);

  int get archiveMid => HistoryArchive.midOf(account);

  @override
  void onInit() {
    super.onInit();
    historyStatus();
    queryData();
    autoSyncArchive();
  }

  /// 打开页面时自动增量归档（10 分钟内不重复；仅由「全部」页触发）
  void autoSyncArchive() {
    if (type != null || _autoSyncStarted) return;
    _autoSyncStarted = true;
    if (!Pref.historyArchiveAutoSync) return;
    if (!archiveEnabled) return;
    final mid = archiveMid;
    final last = HistoryArchive.lastSyncAt(mid);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (last != null && now - last < 600) return;
    HistoryArchiveSyncer.sync(account: account).then((res) {
      if (res.error == null && res.added > 0) {
        SmartDialog.showToast('观看历史已自动归档 ${res.added} 条');
      }
    });
  }

  @override
  Future<void> onRefresh() {
    max = null;
    viewAt = null;
    return super.onRefresh();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading) return;
    if (!isRefresh && isEnd) return;
    isLoading = true;
    try {
      if (isRefresh) {
        await _refresh();
      } else {
        await _loadMore();
      }
    } catch (e) {
      if (isRefresh) {
        loadingState.value = Error(e.toString());
      }
    } finally {
      isLoading = false;
    }
  }

  // 首屏 / 刷新
  Future<void> _refresh() async {
    page = 1;
    _shownKeys.clear();
    _archiveCursorViewAt = null;
    _archiveCursorKey = null;
    _setCloudError(false);
    _setLocalSource(Pref.historyArchiveOnlyLocal);

    if (_localSource) {
      await _loadArchivePage(replace: true, resetShown: true);
      return;
    }

    final res = await UserHttp.historyList(
      type: type ?? 'all',
      account: account,
    );
    if (res case Success(:final response)) {
      if (type == null) {
        final tab = response.tab;
        if (tabs.isEmpty && tab != null && tab.isNotEmpty) {
          tabs.value = tab;
          tabController = TabController(length: tab.length + 1, vsync: this);
        }
      }
      final list = response.list;
      final mid = archiveMid;
      if (list == null || list.isEmpty) {
        max = viewAt = null;
        if (mid > 0 && HistoryArchive.stats(mid).total > 0) {
          // 云端暂无记录时用本地存档兜底
          _setCloudError(true);
          _setLocalSource(true);
          await _loadArchivePage(replace: true, resetShown: true);
        } else {
          isEnd = true;
          loadingState.value = const Success(<HistoryItemModel>[]);
        }
        return;
      }
      _recordCloudItems(list);
      _archiveUpsert(list);
      isEnd = false;
      loadingState.value = Success(list.toList());
    } else if (res is Error) {
      final mid = archiveMid;
      if (mid > 0 && HistoryArchive.stats(mid).total > 0) {
        _setCloudError(true);
        _setLocalSource(true);
        await _loadArchivePage(replace: true, resetShown: true);
        SmartDialog.showToast('云端加载失败，已显示本地存档');
      } else {
        loadingState.value = Error(res.errMsg, code: res.code);
      }
    }
  }

  // 加载更多
  Future<void> _loadMore() async {
    if (!_localSource) {
      final res = await UserHttp.historyList(
        type: type ?? 'all',
        max: max,
        viewAt: viewAt,
        account: account,
      );
      if (res case Success(:final response)) {
        final list = response.list;
        if (list == null || list.isEmpty) {
          // 云端已到底，无缝续接本地存档
          max = viewAt = null;
          if (archiveMid > 0) {
            _setLocalSource(true);
            await _loadArchivePage(replace: false);
          } else {
            isEnd = true;
          }
          return;
        }
        _recordCloudItems(list);
        _archiveUpsert(list);
        _appendItems(list);
        page++;
      } else if (res is Error) {
        SmartDialog.showToast(res.errMsg ?? '加载失败');
      }
      return;
    }
    await _loadArchivePage(replace: false);
  }

  void _recordCloudItems(List<HistoryItemModel> list) {
    final last = list.last;
    max = last.history.oid;
    viewAt = last.viewAt;
    for (final item in list) {
      final key = HistoryArchive.busKeyOf(item);
      if (key != null) _shownKeys.add(key);
    }
  }

  void _archiveUpsert(List<HistoryItemModel> list) {
    final mid = archiveMid;
    if (mid > 0) {
      HistoryArchive.upsertFromCloud(list, mid: mid);
    }
  }

  void _appendItems(List<HistoryItemModel> items) {
    if (items.isEmpty) return;
    final current = loadingState.value.dataOrNull;
    if (current == null) {
      loadingState.value = Success(List.of(items));
      return;
    }
    // 合并保持全局按 view_at 倒序（本地存档中的「官方已删除」条目
    // 可能比云端区块中最新条目还新，需要插入到正确位置）
    final merged = <HistoryItemModel>[];
    var i = 0;
    var j = 0;
    while (i < current.length && j < items.length) {
      final c = current[i];
      final n = items[j];
      if ((n.viewAt ?? 0) > (c.viewAt ?? 0)) {
        merged.add(n);
        j++;
      } else {
        merged.add(c);
        i++;
      }
    }
    while (i < current.length) {
      merged.add(current[i]);
      i++;
    }
    while (j < items.length) {
      merged.add(items[j]);
      j++;
    }
    current
      ..clear()
      ..addAll(merged);
    loadingState.refresh();
  }

  /// 读取本地存档（[replace] 为 true 时替换列表，否则追加）
  Future<void> _loadArchivePage({
    required bool replace,
    bool resetShown = false,
  }) async {
    final mid = archiveMid;
    if (mid <= 0) {
      if (replace) {
        loadingState.value = const Success(<HistoryItemModel>[]);
      }
      isEnd = true;
      return;
    }
    if (resetShown) _shownKeys.clear();
    final includeDeleted = Pref.historyArchiveShowDeleted;
    final bool Function(String? business)? filter;
    if (type == null) {
      filter = null;
    } else {
      final t = type!;
      filter = (String? business) {
        if (business == null) return false;
        if (business == t) return true;
        // 专栏类记录 business 可能为 'article-list' 等变体
        return t == 'article' && business.contains('article');
      };
    }
    final collected = <HistoryItemModel>[];
    var hasMore = false;
    // 循环读取，跳过已展示条目，直到取得至少一条可展示数据
    for (var guard = 0; guard < 500; guard++) {
      final res = HistoryArchive.page(
        mid: mid,
        beforeViewAt: _archiveCursorViewAt,
        beforeKey: _archiveCursorKey,
        includeDeleted: includeDeleted,
        filter: filter,
      );
      if (res.nextViewAt != null) {
        _archiveCursorViewAt = res.nextViewAt;
        _archiveCursorKey = res.nextKey;
      }
      for (final item in res.list) {
        final key = HistoryArchive.busKeyOf(item);
        if (key != null && _shownKeys.contains(key)) continue;
        if (key != null) _shownKeys.add(key);
        collected.add(item);
      }
      hasMore = res.hasMore;
      if (collected.isNotEmpty || !res.hasMore) break;
    }
    if (replace) {
      loadingState.value = Success(collected);
    } else if (collected.isNotEmpty) {
      _appendItems(collected);
    }
    if (!hasMore) isEnd = true;
  }

  // 观看历史暂停状态
  Future<void> historyStatus() async {
    final res = await UserHttp.historyStatus(account: account);
    if (res case Success(:final response)) {
      baseCtr.pauseStatus.value = response;
      GStorage.localCache.put(LocalCacheKey.historyPause, response);
    } else {
      res.toast();
    }
  }

  // 删除某条历史记录
  void delHistory(HistoryItemModel item) {
    if (item.deletedOnServer) {
      // 官方已删除的本地条目：直接从存档移除
      _removeLocalOnly({item});
      return;
    }
    _onDelete({item});
  }

  // 删除已看历史记录
  void onDelViewedHistory() {
    final viewedList = loadingState.value.dataOrNull
        ?.where((e) => e.progress == -1)
        .toSet();
    if (viewedList != null && viewedList.isNotEmpty) {
      _onDelete(viewedList);
    } else {
      SmartDialog.showToast('无已看记录');
    }
  }

  Future<void> _removeLocalOnly(Set<HistoryItemModel> removeList) async {
    final mid = archiveMid;
    if (mid <= 0) return;
    for (final item in removeList) {
      final busKey = HistoryArchive.busKeyOf(item);
      if (busKey != null) {
        await HistoryArchive.removeLocal(mid, busKey);
      }
    }
    afterDelete(removeList);
    SmartDialog.showToast('已从本地存档移除');
  }

  Future<void> _onDelete(Set<HistoryItemModel> removeList) async {
    // 「官方已删除」的条目无需再请求云端，直接从存档移除
    final localOnly = removeList.where((e) => e.deletedOnServer).toSet();
    final cloudList = removeList.where((e) => !e.deletedOnServer).toSet();
    if (localOnly.isNotEmpty) {
      await _removeLocalOnly(localOnly);
    }
    if (cloudList.isEmpty) return;

    SmartDialog.showLoading(msg: '请求中');
    final res = await UserHttp.delHistory(
      cloudList
          .map((item) => '${item.history.business}_${item.kid}')
          .join(','),
      account: account,
    );
    SmartDialog.dismiss();
    if (res.isSuccess) {
      final mid = archiveMid;
      if (mid > 0) {
        // 软删除：本地存档保留记录并标记「官方已删除」
        HistoryArchive.markDeletedItems(mid, cloudList);
      }
      afterDelete(cloudList);
      SmartDialog.showToast('已删除');
    } else {
      res.toast();
    }
  }

  // 删除选中的记录
  @override
  void onRemove() {
    showConfirmDialog(
      context: Get.context!,
      title: const Text('提示'),
      content: const Text('确认删除所选历史记录吗？'),
      onConfirm: () => _onDelete(allChecked.toSet()),
    );
  }

  // ============ 本地存档管理（菜单入口） ============

  /// 手动同步到本地存档
  Future<void> onSyncArchive() async {
    if (!archiveEnabled) {
      SmartDialog.showToast('未登录，无法归档观看历史');
      return;
    }
    SmartDialog.showLoading(msg: '正在同步观看历史...');
    final res = await HistoryArchiveSyncer.sync(account: account);
    SmartDialog.dismiss();
    final stats = HistoryArchive.stats(archiveMid);
    if (res.error != null) {
      SmartDialog.showToast(
        '同步中止：${res.error}（本次新归档 ${res.added} 条，共 ${stats.total} 条）',
      );
    } else if (res.deepPending) {
      // 云端更早期记录未扫完：再次点击同步可从断点继续深入
      SmartDialog.showToast(
        '已归档 ${res.added} 条，共 ${stats.total} 条；'
        '云端更早记录尚未扫完，再次点击「同步到本地存档」可继续深入',
      );
    } else {
      SmartDialog.showToast(
        '同步完成：新归档 ${res.added} 条，更新 ${res.updated} 条，共 ${stats.total} 条',
      );
    }
    onReload();
  }

  /// 校验云端删除状态
  Future<void> onVerifyArchive() async {
    if (!archiveEnabled) {
      SmartDialog.showToast('未登录，无法校验本地存档');
      return;
    }
    SmartDialog.showLoading(msg: '正在校验云端删除状态...');
    final res = await HistoryArchiveSyncer.verify(account: account);
    SmartDialog.dismiss();
    if (!res.completed) {
      SmartDialog.showToast('校验未完成：${res.error ?? '已取消'}');
      return;
    }
    SmartDialog.showToast(
      '校验完成：标记官方已删除 ${res.markedDeleted} 条，恢复 ${res.restored} 条',
    );
    onReload();
  }

  /// 清空本地存档
  void onClearArchive() {
    showConfirmDialog(
      context: Get.context!,
      title: const Text('提示'),
      content: const Text('确认清空本地存档吗？\n（仅清除本机永久存档，不影响 B 站云端观看历史）'),
      onConfirm: () async {
        final count = await HistoryArchive.clearMid(archiveMid);
        SmartDialog.showToast('已清空本地存档（$count 项）');
        onReload();
      },
    );
  }

  /// 切换「仅看本地存档」
  void toggleOnlyLocal() {
    Pref.historyArchiveOnlyLocal = !Pref.historyArchiveOnlyLocal;
    SmartDialog.showToast(
      Pref.historyArchiveOnlyLocal ? '已切换为「仅看本地存档」' : '已切换为「云端+本地存档」',
    );
    if (!Pref.historyArchiveOnlyLocal) _setCloudError(false);
    onReload();
  }

  /// 切换「显示官方已删除的记录」
  void toggleShowDeleted() {
    Pref.historyArchiveShowDeleted = !Pref.historyArchiveShowDeleted;
    SmartDialog.showToast(
      Pref.historyArchiveShowDeleted ? '已显示官方已删除的记录' : '已隐藏官方已删除的记录',
    );
    onReload();
  }

  @override
  List<HistoryItemModel>? getDataList(HistoryData response) {
    return response.list;
  }

  @override
  Future<LoadingState<HistoryData>> customGetData() => UserHttp.historyList(
    type: type ?? 'all',
    max: max,
    viewAt: viewAt,
    account: account,
  );

  @override
  void onClose() {
    tabController?.dispose();
    super.onClose();
  }

  @override
  Future<void> onReload() {
    scrollController.jumpToTop();
    return super.onReload();
  }
}