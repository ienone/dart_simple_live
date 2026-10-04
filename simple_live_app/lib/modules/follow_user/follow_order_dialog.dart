import 'dart:math' as math;

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';

Future<void> showFollowOrderDialog() async {
  await Get.dialog<void>(const _FollowOrderDialog());
}

class _FollowOrderDialog extends StatefulWidget {
  const _FollowOrderDialog();

  @override
  State<_FollowOrderDialog> createState() => _FollowOrderDialogState();
}

class _FollowOrderDialogState extends State<_FollowOrderDialog> {
  late final List<FollowUser> items = FollowService.instance.followList.toList()
    ..sort((a, b) {
      final order = a.manualOrder.compareTo(b.manualOrder);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
  bool saving = false;

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (saving || oldIndex == newIndex) return;
    final previous = List<FollowUser>.of(items);
    final item = items.removeAt(oldIndex);
    setState(() {
      items.insert(newIndex, item);
      saving = true;
    });
    try {
      await FollowService.instance.moveFollow(
        item,
        before: newIndex < items.length - 1 ? items[newIndex + 1] : null,
        after: newIndex == items.length - 1 && newIndex > 0 ? items[newIndex - 1] : null,
      );
    } catch (_) {
      items
        ..clear()
        ..addAll(previous);
      SmartDialog.showToast('排序未保存，请重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动排序'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      content: SizedBox(
        width: 360,
        height: math.min(420, MediaQuery.sizeOf(context).height * .55),
        child: AbsorbPointer(
          absorbing: saving,
          child: ReorderableListView.builder(
            key: const ValueKey('follow-order-list'),
            itemCount: items.length,
            buildDefaultDragHandles: false,
            onReorderItem: reorder,
            itemBuilder: (context, index) {
              final item = items[index];
              return ListTile(
                key: ValueKey('follow-order-${item.id}'),
                title: Text(
                  item.remark?.isNotEmpty == true ? item.remark! : item.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                leading: item.pinned ? const Icon(Icons.push_pin, size: 18) : null,
                trailing: ReorderableDragStartListener(
                  key: ValueKey('follow-order-handle-${item.id}'),
                  index: index,
                  child: const Tooltip(
                    message: '拖动排序',
                    child: Padding(padding: EdgeInsets.all(12), child: Icon(Icons.drag_handle)),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('follow-order-done'),
          onPressed: saving ? null : () => Get.back(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
