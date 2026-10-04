import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/media_session_service.dart';

class MediaQueuePage extends StatelessWidget {
  const MediaQueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = MediaSessionService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('播放队列')),
      body: Obx(() => ListView(
            children: [
              SwitchListTile(
                title: const Text('全部关注'),
                value: session.allFollows.value,
                onChanged: (value) => session.setQueueFilter(all: value, tagIds: session.selectedTagIds),
              ),
              if (!session.allFollows.value)
                for (final tag in FollowService.instance.followTagList)
                  CheckboxListTile(
                    title: Text(tag.tag),
                    value: session.selectedTagIds.contains(tag.id),
                    onChanged: (selected) => session.setQueueFilter(
                      all: false,
                      tagIds: selected == true
                          ? [...session.selectedTagIds, tag.id]
                          : session.selectedTagIds.where((id) => id != tag.id).toList(),
                    ),
                  ),
              const Divider(),
              for (final follow in session.liveQueue)
                ListTile(
                  title: Text(follow.remark?.isNotEmpty == true ? follow.remark! : follow.userName),
                  subtitle: follow.title.value.isEmpty
                      ? null
                      : Text(follow.title.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
          )),
    );
  }
}
