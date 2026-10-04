import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:fractional_indexing_dart/fractional_indexing_dart.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pinyin/pinyin.dart';
import 'package:pool/pool.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';
import 'package:simple_live_app/app/utils/dynamic_sort.dart';
import 'package:simple_live_app/app/utils/extensions/string_normalizer.dart';
import 'package:simple_live_app/models/db/follow_snapshot.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_sync.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:synchronized/synchronized.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;

  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();

  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 休眠用户列表
  RxList<FollowUser> dormantFollowList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 线程安全
  final _lock = Lock(reentrant: true);

  Future<T> withFollowWrite<T>(Future<T> Function() action) => _lock.synchronized(action);

  /// 已经更新状态的数量
  var updatedCount = 0;

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  int _refreshCycle = 0;

  bool _closed = false;
  int _totalToUpdate = 0;
  bool _snap = false;

  Future<void>? _initialization;
  Future<void> get ready => _initialization ??= _initialize();

  @override
  Future<void> onInit() {
    super.onInit();
    return ready;
  }

  Future<void> _initialize() async {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (data) {
      if (data is History) {
        updateFollowHistory(data);
      } else {
        loadData(updateStatus: false);
      }
    });
    await initFollowList();
    if (_closed) return;
    initTimer();
    cleanupTombstones();
  }

  Future<void> updateTagName(FollowUserTag followUserTag, String newTagName) => withFollowWrite(() async {
        final current = followTagList.firstWhereOrNull((tag) => tag.id == followUserTag.id);
        if (current == null) return;
        final names = FollowUser.normalizeTags([newTagName]);
        if (names.isEmpty || {'直播中', '未开播'}.contains(names.single) || names.single == current.tag) return;
        final name = names.single;
        if (followTagList.any((tag) => tag.tag == name && tag.id != current.id)) {
          SmartDialog.showToast('标签名重复');
          return;
        }
        var changedAt = _tagMetadataClock([current.tag, name]);
        for (final follow in followList.where((follow) => follow.tags.contains(current.tag)).toList()) {
          follow.replaceTags(follow.tags.map((tag) => tag == current.tag ? name : tag));
          follow.markMetadataChanged(after: changedAt);
          if (follow.metadataUpdatedAt > changedAt) changedAt = follow.metadataUpdatedAt;
          await DBService.instance.addFollow(follow);
        }
        final previousName = current.copyWith(
          id: DBService.instance.unusedFollowTagId(),
          deleted: true,
          userId: [],
        )..markChanged(after: changedAt);
        final renamed = current.copyWith(tag: name, updatedAt: previousName.updatedAt);
        // Keep the live ID stable for selected filters/queues; retain the old name
        // separately so stale sync peers cannot recreate it as an empty tag.
        await DBService.instance.updateFollowTag(previousName);
        await updateFollowUserTag(renamed);
        await _rebuildTagIndex();
        filterData();
      });

  Future<void> updateFollowUserTag(FollowUserTag tag) async {
    if (tag.tag == '全部') return;
    await DBService.instance.updateFollowTag(tag);
    final index = followTagList.indexWhere((oldTag) => oldTag.id == tag.id);
    if (index < 0) {
      followTagList.add(tag);
    } else {
      followTagList[index] = tag;
    }
  }

  Future<void> addFollowUserTag(String tag) => _lock.synchronized(() async {
        final names = FollowUser.normalizeTags([tag]);
        if (names.isEmpty || {'直播中', '未开播'}.contains(names.single)) return;
        if (followTagList.any((item) => item.tag == names.single)) {
          SmartDialog.showToast('标签名重复');
          return;
        }
        followTagList.add(await DBService.instance.addFollowTag(names.single));
        filterData();
      });

  Future<void> removeFollowUserTag(FollowUserTag tag) => withFollowWrite(() async {
        final current = followTagList.firstWhereOrNull((item) => item.id == tag.id);
        if (current == null) return;
        var changedAt = current.updatedAt;
        for (final follow in followList.where((follow) => follow.tags.contains(current.tag)).toList()) {
          follow.replaceTags(follow.tags.where((name) => name != current.tag));
          follow.markMetadataChanged();
          if (follow.metadataUpdatedAt > changedAt) changedAt = follow.metadataUpdatedAt;
          await DBService.instance.addFollow(follow);
        }
        await DBService.instance.deleteFollowTag(current.id, after: changedAt);
        getAllTagList();
        filterData();
      });

  void getAllTagList() {
    followTagList.assignAll(DBService.instance.getFollowTagList());
  }

  List<FollowUserTag> getTagOptionsWithAll() => [
        FollowUserTag(id: '0', tag: '全部', userId: []),
        ...followTagList,
      ];

  /// Compatibility API for callers that deliberately replace all memberships.
  Future<void> setFollowTag(FollowUser item, FollowUserTag targetTag) => setFollowTags(item, [targetTag.tag]);

  Future<void> setFollowTags(FollowUser item, Iterable<String> tags) => _lock.synchronized(() async {
        final current = followList.firstWhereOrNull((follow) => follow.id == item.id);
        if (current == null || current.deleted) return;
        final next = FollowUser.normalizeTags(tags);
        if (const ListEquality<String>().equals(current.tags, next)) return;
        await _ensureActiveTags(next.where((name) => !current.tags.contains(name)));
        current.replaceTags(next);
        current.markMetadataChanged(after: _tagMetadataClock(next));
        await DBService.instance.addFollow(current);
        await _rebuildTagIndex();
        filterData();
      });

  Future<void> batchUpdateTags(
    Iterable<String> ids, {
    Iterable<String> addTags = const [],
    Iterable<String> removeTags = const [],
  }) =>
      _lock.synchronized(() async {
        final selected = ids.toSet();
        final additions = FollowUser.normalizeTags(addTags);
        final removals = FollowUser.normalizeTags(removeTags).toSet();
        final items = followList.where((item) => selected.contains(item.id)).toList();
        if (items.isEmpty) return;
        await _ensureActiveTags(additions.where((name) => !removals.contains(name)));
        for (final item in items) {
          final next = FollowUser.normalizeTags([...item.tags, ...additions].where((tag) => !removals.contains(tag)));
          if (const ListEquality<String>().equals(item.tags, next)) continue;
          item.replaceTags(next);
          item.markMetadataChanged(after: _tagMetadataClock(next));
          await DBService.instance.addFollow(item);
        }
        await _rebuildTagIndex();
        filterData();
      });

  Future<void> setPinned(FollowUser item, bool pinned) => _lock.synchronized(() async {
        final current = followList.firstWhereOrNull((follow) => follow.id == item.id);
        if (current == null || current.pinned == pinned) return;
        current.pinned = pinned;
        current.markMetadataChanged();
        await DBService.instance.addFollow(current);
        filterData();
      });

  int _tagMetadataClock(Iterable<String> names) {
    final selected = names.toSet();
    return DBService.instance.getAllFollowTagList().where((tag) => selected.contains(tag.tag)).fold<int>(
          0,
          (time, tag) => tag.updatedAt > time ? tag.updatedAt : time,
        );
  }

  /// Only a deliberate tag edit can recreate a deleted definition. A pin/order
  /// update or a legacy import carrying an old membership cannot do so.
  Future<void> _ensureActiveTags(Iterable<String> names) async {
    for (final name in FollowUser.normalizeTags(names)) {
      await DBService.instance.addFollowTag(name);
    }
  }

  /// Move relative to one neighbor in the saved manual order.
  Future<void> moveFollow(FollowUser item, {FollowUser? before, FollowUser? after}) => _lock.synchronized(() async {
        if (before != null && after != null) throw ArgumentError('Choose before or after');
        final current = followList.firstWhereOrNull((follow) => follow.id == item.id);
        if (current == null || before?.id == current.id || after?.id == current.id) return;
        final settings = AppSettingsController.instance;
        await _ensureManualOrder(followList);
        final ordered = followList.where((follow) => follow.id != current.id).toList()
          ..sort((a, b) => a.manualOrder.compareTo(b.manualOrder));
        int index = ordered.length;
        if (before != null) {
          index = ordered.indexWhere((follow) => follow.id == before.id);
        } else if (after != null) {
          final previous = ordered.indexWhere((follow) => follow.id == after.id);
          if (previous < 0) return;
          index = previous + 1;
        }
        if (index < 0) return;
        current.manualOrder = FractionalIndexing.generateKeyBetween(
          index == 0 ? null : ordered[index - 1].manualOrder,
          index == ordered.length ? null : ordered[index].manualOrder,
        );
        current.markMetadataChanged();
        await DBService.instance.addFollow(current);
        settings.setFollowSortMethod(SortMethod.manual);
        filterData();
      });

  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.assignAll(followList.where((follow) => tag.tag == '全部' || follow.tags.contains(tag.tag)));
    listSortByMethod(curTagFollowList, AppSettingsController.instance.followSortMethod.value);
  }

  Future<void> updateFollowTagOrder(FollowUserTag oldTag, FollowUserTag newTag) => withFollowWrite(() async {
        final current = followTagList.firstWhereOrNull((tag) => tag.id == oldTag.id);
        if (current == null || current.id == newTag.id) return;
        final newId = DBService.instance.unusedFollowTagId(preferred: newTag.id);
        await DBService.instance.deleteFollowTag(oldTag.id);
        final tombstone = DBService.instance.tagBox.get(oldTag.id)!;
        final replacement = current.copyWith(id: newId, userId: List<String>.of(current.userId))
          ..markChanged(after: tombstone.updatedAt);
        await DBService.instance.updateFollowTag(replacement);
        final tags = [
          for (final tag in followTagList)
            if (tag.id == oldTag.id) replacement else tag,
        ]..sort((a, b) => a.id.compareTo(b.id));
        followTagList.assignAll(tags);
        filterData();
      });

  // Explicit follow action also restores a previously deleted entry.
  Future<void> addFollow(FollowUser follow) => _lock.synchronized(() async {
        follow.romanName = PinyinHelper.getShortPinyin(
          (follow.remark?.isNotEmpty ?? false) ? follow.remark! : follow.userName,
        ).normalize();
        follow.replaceTags(follow.tags);
        follow.deleted = false;
        follow.updateTime = 0;
        final index = followList.indexWhere((item) => item.id == follow.id);
        if (index >= 0) {
          if (!identical(followList[index], follow)) follow.applySnapshot(followList[index].toSnapshot());
          followList[index] = follow;
        } else {
          await _ensureActiveTags(follow.tags);
          followList.add(follow);
        }
        await _ensureManualOrder(followList);
        await DBService.instance.addFollow(follow);
        await _rebuildTagIndex();
        filterData();
      });

  Future<void> removeFollowUser(String id) => _lock.synchronized(() async {
        final follow = followList.firstWhereOrNull((item) => item.id == id);
        if (follow == null) return;
        follow.deleted = true;
        follow.updateTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        followList.removeWhere((item) => item.id == id);
        dormantFollowList.removeWhere((item) => item.id == id);
        await DBService.instance.addFollow(follow);
        await _rebuildTagIndex();
        filterData();
      });

  // 判断关注是否存在
  bool getFollowExist(String id) {
    return DBService.instance.getFollowExist(id);
  }

  // History changes cannot restore a follow deleted while waiting for a write.
  Future<void> updateFollowHistory(History history) => withFollowWrite(() async {
        final follow = followList.firstWhereOrNull((follow) => follow.id == history.id && !follow.deleted);
        if (follow == null) return;
        follow.syncDuration = history.syncDuration;
        follow.watchDuration = history.watchDuration;
        follow.watchDurationSec = (history.watchDuration ?? '00:00:00').toDuration().inSeconds;
        await DBService.instance.addFollow(follow);
        filterData();
      });

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      _refreshCycle = 0;
      updateTimer = Timer.periodic(
        Duration(minutes: AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          CoreLog.i("Update Follow Timer - Cycle: $_refreshCycle");
          loadData(updateStatus: true, cycle: _refreshCycle);
          _refreshCycle = (_refreshCycle + 1) % 2; // 2-cycle rotation
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  // 此操作只在初始化时调用一次
  Future<void> initFollowList() => withFollowWrite(() async {
        List<FollowUser> list = DBService.instance.getFollowList();
        // Very old releases stored membership only in the tag index. Recover it
        // before rebuilding that index, even when startup migration runs later.
        if (AppSettingsController.instance.dbVer <= 10709) {
          final legacyTags = DBService.instance.getFollowTagList();
          for (final follow in list) {
            final memberships = legacyTags.where((tag) => tag.userId.contains(follow.id)).map((tag) => tag.tag);
            follow.replaceTags([...follow.tags, ...memberships]);
            await DBService.instance.addFollow(follow);
          }
        }
        await _ensureManualOrder(list);
        getAllTagList();

        if (list.isEmpty) {
          updating.value = false;
          followList.assignAll(list);
          liveList.clear();
          notLiveList.clear();
          if (!_closed) _updatedListController.add(0);
          return;
        }
        var followSnapshot = AppSettingsController.instance.followSnapshot;
        bool followSnapshotEnable = AppSettingsController.instance.followSnapshotEnable.value;
        // whether to recover snapshot depends on expireAt
        if (followSnapshot != null &&
            followSnapshot.expireAt > DateTime.now().microsecondsSinceEpoch &&
            followSnapshotEnable) {
          final snapshotMap = {for (var item in followSnapshot.followSnapshotItems) item.id: item};
          for (var item in list) {
            final resItem = snapshotMap[item.id];
            if (resItem != null) {
              item.applySnapshot(resItem);
            }
          }
          _snap = true;
          Log.i("FollowService: follow-snapshot has recovered, expireAt: ${followSnapshot.expireAt}");
        }
        followList.assignAll(list);
        await _rebuildTagIndex();
        _buildDormantList();
        filterData();
      });

  /// 构建休眠用户列表
  void _buildDormantList() {
    final threshold = AppSettingsController.instance.dormancyThreshold.value;
    if (threshold <= 0) {
      dormantFollowList.clear();
      return;
    }
    final cutoff = DateTime.now().subtract(Duration(days: threshold)).millisecondsSinceEpoch ~/ 1000;
    dormantFollowList.assignAll(
      followList.where((u) => (u.lastWatchTime ?? 0) > 0 && u.lastWatchTime! < cutoff),
    );
  }

  /// 解冻：用户进入直播间时调用
  Future<void> resumeUser(String userId) => withFollowWrite(() async {
        final follow = followList.firstWhereOrNull((follow) => follow.id == userId && !follow.deleted);
        if (follow == null) return;
        follow.lastWatchTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await DBService.instance.addFollow(follow);
        dormantFollowList.removeWhere((item) => item.id == userId);
      });

  Future<void> loadData({bool updateStatus = true, int? cycle}) async {
    // snapshot 恢复跳过第一次状态更新
    if (_snap) {
      _snap = false;
      return;
    }
    if (updateStatus) {
      startUpdateStatus(cycle: cycle);
    } else {
      _updatedListController.add(0);
    }
  }

  void multiRoundPriority() {
    final historyList = DBService.instance.getHistories();
    final Map<String, int> historyRankMap = {for (var i = 0; i < historyList.length; i++) historyList[i].id: i};
    final int maxRank = historyList.isNotEmpty ? historyList.length : 1;

    Duration maxDuration = const Duration();
    for (var user in followList) {
      final duration = user.watchDuration!.toDuration();
      if (duration > maxDuration) {
        maxDuration = duration;
      }
    }
    final double maxDurationInSeconds = maxDuration.inSeconds > 0 ? maxDuration.inSeconds.toDouble() : 1.0;

    // 休眠用户 ID 集合
    final dormantIds = dormantFollowList.map((u) => u.id).toSet();

    // 简单线性加权组合算法，目前认定观看时长和最近观看时间权重一致
    // 如果用户历史行为序列非常长：可替换为时间衰减 + 观看时长加权
    followList.sort((a, b) {
      // 静态权重
      const double wDuration = 0.5;
      const double wRecency = 0.5;
      // 在线降权，离线增权
      const double wOnline = 0.3;
      const double wOffline = 1 - wOnline;

      // 动态权重
      double normDurationA = a.watchDurationSec.toDouble() / maxDurationInSeconds;
      int rankA = historyRankMap[a.id] ?? maxRank;
      double normRecencyA = (maxRank - rankA).toDouble() / maxRank;
      double wDormantA = dormantIds.contains(a.id) ? 0.0 : 1.0;
      double scoreA = ((wDuration * normDurationA) + (wRecency * normRecencyA)) *
          (a.liveStatus.value == 2 ? wOnline : wOffline) *
          wDormantA;

      double normDurationB = b.watchDurationSec.toDouble() / maxDurationInSeconds;
      int rankB = historyRankMap[b.id] ?? maxRank;
      double normRecencyB = (maxRank - rankB).toDouble() / maxRank;
      double wDormantB = dormantIds.contains(b.id) ? 0.0 : 1.0;
      double scoreB = ((wDuration * normDurationB) + (wRecency * normRecencyB)) *
          (b.liveStatus.value == 2 ? wOnline : wOffline) *
          wDormantB;

      return scoreB.compareTo(scoreA);
    });
  }

  void startUpdateStatus({int? cycle}) async {
    List<FollowUser> usersToUpdate;
    final totalUsers = followList.length;
    final douyinCount = followList.where((x) => x.siteId == 'douyin').length;

    //tips: 噪音用户画像（高风险平台：90%; 多次手刷; 单高关注数>50; 频繁切直播间; 不登录反复高危操作; 移动宽带用户; 反复关注取消; 多ip切换; 特殊地区风控; 多端在线请求; 黑号）
    if (cycle != null && (totalUsers > 100 || douyinCount > 50)) {
      // 简单28
      final topNCount = (totalUsers * 0.2).round(); // Top 20%
      final bottomNCount = (totalUsers * 0.2).round(); // Bottom 20%
      final middlePartEndIndex = totalUsers - bottomNCount;
      multiRoundPriority();
      final topNUsers = followList.sublist(0, topNCount);
      final middleUsers = followList.sublist(topNCount, middlePartEndIndex);
      if (cycle == 0) {
        usersToUpdate = topNUsers;
        CoreLog.i("Update Follow: Cycle 0, updating top ${usersToUpdate.length}/$totalUsers users.");
      } else {
        usersToUpdate = [...topNUsers, ...middleUsers];
        CoreLog.i("Update Follow: Cycle 1, updating top+middle ${usersToUpdate.length}/$totalUsers users.");
      }
    } else {
      usersToUpdate = List.from(followList);
      if (cycle != null) {
        CoreLog.i("Update Follow: List <= 100, updating all ${usersToUpdate.length} users.");
      }
    }
    _totalToUpdate = usersToUpdate.length;
    updatedCount = 0;
    updating.value = true;

    if (_totalToUpdate == 0) {
      updating.value = false;
      filterData();
      return;
    }

    var threadCount = AppSettingsController.instance.updateFollowThreadCount.value;

    var pool = Pool(threadCount);
    var tasks = <Future>[];

    for (var user in usersToUpdate) {
      tasks.add(pool.withResource(() => updateLiveInformation(user)));
    }
    await Future.wait(tasks);
    await pool.close();

    // 增量检查：自动解冻 lastWatchTime >= cutoff 的用户
    final threshold = AppSettingsController.instance.dormancyThreshold.value;
    if (threshold > 0 && dormantFollowList.isNotEmpty) {
      final cutoff = DateTime.now().subtract(Duration(days: threshold)).millisecondsSinceEpoch ~/ 1000;
      dormantFollowList.removeWhere((u) => u.lastWatchTime != null && u.lastWatchTime! >= cutoff);
    }

    // frequency of snapshot-saving and expireAt calculation depend on user-setting: auto-update
    final minutes = AppSettingsController.instance.autoUpdateFollowDuration.value;
    final expireAt = DateTime.now().add(Duration(minutes: minutes)).microsecondsSinceEpoch;
    AppSettingsController.instance.setFollowSnapshot(
      FollowSnapshot(
        expireAt: expireAt,
        followSnapshotItems: followList.map((e) => e.toSnapshot()).toList(),
      ),
    );
    Log.i("FollowService: follow-snapshot has saved, time: ${DateTime.now()}");
  }

  Future updateLiveInformation(FollowUser item) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      LiveRoomDetail detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
      item.liveStatus.value = detail.status ? 2 : 1;
      item.cover.value = detail.status ? detail.cover : "";
      item.title.value = detail.title;
      item.online.value = detail.online;
    } catch (e) {
      Log.logPrint(e);
    } finally {
      await _lock.synchronized(() {
        updatedCount++;
      });
      if (updatedCount >= _totalToUpdate) {
        filterData();
        updating.value = false;
      }
    }
  }

  void filterData() {
    liveListSort();
    if (!_closed) _updatedListController.add(0);
  }

  void liveListSort() {
    listSortByMethod(followList, AppSettingsController.instance.followSortMethod.value);
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
  }

  void listSortByMethod(List<FollowUser> list, SortMethod sortMethod) {
    var liveCondition = SortCondition<FollowUser>(
      valueGetter: (item) => item.liveStatus.value, // Rx<int>
      ascending: false,
    );
    var watchDurationCondition = SortCondition<FollowUser>(
      valueGetter: (item) => item.watchDurationSec,
      ascending: false,
    );
    var siteIdCondition = SortCondition<FollowUser>(
      valueGetter: (item) {
        final order = AppSettingsController.instance.siteSort;
        // 返回索引作为 Comparable
        return order.indexOf(item.siteId);
      },
    );
    var recentlyCondition = SortCondition<FollowUser>(
      valueGetter: (item) => item.addTime,
      ascending: false,
    );
    var userNameASCCondition = SortCondition<FollowUser>(
      valueGetter: (item) => item.romanName ?? "",
      ascending: true,
    );
    var userNameDESCCondition = SortCondition<FollowUser>(
      valueGetter: (item) => item.romanName ?? "",
      ascending: false,
    );
    final tagCondition = SortCondition<FollowUser>(
      valueGetter: (item) {
        final index = followTagList.indexWhere((tag) => item.tags.contains(tag.tag));
        return index < 0 ? followTagList.length : index;
      },
    );
    final pinnedCondition = SortCondition<FollowUser>(valueGetter: (item) => item.pinned ? 0 : 1);
    final manualCondition = SortCondition<FollowUser>(valueGetter: (item) => item.manualOrder);
    final stableCondition = SortCondition<FollowUser>(valueGetter: (item) => item.id);
    final methodConditions = switch (sortMethod) {
      SortMethod.watchDuration => [watchDurationCondition],
      SortMethod.siteId => [siteIdCondition, watchDurationCondition],
      SortMethod.recently => [recentlyCondition],
      SortMethod.userNameASC => [userNameASCCondition],
      SortMethod.userNameDESC => [userNameDESCCondition],
      SortMethod.tag => [tagCondition, watchDurationCondition],
      SortMethod.manual => [manualCondition],
    };
    final customFirst = AppSettingsController.instance.customOrderBeforeLive.value;
    list.dynamicSort([
      if (!customFirst) liveCondition,
      pinnedCondition,
      if (customFirst && sortMethod == SortMethod.manual) manualCondition,
      if (customFirst) liveCondition,
      ...methodConditions,
      stableCondition,
    ]);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File('$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    final records = followList.map((item) => item.toJson()).toList();
    if (records.isNotEmpty) {
      records.first['tagDefinitions'] = DBService.instance.getAllFollowTagList().map((tag) => tag.toJson()).toList();
    }
    return jsonEncode(records);
  }

  Future<void> inputJson(String content) async {
    await importSyncedFollows(jsonDecode(content));
  }

  /// Repair legacy records and imported indexes, then publish one consistent list.
  Future<void> followUserAllDataCheck() => withFollowWrite(() async {
        final previous = {for (final follow in followList) follow.id: follow};
        final follows = DBService.instance.getFollowList();
        await _ensureManualOrder(follows);
        for (final follow in follows) {
          follow.replaceTags(follow.tags);
          follow.romanName = PinyinHelper.getShortPinyin(
            (follow.remark?.isNotEmpty ?? false) ? follow.remark! : follow.userName,
          ).normalize();
          final old = previous[follow.id];
          if (old != null && !identical(old, follow)) {
            follow.applySnapshot(old.toSnapshot());
          }
        }
        await DBService.instance.followBox.putAll({for (final follow in follows) follow.id: follow});
        followList.assignAll(follows);
        await _rebuildTagIndex();
        _buildDormantList();
        filterData();
      });

  bool _validOrderKey(String key) {
    if (key.isEmpty || !RegExp(r'^[A-Za-z][0-9A-Za-z]+$').hasMatch(key)) return false;
    try {
      FractionalIndexing.validateOrderKey(key, FractionalIndexing.base62Digits);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureManualOrder(List<FollowUser> follows) async {
    final ordered = follows.toList()
      ..sort((a, b) {
        final validA = _validOrderKey(a.manualOrder);
        final validB = _validOrderKey(b.manualOrder);
        if (validA != validB) return validA ? -1 : 1;
        if (validA) {
          final key = a.manualOrder.compareTo(b.manualOrder);
          if (key != 0) return key;
        } else {
          final added = b.addTime.compareTo(a.addTime);
          if (added != 0) return added;
        }
        return a.id.compareTo(b.id);
      });
    String? lastKey;
    for (var i = 0; i < ordered.length; i++) {
      final follow = ordered[i];
      if (!_validOrderKey(follow.manualOrder) || (lastKey != null && follow.manualOrder.compareTo(lastKey) <= 0)) {
        String? nextKey;
        for (final next in ordered.skip(i + 1)) {
          if (_validOrderKey(next.manualOrder) && (lastKey == null || next.manualOrder.compareTo(lastKey) > 0)) {
            nextKey = next.manualOrder;
            break;
          }
        }
        follow.manualOrder = FractionalIndexing.generateKeyBetween(lastKey, nextKey);
        // Backfills do not compete with explicit metadata edits from another device.
        await DBService.instance.addFollow(follow);
      }
      lastKey = follow.manualOrder;
    }
  }

  /// Follow records own membership. Definitions retain their versions and
  /// tombstones so deleting/renaming an empty tag survives bidirectional sync.
  Future<void> _rebuildTagIndex() async {
    final existing = DBService.instance.getAllFollowTagList();
    final latestByName = <String, FollowUserTag>{};
    final records = <String, FollowUserTag>{};
    String? lastKey;
    for (final tag in existing) {
      if (_validOrderKey(tag.id) && (lastKey == null || tag.id.compareTo(lastKey) > 0)) lastKey = tag.id;
    }
    for (final old in existing) {
      final name = FollowUser.normalizeTags([old.tag]).firstOrNull;
      if (name == null) continue;
      var id = old.id;
      if (!_validOrderKey(id) || records.containsKey(id)) {
        id = FractionalIndexing.generateKeyBetween(lastKey, null);
        lastKey = id;
      }
      final tag = old.copyWith(id: id, tag: name, userId: []);
      records[id] = tag;
      final previous = latestByName[name];
      if (previous == null ||
          tag.updatedAt > previous.updatedAt ||
          (tag.updatedAt == previous.updatedAt && tag.deleted && !previous.deleted)) {
        latestByName[name] = tag;
      }
    }
    // Duplicate active definitions are index repairs, not user deletions. A
    // synthetic equal-time tombstone here would incorrectly beat the winner.
    records.removeWhere((id, tag) => !tag.deleted && !identical(latestByName[tag.tag], tag));
    for (final follow in followList.toList()) {
      final retained = <String>[];
      var metadataTime = follow.metadataUpdatedAt;
      for (final name in follow.tags) {
        var tag = latestByName[name];
        if (tag != null && tag.deleted) {
          if (tag.updatedAt > metadataTime) metadataTime = tag.updatedAt;
          continue;
        }
        if (tag == null) {
          lastKey = FractionalIndexing.generateKeyBetween(lastKey, null);
          tag = FollowUserTag(id: lastKey, tag: name, userId: [], updatedAt: follow.metadataUpdatedAt);
          records[tag.id] = tag;
          latestByName[name] = tag;
        }
        retained.add(name);
        tag.userId.add(follow.id);
      }
      if (!const ListEquality<String>().equals(retained, follow.tags)) {
        follow.replaceTags(retained);
        follow.metadataUpdatedAt = metadataTime;
        // The remote tag operation already has a clock. Preserve its authority
        // instead of inventing a new local edit while repairing an import.
        await DBService.instance.addFollow(follow);
      }
    }
    await DBService.instance.tagBox.putAll(records);
    await DBService.instance.tagBox.deleteAll(
      DBService.instance.tagBox.keys.where((key) => !records.containsKey(key)).toList(),
    );
    getAllTagList();
  }

  /// 清理墓碑记录：删除 updateTime 超过15天的墓碑
  Future<void> cleanupTombstones() async {
    // 墓碑保留15天 = 15 * 24 * 60 * 60 秒
    const int tombstoneTTL = 15 * 24 * 60 * 60;
    final beforeTimestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - tombstoneTTL;
    final count = await DBService.instance.cleanupTombstones(beforeTimestamp);
    if (count > 0) {
      Log.i("Follow-Service: cleaned $count tombstone records");
    }
  }

  @override
  void onClose() {
    _closed = true;
    updateTimer?.cancel();
    subscription?.cancel();
    _updatedListController.close();
    super.onClose();
  }
}
