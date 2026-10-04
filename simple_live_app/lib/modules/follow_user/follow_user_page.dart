import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/filter_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FollowUserPage extends GetView<FollowUserController> {
  const FollowUserPage({super.key});

  @override
  Widget build(BuildContext context) {
    var count = MediaQuery.of(context).size.width ~/ 500;
    if (count < 1) count = 1;
    var c = MediaQuery.of(context).size.width ~/ 200;
    if (c < 2) {
      c = 2;
    }
    return Scaffold(
      appBar: AppBar(
        title: Obx(() => Text(controller.selectionMode.value ? '已选 ${controller.selectedIds.length} 项' : '关注用户')),
        actions: [
          Obx(() => controller.selectionMode.value
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('follow-select-visible'),
                      tooltip: '全选当前列表',
                      onPressed: controller.toggleSelectVisible,
                      icon: const Icon(Icons.select_all),
                    ),
                    PopupMenuButton<bool>(
                      key: const ValueKey('follow-batch-tags'),
                      tooltip: '批量标签',
                      enabled: controller.selectedIds.isNotEmpty,
                      icon: const Icon(Remix.price_tag_3_line),
                      onSelected: (remove) => controller.batchTags(remove: remove),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: false, child: Text('添加标签')),
                        PopupMenuItem(value: true, child: Text('移除标签')),
                      ],
                    ),
                  ],
                )
              : PopupMenuButton<int>(
                  key: const ValueKey('follow-menu'),
                  tooltip: '关注选项',
                  itemBuilder: (context) {
                    return const [
                      PopupMenuItem(
                        value: 0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.checklist),
                            AppStyle.hGap12,
                            Text("多选"),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 1,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Remix.blender_line),
                            AppStyle.hGap12,
                            Text("模式切换"),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 2,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Remix.sort_asc),
                            AppStyle.hGap12,
                            Text("按序排列"),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 3,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.reorder),
                            AppStyle.hGap12,
                            Text("手动排序"),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 4,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Remix.heart_line),
                            AppStyle.hGap12,
                            Text("关注设置"),
                          ],
                        ),
                      ),
                    ];
                  },
                  onSelected: (value) {
                    if (value == 4) {
                      Get.toNamed(RoutePath.kSettingsFollow);
                    } else if (value == 0) {
                      controller.startSelection();
                    } else if (value == 1) {
                      controller.showFollowStyleDialog();
                    } else if (value == 2) {
                      controller.showSortDialog();
                    } else if (value == 3) {
                      controller.showManualOrder();
                    }
                  },
                )),
        ],
        leading: Obx(
          () => controller.selectionMode.value
              ? IconButton(
                  key: const ValueKey('follow-selection-close'),
                  tooltip: '结束多选',
                  onPressed: controller.endSelection,
                  icon: const Icon(Icons.close),
                )
              : FollowService.instance.updating.value
                  ? const IconButton(
                      onPressed: null,
                      icon: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  : IconButton(
                      key: const ValueKey('follow-refresh'),
                      tooltip: '刷新关注',
                      onPressed: () {
                        controller.refreshData();
                      },
                      icon: const Icon(Icons.refresh),
                    ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsL8,
            child: Row(
              children: [
                Expanded(
                  child: Obx(
                    () => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Wrap(
                        spacing: 12,
                        children: controller.tagList.map(
                          (option) {
                            return FilterButton(
                              key: ValueKey('follow-filter-${option.tag}'),
                              text: option.tag,
                              selected: controller.filterMode.value == option,
                              onTap: () {
                                controller.setFilterMode(option);
                              },
                            );
                          },
                        ).toList(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Obx(
            () => Expanded(
              child: AppSettingsController.instance.followStyleNotGrid.value
                  ? PageGridView(
                      crossAxisSpacing: 12,
                      crossAxisCount: count,
                      pageController: controller,
                      firstRefresh: true,
                      showPCRefreshButton: false,
                      itemBuilder: (_, i) {
                        var item = controller.list[i];
                        var site = Sites.allSites[item.siteId]!;
                        return Obx(() => FollowUserItem(
                              key: ValueKey('follow-row-${item.id}'),
                              item: item,
                              selectionMode: controller.selectionMode.value,
                              selected: controller.selectedIds.contains(item.id),
                              onSelected: () => controller.toggleSelection(item),
                              onRemove: AppSettingsController.instance.hideRemoveFollowButton.value
                                  ? null
                                  : () => controller.removeFollow(item),
                              onTap: () {
                                if (controller.selectionMode.value) {
                                  controller.toggleSelection(item);
                                } else {
                                  AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
                                }
                              },
                              onLongPress: () => controller.showBottomMenu(item),
                            ));
                      },
                    )
                  : KeepAliveWrapper(
                      child: Obx(
                        () {
                          // temp
                          final hide = AppSettingsController.instance.hideRemoveFollowButton.value;
                          return PageGridView(
                            pageController: controller,
                            padding: AppStyle.edgeInsetsA12,
                            firstRefresh: true,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            crossAxisCount: c,
                            itemBuilder: (_, i) {
                              var item = controller.list[i];
                              // 或许直接继承字段更好，标记工作
                              LiveRoomItem liveRoomItem = LiveRoomItem(
                                roomId: item.roomId,
                                title: item.title.value,
                                cover: item.cover.value,
                                userName: item.userName,
                                online: item.online.value,
                              );
                              var site = Sites.allSites[item.siteId]!;
                              return Obx(() {
                                final selecting = controller.selectionMode.value;
                                return GestureDetector(
                                  key: ValueKey('follow-row-${item.id}'),
                                  onTap: selecting ? () => controller.toggleSelection(item) : null,
                                  child: Stack(
                                    children: [
                                      AbsorbPointer(
                                        absorbing: selecting,
                                        child: LiveRoomCard(
                                          site,
                                          liveRoomItem,
                                          onFollowRemove:
                                              hide || selecting ? null : () => controller.removeFollow(item),
                                          onLongPress: () => controller.showBottomMenu(item),
                                        ),
                                      ),
                                      if (selecting)
                                        Positioned(
                                          top: 4,
                                          left: 4,
                                          child: Material(
                                            color: Theme.of(context).colorScheme.surface,
                                            shape: const CircleBorder(),
                                            child: Checkbox(
                                              key: ValueKey('follow-select-${item.id}'),
                                              value: controller.selectedIds.contains(item.id),
                                              semanticLabel: '选择${item.userName}',
                                              onChanged: (_) => controller.toggleSelection(item),
                                            ),
                                          ),
                                        )
                                      else if (item.pinned)
                                        Positioned(
                                          top: 8,
                                          left: 8,
                                          child: Tooltip(
                                            message: '已置顶',
                                            child: Icon(Icons.push_pin,
                                                size: 18, color: Theme.of(context).colorScheme.primary),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              });
                            },
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
