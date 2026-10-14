import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models_new/history/data.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:hive_ce/hive.dart';

/// 本地观看历史永久存档。
///
/// 数据存放在独立的 `historyArchive` box 中：
/// - 不随「清除缓存」清除，也不会被「重置所有数据」清空（避免误操作丢失
///   多年记录）；如需清空请使用历史页菜单中的「清空本地存档」。
/// - 按账号 mid 隔离，条目 key 为 `{mid}/{business}_{kid}`（与官方删除
///   接口使用的 `{business}_{kid}` 保持一致）。
/// - 官方删除采用软删除：条目保留并标记 `deleted`，默认隐藏，可切换显示。
///
/// 注意：B 站接口只能返回云端当前可见的记录（约近 3 个月/有限条数），
/// 因此首次同步只能从「当前可见范围」开始归档，此前已过期的记录无法
/// 找回；之后不会再丢失任何一条记录。
abstract final class HistoryArchive {
  static const int schemaVersion = 1;

  static Box<dynamic> get _box => GStorage.historyArchive;

  static int? _indexMid;
  static List<_ArchiveIndexEntry>? _index;

  /// 账号是否可用于归档（已登录且 mid 有效）
  static bool isEnabled(Account account) {
    try {
      return account.isLogin && account.mid > 0;
    } catch (_) {
      return false;
    }
  }

  /// 安全获取账号 mid（未登录或不可用时返回 0）
  static int midOf(Account account) {
    try {
      return account.isLogin ? account.mid : 0;
    } catch (_) {
      return 0;
    }
  }

  static void _invalidateIndex() {
    _indexMid = null;
    _index = null;
  }

  static String _keyOf(int mid, String busKey) => '$mid/$busKey';

  static String _metaKey(int mid) => '~meta/$mid';

  /// 条目在官方接口中的唯一标识（与删除接口一致）：`{business}_{kid}`
  static String? busKeyOf(HistoryItemModel item) {
    final business = item.history.business;
    if (business == null || business.isEmpty) return null;
    final kid = item.kid;
    if (kid != null && kid != 0) return '${business}_$kid';
    final oid = item.history.oid;
    if (oid == null) return null;
    final page = item.history.page;
    return '${business}_oid$oid${page == null || page <= 0 ? '' : '_p$page'}';
  }

  static Map<String, dynamic> _encodeItem(HistoryItemModel item) => {
    'title': item.title,
    'cover': item.cover,
    'covers': item.covers,
    'uri': item.uri,
    'history': {
      'oid': item.history.oid,
      'epid': item.history.epid,
      'bvid': item.history.bvid,
      'page': item.history.page,
      'cid': item.history.cid,
      'business': item.history.business,
    },
    'videos': item.videos,
    'author_name': item.authorName,
    'author_mid': item.authorMid,
    'view_at': item.viewAt,
    'progress': item.progress,
    'badge': item.badge,
    'show_title': item.showTitle,
    'duration': item.duration,
    'is_fav': item.isFav,
    'kid': item.kid,
    'tag_name': item.tagName,
    'live_status': item.liveStatus,
  };

  static HistoryItemModel? _decodeItem(dynamic data) {
    if (data is! Map) return null;
    try {
      // Hive 读出的嵌套 Map 为 Map<dynamic, dynamic>，
      // 需要深度转换为 Map<String, dynamic> 才能安全交给 fromJson。
      final plain = _toPlain(data);
      return HistoryItemModel.fromJson(plain as Map<String, dynamic>);
    } catch (e) {
      if (kDebugMode) debugPrint('history archive decode error: $e');
      return null;
    }
  }

