import 'dart:math' as math;

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/services/follow_service.dart';

Future<List<String>?> showFollowTagPicker({
  String title = '设置标签',
  Iterable<String> selectedTags = const [],
  bool allowCreate = true,
}) {
  return Get.dialog<List<String>>(
    _FollowTagPicker(title: title, selectedTags: selectedTags, allowCreate: allowCreate),
  );
}

class _FollowTagPicker extends StatefulWidget {
  final String title;
  final Iterable<String> selectedTags;
  final bool allowCreate;

  const _FollowTagPicker({required this.title, required this.selectedTags, required this.allowCreate});

  @override
  State<_FollowTagPicker> createState() => _FollowTagPickerState();
}

class _FollowTagPickerState extends State<_FollowTagPicker> {
  late final Set<String> selected = widget.selectedTags.toSet();
  bool creatingTag = false;

  Future<void> addTag() async {
    if (creatingTag) return;
    setState(() => creatingTag = true);
    var input = '';
    var submitted = false;
    String? error;
    try {
      final name = await Get.dialog<String>(
        StatefulBuilder(builder: (context, setDialogState) {
          void submit() {
            if (submitted) return;
            final value = input.trim();
            if (value.isEmpty || const ['全部', '直播中', '未开播'].contains(value)) {
              setDialogState(() => error = '请输入其他标签名');
            } else if (FollowService.instance.followTagList.any((tag) => tag.tag == value)) {
              setDialogState(() => error = '标签已存在');
            } else {
              submitted = true;
              Navigator.of(context).pop(value);
            }
          }

          return AlertDialog(
            title: const Text('添加标签'),
            content: TextField(
              key: const ValueKey('follow-tag-name'),
              autofocus: true,
              maxLength: 30,
              decoration: InputDecoration(labelText: '标签名', errorText: error),
              onChanged: (value) => input = value,
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
              TextButton(key: const ValueKey('follow-tag-create-confirm'), onPressed: submit, child: const Text('添加')),
            ],
          );
        }),
      );
      if (name == null || !mounted) return;
      await FollowService.instance.addFollowUserTag(name);
      if (mounted) setState(() => selected.add(name));
    } catch (_) {
      if (mounted) SmartDialog.showToast('标签未保存，请重试');
    } finally {
      if (mounted) setState(() => creatingTag = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      content: SizedBox(
        width: 320,
        height: math.min(320, MediaQuery.sizeOf(context).height * .45),
        child: Obx(() {
          final tags = FollowService.instance.followTagList.toList();
          return ListView(
            children: [
              for (final tag in tags)
                CheckboxListTile(
                  key: ValueKey('follow-tag-option-${tag.tag}'),
                  title: Text(tag.tag),
                  value: selected.contains(tag.tag),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (value) => setState(() {
                    value == true ? selected.add(tag.tag) : selected.remove(tag.tag);
                  }),
                ),
              if (widget.allowCreate)
                ListTile(
                  key: const ValueKey('follow-tag-create'),
                  leading: const Icon(Icons.add),
                  title: const Text('添加标签'),
                  onTap: creatingTag ? null : addTag,
                ),
            ],
          );
        }),
      ),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('取消')),
        TextButton(
          key: const ValueKey('follow-tags-confirm'),
          onPressed: creatingTag ? null : () => Navigator.of(context).pop(selected.toList()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
