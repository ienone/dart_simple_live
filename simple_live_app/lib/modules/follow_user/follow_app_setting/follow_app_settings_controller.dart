import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:fractional_indexing_dart/fractional_indexing_dart.dart';
import 'package:get/get.dart' hide Condition;
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';
import 'package:simple_live_app/app/utils/dynamic_filter.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/history_service.dart';

class FollowAppSettingsController extends BaseController {
  final appC = Get.find<AppSettingsController>();

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;
  final _savingTagOrder = false.obs;

  // 用户自定义条件
  Rx<int> takeLast = 15.obs;
  Rx<int> minutes = 30.obs;

  @override
  void onInit() {
    updateTagList();
    super.onInit();
  }

  // 修改用户自定义关注设置
  void setFollowSetting(bool hideOfflineFollow) {
    appC.setHideOfflineFollow(hideOfflineFollow);
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
  }

  // 修改隐藏快速取关按钮
  void setRemoveFollowButton(bool hideFollowCardRemoveButton) {
    appC.setHideRemoveFollowButton(hideFollowCardRemoveButton);
  }

  // 标签管理
  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    // 修改tag 通知 follo_user_controller 数据更新
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
  }

  Future removeTag(FollowUserTag tag) async {
    await FollowService.instance.removeFollowUserTag(tag);
    updateTagList();
    Log.i('删除tag${tag.tag}');
  }

  Future<void> updateTagOrder(int oldIndex, int newIndex) async {
    if (_savingTagOrder.value ||
        oldIndex == newIndex ||
        oldIndex < 0 ||
        oldIndex >= userTagList.length ||
        newIndex < 0 ||
        newIndex >= userTagList.length) {
      return;
    }
    _savingTagOrder.value = true;
    try {
      final reordered = userTagList.toList();
      final item = reordered.removeAt(oldIndex);
      final newTagKey = FractionalIndexing.generateKeyBetween(
        newIndex > 0 ? reordered[newIndex - 1].id : null,
        newIndex < reordered.length ? reordered[newIndex].id : null,
      );
      final newTag = FollowUserTag(id: newTagKey, tag: item.tag, userId: item.userId);
      reordered.insert(newIndex, item);
      userTagList.assignAll(reordered);
      await FollowService.instance.updateFollowTagOrder(item, newTag);
    } catch (_) {
      SmartDialog.showToast('排序未保存，请重试');
    } finally {
      updateTagList();
      _savingTagOrder.value = false;
    }
  }

  Future<void> followDataCheck() async {
    await FollowService.instance.followUserAllDataCheck();
    SmartDialog.showToast("数据校准完成");
  }

  // 标签管理弹窗
  void showTagsManager() {
    Utils.showBottomSheet(
      title: '标签管理',
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppStyle.divider,
        Obx(() => ListTile(
              title: const Text("添加标签"),
              leading: const Icon(Icons.add),
              onTap: _savingTagOrder.value
                  ? null
                  : () {
                      editTagDialog("添加标签");
                    },
            )),
        AppStyle.divider,
        // 列表内容
        Expanded(
          child: Obx(
            () => AbsorbPointer(
              absorbing: _savingTagOrder.value,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: userTagList.length,
                itemBuilder: (context, index) {
                  // 偏移
                  FollowUserTag item = userTagList[index];
                  return ListTile(
                    key: ValueKey(item.id),
                    title: Text(item.tag),
                    onTap: () => editTagDialog("修改标签", followUserTag: item),
                    leading: IconButton(
                      tooltip: '删除标签',
                      icon: const Icon(Icons.delete),
                      onPressed: () {
                        removeTag(item);
                      },
                    ),
                    trailing: ReorderableDelayedDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12.0),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  );
                },
                onReorderItem: updateTagOrder,
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> editTagDialog(String title, {FollowUserTag? followUserTag}) async {
    var input = followUserTag?.tag ?? '';
    String? error;
    final name = await Get.dialog<String>(
      StatefulBuilder(builder: (context, setDialogState) {
        void submit() {
          final value = input.trim();
          if (value.isEmpty || const ['全部', '直播中', '未开播'].contains(value)) {
            setDialogState(() => error = '请输入其他标签名');
          } else if (userTagList.any((tag) => tag.tag == value && tag.id != followUserTag?.id)) {
            setDialogState(() => error = '标签已存在');
          } else {
            Get.back(result: value);
          }
        }

        return AlertDialog(
          title: Text(title),
          content: TextFormField(
            key: const ValueKey('follow-tag-manage-name'),
            initialValue: input,
            autofocus: true,
            maxLength: 30,
            decoration: InputDecoration(labelText: '标签名', errorText: error),
            onChanged: (value) => input = value,
            onFieldSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: const Text('取消')),
            TextButton(onPressed: submit, child: const Text('确定')),
          ],
        );
      }),
    );
    if (name == null || name == followUserTag?.tag) return;
    if (followUserTag == null) {
      await FollowService.instance.addFollowUserTag(name);
    } else {
      await FollowService.instance.updateTagName(followUserTag, name);
    }
    updateTagList();
  }

  // 关注清理功能
  Future<void> cleanFollow(List<FollowUser> cleanPool) async {
    if (cleanPool.isEmpty) {
      SmartDialog.showToast("没有需要清理的用户");
      return;
    }
    SmartDialog.showLoading(msg: "清理中");
    for (var follow in cleanPool) {
      await FollowService.instance.removeFollowUser(follow.id);
    }
    SmartDialog.dismiss();
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
    SmartDialog.showToast("清理完成");
  }

  List<FollowUser> buildAutoCleanPool() {
    var followList = FollowService.instance.followList;
    var histories = HistoryService.instance.getHistories();
    if (histories.isEmpty || followList.isEmpty) return [];
    // 筛选出历史记录里已关注的
    final followedIds = followList.map((follow) => follow.id).toSet(); // set性能略优
    final followedHistories = histories.where((history) => followedIds.contains(history.id)).toList();
    if (followedHistories.isEmpty) return [];

    List<Condition> conditions = [
      // Condition('siteId', FilterOperator.equals, Constant.kBiliBili),
      Condition(
        'watchDuration',
        FilterOperator.lessThan,
        Duration(minutes: minutes.value),
        comparableValueProvider: (watchDuration) {
          if (watchDuration is String) {
            return watchDuration.toDuration();
          }
          return null;
        },
      ),
    ];
    // 根据动态条件筛选出需要清理的 关注id
    final df = dynamicFilter(followedHistories, conditions, takeLast: takeLast.value);
    final uidsToClean = df.map((history) => history.id).toSet();

    final autoCleanPool = followList.where((follow) => uidsToClean.contains(follow.id)).toList();
    return autoCleanPool;
  }
}
