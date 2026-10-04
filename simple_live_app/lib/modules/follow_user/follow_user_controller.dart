// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_tag_picker.dart';
import 'package:simple_live_app/modules/follow_user/follow_order_dialog.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/follow_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  /// 0:全部 1:直播中 2:未直播
  var filterMode = FollowUserTag(id: "0", tag: "全部", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  // 用户自定义显示顺序 - default：watchDuration
  Rx<SortMethod> sortMethod = SortMethod.watchDuration.obs;

  // 排序方式
  var sortMap = {
    SortMethod.watchDuration: "观看时长",
    SortMethod.siteId: "直播平台",
    SortMethod.recently: "最近添加",
    SortMethod.userNameASC: "用户名A-Z",
    SortMethod.userNameDESC: "用户名Z-A",
    SortMethod.tag: "自定义标签",
    SortMethod.manual: "手动排序",
  };

  final selectionMode = false.obs;
  final selectedIds = <String>{}.obs;

  // 关注列表样式
  var followStyleMap = {true: "紧凑模式", false: "卡片模式"};

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream = FollowService.instance.updatedListStream.listen(
      (event) {
        updateTagList();
        filterData();
      },
    );

    sortMethod = AppSettingsController.instance.followSortMethod;
    super.onInit();
  }

  @override
  Future refreshData() async {
    await FollowService.instance.loadData();
    updateTagList();
    super.refreshData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    if (filterMode.value.id == "0") {
      return FollowService.instance.followList.value;
    } else if (filterMode.value.id == "1") {
      return FollowService.instance.liveList.value;
    } else if (filterMode.value.id == "2") {
      return FollowService.instance.notLiveList.value;
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      return FollowService.instance.curTagFollowList.value;
    }
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
    filterMode.value = tagList.firstWhereOrNull((tag) => tag.id == filterMode.value.id) ??
        tagList.firstWhereOrNull((tag) => tag.tag == filterMode.value.tag) ??
        tagList.first;
  }

  // 数据清洗：不关心中间 data_flow，最终由filterData决定显示数据
  void filterData() {
    bool hideOffline = AppSettingsController.instance.hideOfflineFollow.value;

    if (filterMode.value.id == "0") {
      list.assignAll(FollowService.instance.followList.value);
    } else if (filterMode.value.id == "1") {
      list.assignAll(FollowService.instance.liveList.value);
    } else if (filterMode.value.id == "2") {
      list.assignAll(FollowService.instance.notLiveList.value);
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      list.assignAll(FollowService.instance.curTagFollowList);
    }

    if (hideOffline && filterMode.value.id != "2") {
      list.retainWhere((user) => user.liveStatus.value == 2);
    }
    pageEmpty.value = list.isEmpty;
    selectedIds.retainAll(FollowService.instance.followList.map((follow) => follow.id));
  }

  // 用户自定义关注样式
  Future<void> showFollowStyleDialog() async {
    var res = await Utils.showMapOptionDialog(
      title: "关注样式切换",
      followStyleMap,
      AppSettingsController.instance.followStyleNotGrid.value,
    );
    if (res != null) {
      AppSettingsController.instance.setFollowStyleNotGrid(res);
    }
  }

  // 用户自定义顺序dialog
  Future<void> showSortDialog() async {
    var res = await Utils.showMapOptionDialog(sortMap, sortMethod.value, title: "排序方式");
    if (res != null) {
      sortMethod.value = res;
      AppSettingsController.instance.setFollowSortMethod(sortMethod.value);
      FollowService.instance.liveListSort();
      filterData();
    }
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  void removeFollow(FollowUser follow) async {
    var result = await Utils.showAlertDialog("确定要取消关注${follow.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    await FollowService.instance.removeFollowUser(follow.id);
    filterData();
  }

  Future<void> updateFollow(FollowUser follow) async {
    await FollowService.instance.addFollow(follow);
  }

  void startSelection([FollowUser? follow]) {
    selectedIds.clear();
    if (follow != null) selectedIds.add(follow.id);
    selectionMode.value = true;
  }

  void endSelection() {
    selectionMode.value = false;
    selectedIds.clear();
  }

  void toggleSelection(FollowUser follow) {
    if (!selectedIds.remove(follow.id)) selectedIds.add(follow.id);
  }

  void toggleSelectVisible() {
    final ids = list.map((follow) => follow.id).toSet();
    if (ids.every(selectedIds.contains)) {
      selectedIds.removeAll(ids);
    } else {
      selectedIds.addAll(ids);
    }
  }

  Future<void> batchTags({required bool remove}) async {
    final ids = selectedIds.toList();
    if (ids.isEmpty) return;
    final tags = await showFollowTagPicker(title: remove ? '移除标签' : '添加标签', allowCreate: !remove);
    if (tags == null || tags.isEmpty) return;
    await FollowService.instance.batchUpdateTags(
      ids,
      addTags: remove ? const [] : tags,
      removeTags: remove ? tags : const [],
    );
    filterData();
  }

  Future<void> setFollowTagDialog(FollowUser follow) async {
    final tags = await showFollowTagPicker(selectedTags: follow.tags);
    if (tags == null) return;
    await FollowService.instance.setFollowTags(follow, tags);
    filterData();
  }

  Future<void> showManualOrder() async {
    await showFollowOrderDialog();
    filterData();
  }

  void showBottomMenu(FollowUser item) {
    Get.bottomSheet(
      SafeArea(
        child: Wrap(
          children: [
            ListTile(
              key: const ValueKey('follow-action-tags'),
              leading: const Icon(Remix.price_tag_3_line),
              title: const Text('设置标签'),
              onTap: () {
                Get.back();
                setFollowTagDialog(item);
              },
            ),
            ListTile(
              key: const ValueKey('follow-action-pin'),
              leading: Icon(item.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(item.pinned ? '取消置顶' : '置顶'),
              onTap: () async {
                Get.back();
                await FollowService.instance.setPinned(item, !item.pinned);
                filterData();
              },
            ),
            ListTile(
              key: const ValueKey('follow-action-order'),
              leading: const Icon(Icons.reorder),
              title: const Text('手动排序'),
              onTap: () {
                Get.back();
                showManualOrder();
              },
            ),
            ListTile(
              key: const ValueKey('follow-action-select'),
              leading: const Icon(Icons.checklist),
              title: const Text('多选'),
              onTap: () {
                Get.back();
                startSelection(item);
              },
            ),
            ListTile(
              leading: const Icon(Remix.information_line),
              title: const Text('查看详情'),
              onTap: () {
                Get.back();
                AppNavigator.toFollowInfo(item);
              },
            ),
          ],
        ),
      ),
      backgroundColor: Get.theme.cardColor,
      isScrollControlled: true,
    );
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    super.onClose();
  }
}