  /// 将 Hive 读出的值深度转换为普通 Dart 容器
  /// （Map -> Map<String, dynamic>，List -> List<dynamic>）。
  static dynamic _toPlain(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = _toPlain(entry.value);
      }
      return result;
    }
    if (value is List) {
      return [for (final e in value) _toPlain(e)];
    }
    return value;
  }

  static List<_ArchiveIndexEntry> _ensureIndex(int mid) {
    final cached = _index;
    if (cached != null && _indexMid == mid) return cached;
    final prefix = '$mid/';
    final entries = <_ArchiveIndexEntry>[];
    for (final key in _box.keys) {
      if (key is! String || !key.startsWith(prefix)) continue;
      final value = _box.get(key);
      if (value is! Map) continue;
      final viewAt = value['viewAt'];
      entries.add(
        _ArchiveIndexEntry(
          key: key,
          viewAt: viewAt is int ? viewAt : 0,
          deleted: value['deleted'] == true,
        ),
      );
    }
    entries.sort((a, b) {
      final byTime = b.viewAt.compareTo(a.viewAt);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    _indexMid = mid;
    _index = entries;
    return entries;
  }

  /// 云端数据入库（新增/更新，并清除「官方已删除」标记）
  ///
  /// 返回 `(added, updated)`。
  static ({int added, int updated}) upsertFromCloud(
    Iterable<HistoryItemModel> items, {
    required int mid,
  }) {
    if (mid <= 0) return (added: 0, updated: 0);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var added = 0;
    var updated = 0;
    for (final item in items) {
      final busKey = busKeyOf(item);
      if (busKey == null) continue;
      final key = _keyOf(mid, busKey);
      final value = _box.get(key);
      final encoded = _encodeItem(item);
      if (value is Map) {
        final oldData = value['data'];
        final changed =
            value['viewAt'] != item.viewAt ||
            (oldData is Map && oldData['progress'] != item.progress) ||
            value['deleted'] == true;
        if (changed) {
          updated++;
          _box.put(key, {
            ...value.cast<String, dynamic>(),
            'busKey': busKey,
            'data': encoded,
            'viewAt': item.viewAt,
            'lastSeenAt': now,
            'deleted': false,
            'deletedAt': null,
          });
        }
      } else {
        added++;
        _box.put(key, {
          'v': schemaVersion,
          'mid': mid,
          'busKey': busKey,
          'viewAt': item.viewAt,
          'firstSeenAt': now,
          'lastSeenAt': now,
          'deleted': false,
          'deletedAt': null,
          'data': encoded,
        });
      }
    }
    if (added > 0 || updated > 0) _invalidateIndex();
    return (added: added, updated: updated);
  }

  /// 将条目标记为「官方已删除」（软删除）
  static int markDeletedItems(int mid, Iterable<HistoryItemModel> items) {
    if (mid <= 0) return 0;
    final keys = <String>[];
    for (final item in items) {
      final busKey = busKeyOf(item);
      if (busKey != null) keys.add(busKey);
    }
    return markDeletedByBusKeys(mid, keys);
  }

  /// 按 `{business}_{kid}` 标记软删除
  static int markDeletedByBusKeys(int mid, Iterable<String> busKeys) {
    if (mid <= 0) return 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var marked = 0;
    for (final busKey in busKeys) {
      final key = _keyOf(mid, busKey);
      final value = _box.get(key);
      if (value is Map && value['deleted'] != true) {
        _box.put(key, {
          ...value.cast<String, dynamic>(),
          'deleted': true,
          'deletedAt': now,
        });
        marked++;
      }
    }
    if (marked > 0) _invalidateIndex();
    return marked;
  }

  /// 按官方删除接口删除记录时调用
  static int markDeletedByKid(int mid, String business, int kid) =>
      markDeletedByBusKeys(mid, ['${business}_$kid']);

  /// 清空云端历史后，把整个账号的存档条目全部标记为「官方已删除」
  static int markAllDeleted(int mid) {
    if (mid <= 0) return 0;
    final index = _ensureIndex(mid);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var marked = 0;
    for (final entry in index) {
      if (entry.deleted) continue;
      final value = _box.get(entry.key);
      if (value is Map) {
        _box.put(entry.key, {
          ...value.cast<String, dynamic>(),
          'deleted': true,
          'deletedAt': now,
        });
        marked++;
      }
    }
    if (marked > 0) _invalidateIndex();
    return marked;
  }

  /// 分页读取存档（按 view_at 倒序；相同时间按 key 升序稳定排序）
  ///
  /// [beforeViewAt]/[beforeKey] 组成分页游标，表示「已读到的最后一条」；
  /// 返回中 [nextViewAt]/[nextKey] 为「本页已消费的最后一条」的位置
  /// （无论是否命中过滤），用于下一页游标；[hasMore] 表示是否还有更多。
  static ({
    List<HistoryItemModel> list,
    bool hasMore,
    int? nextViewAt,
    String? nextKey,
  })
  page({
    required int mid,
    int? beforeViewAt,
    String? beforeKey,
    int limit = 20,
    bool includeDeleted = false,
    bool Function(String? business)? filter,
  }) {
    if (mid <= 0) {
      return (
        list: <HistoryItemModel>[],
        hasMore: false,
        nextViewAt: null,
        nextKey: null,
      );
    }
    final index = _ensureIndex(mid);
    final list = <HistoryItemModel>[];
    var hasMore = false;
    int? nextViewAt;
    String? nextKey;
    // 二分定位游标起点（索引已按 viewAt 降序、key 升序排序），
    // 避免深翻页时从头部重复扫描已消费区域。
    var start = 0;
    if (beforeViewAt != null) {
      var lo = 0;
      var hi = index.length;
      while (lo < hi) {
        final midIndex = (lo + hi) >> 1;
        final e = index[midIndex];
        final before =
            e.viewAt > beforeViewAt ||
            (e.viewAt == beforeViewAt &&
                beforeKey != null &&
                e.key.compareTo(beforeKey) <= 0);
        if (before) {
          lo = midIndex + 1;
        } else {
          hi = midIndex;
        }
      }
      start = lo;
    }
    for (var i = start; i < index.length; i++) {
      final entry = index[i];
      if (!includeDeleted && entry.deleted) {
        nextViewAt = entry.viewAt;
        nextKey = entry.key;
        continue;
      }
      final value = _box.get(entry.key);
      if (value is! Map) {
        nextViewAt = entry.viewAt;
        nextKey = entry.key;
        continue;
      }
      final item = _decodeItem(value['data']);
      if (item == null || (filter != null && !filter(item.history.business))) {
        nextViewAt = entry.viewAt;
        nextKey = entry.key;
        continue;
      }
      if (list.length >= limit) {
        hasMore = true;
        break;
      }
      item.deletedOnServer = entry.deleted;
      list.add(item);
      nextViewAt = entry.viewAt;
      nextKey = entry.key;
    }
    return (
      list: list,
      hasMore: hasMore,
      nextViewAt: nextViewAt,
      nextKey: nextKey,
    );
  }

  /// 存档统计
  static ({int total, int deleted, int? earliest, int? latest}) stats(int mid) {
    if (mid <= 0) {
      return (total: 0, deleted: 0, earliest: null, latest: null);
    }
    final index = _ensureIndex(mid);
    var deleted = 0;
    int? earliest;
    int? latest;
    for (final entry in index) {
      if (entry.deleted) deleted++;
      if (entry.viewAt > 0) {
        latest ??= entry.viewAt;
        earliest = entry.viewAt;
      }
    }
    return (
      total: index.length,
      deleted: deleted,
      earliest: earliest,
      latest: latest,
    );
  }

  /// 上次同步时间（秒级时间戳）
  static int? lastSyncAt(int mid) {
    final value = _box.get(_metaKey(mid));
    if (value is Map) {
      final lastSyncAt = value['lastSyncAt'];
      if (lastSyncAt is int) return lastSyncAt;
    }
    return null;
  }

  static void saveSyncMeta(
    int mid, {
    required int lastSyncAt,
    required int total,
    required bool completed,
    bool? deepPending,
    bool? deepDone,
    int? deepMax,
    int? deepViewAt,
  }) {
    if (mid <= 0) return;
    final old = _box.get(_metaKey(mid));
    final map = <String, dynamic>{
      if (old is Map) ...old.cast<String, dynamic>(),
      'lastSyncAt': lastSyncAt,
      'total': total,
      'completed': completed,
      if (deepPending != null) 'deepPending': deepPending,
      if (deepDone != null) 'deepDone': deepDone,
      if (deepMax != null) 'deepMax': deepMax,
      if (deepViewAt != null) 'deepViewAt': deepViewAt,
    };
    _box.put(_metaKey(mid), map);
  }

  /// 深扫断点：云端更早期尚未被扫描归档的区域游标。
  ///
  /// [pending] 为 true 表示存档尚未覆盖到云端可见范围的最深处，
  /// 下次同步会从 [max]/[viewAt] 游标继续向下深入归档；
  /// [done] 为 true 表示历史上至少完整遍历过一次云端可见范围。
  static ({bool pending, bool done, int max, int viewAt}) deepCursor(int mid) {
    final value = _box.get(_metaKey(mid));
    if (value is Map) {
      final pending = value['deepPending'] == true;
      final done = value['deepDone'] == true;
      final max = value['deepMax'];
      final viewAt = value['deepViewAt'];
      return (
        pending: pending,
        done: done,
        max: max is int ? max : 0,
        viewAt: viewAt is int ? viewAt : 0,
      );
    }
    return (pending: false, done: false, max: 0, viewAt: 0);
  }

  /// 清空某账号的全部本地存档（含同步元信息）
  static Future<int> clearMid(int mid) async {
    if (mid <= 0) return 0;
    final prefix = '$mid/';
    final metaKey = _metaKey(mid);
    final keys = <dynamic>[];
    for (final key in _box.keys) {
      if (key is String && (key.startsWith(prefix) || key == metaKey)) {
        keys.add(key);
      }
    }
    await _box.deleteAll(keys);
    _invalidateIndex();
    return keys.length;
  }

  /// 读取某条目的原始存档数据（用于校验）
  static Map<dynamic, dynamic>? rawOf(int mid, String busKey) {
    final value = _box.get(_keyOf(mid, busKey));
    return value is Map ? value : null;
  }

  /// 从本地存档中彻底移除某条目（用于「官方已删除」条目的本地清理）
  static Future<void> removeLocal(int mid, String busKey) async {
    if (mid <= 0) return;
    await _box.delete(_keyOf(mid, busKey));
    _invalidateIndex();
  }

  static void invalidateIndex() => _invalidateIndex();
}

/// 同步结果
class HistoryArchiveSyncResult {
  const HistoryArchiveSyncResult({
    required this.scannedPages,
    required this.added,
    required this.updated,
    required this.completed,
    this.deepPending = false,
    this.error,
  });

  /// 已扫描页数
  final int scannedPages;

  /// 新增条数
  final int added;

  /// 更新条数
  final int updated;

  /// 是否完整遍历到云端尽头（false 表示增量提前结束或中途中断）
  final bool completed;

  /// 云端更早期的记录尚未扫描完，下次同步会从断点继续深入
  final bool deepPending;

  /// 错误信息（null 表示无错误）
  final String? error;
}

/// 云端删除状态校验结果
class HistoryArchiveVerifyResult {
  const HistoryArchiveVerifyResult({
    required this.scannedPages,
    required this.markedDeleted,
    required this.restored,
    required this.completed,
    this.error,
  });

  final int scannedPages;
  final int markedDeleted;
  final int restored;
  final bool completed;
  final String? error;
}

/// 观看历史归档引擎
///
/// 以 `max/view_at` 游标分页拉取云端全部可见记录并增量入库；
/// 增量模式在连续多页记录均为「未变化的旧记录」时提前结束。
abstract final class HistoryArchiveSyncer {
  static const int _pageGapMs = 400;
  static const int _maxPages = 500;

  /// 单次同步的最长运行时间（毫秒）；未扫完会保留断点，下次自动续扫。
  static const int _maxRunMs = 100000;

  static const int _verifyMaxPages = 1000;

  /// 单次「校验云端删除状态」的最长运行时间（毫秒）。
  static const int _verifyMaxRunMs = 120000;

  static const int _knownStreakThreshold = 60;

  static Future<HistoryArchiveSyncResult>? _running;

  static bool get isSyncing => _running != null;

  /// 增量/全量同步（并发调用会复用同一任务）
  static Future<HistoryArchiveSyncResult> sync({
    required Account account,
    bool full = false,
    void Function(int scannedPages, int processed, int added)? onProgress,
  }) {
    final running = _running;
    if (running != null) return running;
    late final Future<HistoryArchiveSyncResult> task;
    task = _doSync(
      account: account,
      full: full,
      onProgress: onProgress,
    ).whenComplete(() {
      if (identical(_running, task)) _running = null;
    });
    _running = task;
    return task;
  }

  static String _errorMessage(LoadingState<HistoryData> res) =>
      res is Error ? (res.errMsg ?? '网络错误') : '未知错误';

  static Future<HistoryArchiveSyncResult> _doSync({
    required Account account,
    required bool full,
    void Function(int scannedPages, int processed, int added)? onProgress,
  }) async {
    final mid = HistoryArchive.midOf(account);
    if (mid <= 0) {
      return const HistoryArchiveSyncResult(
        scannedPages: 0,
        added: 0,
        updated: 0,
        completed: false,
        error: '未登录',
      );
    }

    var max = 0;
    var viewAt = 0;
    var scanned = 0;
    var added = 0;
    var updated = 0;
    var knownStreak = 0;
    var completed = false;
    var knownStreakStop = false;
    String? error;
    final startMs = DateTime.now().millisecondsSinceEpoch;

    final priorDeep = HistoryArchive.deepCursor(mid);

    // ---- 阶段一：从最新记录向下扫描，快速归档新增/变更记录 ----
    try {
      while (scanned < _maxPages) {
        final res = await UserHttp.historyList(
          type: 'all',
          max: max,
          viewAt: viewAt,
          account: account,
        );
        if (res case Success(:final response)) {
          final list = response.list;
          if (list == null || list.isEmpty) {
            completed = true;
            break;
          }
          scanned++;

          // 统计「未变化旧记录」数量（入库前判断）
          var known = 0;
          for (final item in list) {
            final busKey = HistoryArchive.busKeyOf(item);
            if (busKey == null) continue;
            final value = HistoryArchive.rawOf(mid, busKey);
            if (value != null) {
              final data = value['data'];
              final same =
                  value['viewAt'] == item.viewAt &&
                  (data is! Map || data['progress'] == item.progress);
              if (same) known++;
            }
          }

          final res2 = HistoryArchive.upsertFromCloud(list, mid: mid);
          added += res2.added;
          updated += res2.updated;
          knownStreak = known == list.length && list.isNotEmpty
              ? knownStreak + list.length
              : 0;
          onProgress?.call(scanned, added + updated, added);

          final last = list.last;
          max = last.history.oid ?? 0;
          viewAt = last.viewAt ?? 0;
          if (list.length < 20) {
            completed = true;
            break;
          }
          if (viewAt == 0 && max == 0) {
            break; // 游标无进展，防御性中断
          }
          if (!full && knownStreak >= _knownStreakThreshold) {
            // 已进入「全部为旧记录」区域，增量扫描结束
            knownStreakStop = true;
            break;
          }
          if (DateTime.now().millisecondsSinceEpoch - startMs >= _maxRunMs) {
            break; // 本次运行时间耗尽，保留断点供下次续扫
          }
          await Future.delayed(const Duration(milliseconds: _pageGapMs));
        } else {
          error = _errorMessage(res);
          break;
        }
      }
    } catch (e) {
      error = e.toString();
    }

    // ---- 阶段二：深扫续传（继续向云端更深处归档尚未覆盖的记录） ----
    //
    // 当阶段一因「已知记录」提前结束时（增量稳态），若存在上次保留的
    // 深扫断点，则从断点继续；否则从阶段一自身到达的游标继续。
    if (!completed && error == null) {
      if (knownStreakStop) {
        if (priorDeep.pending) {
          max = priorDeep.max;
          viewAt = priorDeep.viewAt;
        } else {
          max = 0;
          viewAt = 0;
        }
      }
      if ((max != 0 || viewAt != 0) && scanned < _maxPages) {
        try {
          while (scanned < _maxPages) {
            final res = await UserHttp.historyList(
              type: 'all',
              max: max,
              viewAt: viewAt,
              account: account,
            );
            if (res case Success(:final response)) {
              final list = response.list;
              if (list == null || list.isEmpty) {
                completed = true;
                break;
              }
              scanned++;
              final res2 = HistoryArchive.upsertFromCloud(list, mid: mid);
              added += res2.added;
              updated += res2.updated;
              onProgress?.call(scanned, added + updated, added);

              final last = list.last;
              max = last.history.oid ?? 0;
              viewAt = last.viewAt ?? 0;
              if (list.length < 20) {
                completed = true;
                break;
              }
              if (viewAt == 0 && max == 0) break;
              if (DateTime.now().millisecondsSinceEpoch - startMs >=
                  _maxRunMs) {
                break; // 时间耗尽，保留断点
              }
              await Future.delayed(const Duration(milliseconds: _pageGapMs));
            } else {
              error = _errorMessage(res);
              break;
            }
          }
        } catch (e) {
          error ??= e.toString();
        }
      }
    }

    // ---- 断点状态判定 ----
    var deepPending = false;
    var deepMax = 0;
    var deepViewAt = 0;
    var deepDone = priorDeep.done;
    if (completed) {
      // 已完整遍历云端可见范围
      deepDone = true;
    } else if (max != 0 || viewAt != 0) {
      if (knownStreakStop && priorDeep.done && !priorDeep.pending) {
        // 增量稳态且此前已完整覆盖：无需深扫
        deepPending = false;
      } else {
        // 尚未覆盖云端最深处（或上次断点未完成/中断）：保留断点供下次续扫
        deepPending = true;
        deepMax = max;
        deepViewAt = viewAt;
      }
    }

    final stats = HistoryArchive.stats(mid);
    HistoryArchive.saveSyncMeta(
      mid,
      lastSyncAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      total: stats.total,
      completed: completed,
      deepPending: deepPending,
      deepDone: deepDone,
      deepMax: deepMax,
      deepViewAt: deepViewAt,
    );
    return HistoryArchiveSyncResult(
      scannedPages: scanned,
      added: added,
      updated: updated,
      completed: completed,
      deepPending: deepPending,
      error: error,
    );
  }

  /// 校验云端删除状态：完整遍历云端记录，把本地存档中「云端已不存在」
  /// 的条目标记为「官方已删除」，重新出现的条目恢复显示。
  ///
  /// 仅当完整遍历成功时才执行标记，避免误标记。
  static Future<HistoryArchiveVerifyResult> verify({
    required Account account,
    void Function(int scannedPages, int marked)? onProgress,
  }) async {
    final mid = HistoryArchive.midOf(account);
    if (mid <= 0) {
      return const HistoryArchiveVerifyResult(
        scannedPages: 0,
        markedDeleted: 0,
        restored: 0,
        completed: false,
        error: '未登录',
      );
    }

    final serverKeys = <String>{};
    var max = 0;
    var viewAt = 0;
    var scanned = 0;
    var completed = false;
    String? error;
    final startMs = DateTime.now().millisecondsSinceEpoch;

    try {
      while (scanned < _verifyMaxPages) {
        final res = await UserHttp.historyList(
          type: 'all',
          max: max,
          viewAt: viewAt,
          account: account,
        );
        if (res case Success(:final response)) {
          final list = response.list;
          if (list == null || list.isEmpty) {
            completed = true;
            break;
          }
          scanned++;
          for (final item in list) {
            final busKey = HistoryArchive.busKeyOf(item);
            if (busKey != null) serverKeys.add(busKey);
          }
          onProgress?.call(scanned, serverKeys.length);
          final last = list.last;
          max = last.history.oid ?? 0;
          viewAt = last.viewAt ?? 0;
          if (list.length < 20) {
            completed = true;
            break;
          }
          if (viewAt == 0 && max == 0) break;
          if (DateTime.now().millisecondsSinceEpoch - startMs >=
              _verifyMaxRunMs) {
            error = '校验超时';
            break;
          }
          await Future.delayed(const Duration(milliseconds: _pageGapMs));
        } else {
          error = _errorMessage(res);
          break;
        }
      }
    } catch (e) {
      error = e.toString();
    }

    var marked = 0;
    var restored = 0;
    if (completed) {
      final index = HistoryArchive._ensureIndex(mid);
      for (final entry in index) {
        final value = HistoryArchive.rawOf(mid, _busKeyFromKey(entry.key));
        if (value == null) continue;
        final busKey = value['busKey'];
        if (busKey is! String) continue;
        final onServer = serverKeys.contains(busKey);
        final wasDeleted = value['deleted'] == true;
        if (!onServer && !wasDeleted) {
          HistoryArchive.markDeletedByBusKeys(mid, [busKey]);
          marked++;
        } else if (onServer && wasDeleted) {
          HistoryArchive._box.put(entry.key, {
            ...value.cast<String, dynamic>(),
            'deleted': false,
            'deletedAt': null,
          });
          restored++;
        }
      }
      if (marked > 0 || restored > 0) HistoryArchive.invalidateIndex();
    }

    return HistoryArchiveVerifyResult(
      scannedPages: scanned,
      markedDeleted: marked,
      restored: restored,
      completed: completed,
      error: error,
    );
  }

  static String _busKeyFromKey(String key) {
    final index = key.indexOf('/');
    return index == -1 ? key : key.substring(index + 1);
  }
}

class _ArchiveIndexEntry {
  const _ArchiveIndexEntry({
    required this.key,
    required this.viewAt,
    required this.deleted,
  });

  final String key;
  final int viewAt;
  final bool deleted;
}