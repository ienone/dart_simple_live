import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/follow_tag_badges.dart';
import 'dart:ui' as ui;

class FollowUserItem extends StatelessWidget {
  final FollowUser item;
  final Function()? onRemove;
  final Function()? onTap;
  final Function()? onLongPress;
  final bool playing;
  final String? activeTag;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelected;
  const FollowUserItem({
    required this.item,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.playing = false,
    this.activeTag,
    this.selectionMode = false,
    this.selected = false,
    this.onSelected,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId]!;
    final metadataStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return Ink(
        decoration: BoxDecoration(
          gradient: playing
              ? LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.red.withValues(alpha: 0.06), Colors.transparent],
                )
              : null,
        ),
        child: ListTile(
          contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
          selected: selected,
          leading: selectionMode
              ? Checkbox(
                  key: ValueKey('follow-select-${item.id}'),
                  value: selected,
                  semanticLabel: '选择${item.userName}',
                  onChanged: (_) => onSelected?.call(),
                )
              : NetImage(
                  item.face,
                  width: 48,
                  height: 48,
                  borderRadius: 24,
                ),
          title: Text.rich(
            TextSpan(
              text: item.remark?.isNotEmpty == true ? item.remark : item.userName,
              children: [
                if (item.pinned)
                  const WidgetSpan(
                    alignment: ui.PlaceholderAlignment.middle,
                    child: Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Tooltip(message: '已置顶', child: Icon(Icons.push_pin, size: 14)),
                    ),
                  ),
                WidgetSpan(
                  alignment: ui.PlaceholderAlignment.middle,
                  child: Obx(
                    () => Offstage(
                      offstage: item.liveStatus.value == 0,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppStyle.hGap12,
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: LiveStatus.fromCode(item.liveStatus.value, playing: playing).color,
                              borderRadius: AppStyle.radius12,
                            ),
                          ),
                          AppStyle.hGap4,
                          Text(
                            LiveStatus.fromCode(item.liveStatus.value, playing: playing).label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.normal,
                              color: item.liveStatus.value == 2 ? null : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          subtitle: Row(
            children: [
              Image.asset(
                site.logo,
                width: 16,
              ),
              AppStyle.hGap4,
              Text(
                site.name,
                style: metadataStyle,
              ),
              AppStyle.hGap4,
              Text(
                "${(item.watchDurationSec / 3600).toStringAsFixed(1)}h",
                style: metadataStyle,
              ),
              if (item.tags.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(child: FollowTagBadges(tags: item.tags, activeTag: activeTag)),
              ],
            ],
          ),
          trailing: selectionMode
              ? null
              : playing
                  ? const SizedBox(
                      width: 64,
                      child: Center(
                        child: Icon(
                          Icons.play_arrow,
                        ),
                      ),
                    )
                  : (onRemove == null
                      ? null
                      : IconButton(
                          tooltip: '取消关注',
                          onPressed: () {
                            onRemove?.call();
                          },
                          icon: const Icon(Remix.dislike_line),
                        )),
          onTap: onTap,
          onLongPress: onLongPress,
        ));
  }
}

enum LiveStatus {
  reading('读取中', Colors.grey),
  notLiving('未开播', Colors.grey),
  living('直播中', Colors.green),
  watching('观看中', Colors.red);

  const LiveStatus(this.label, this.color);

  final String label;
  final Color color;

  static LiveStatus fromCode(int status, {bool playing = false}) {
    if (playing) {
      return LiveStatus.watching;
    }
    if (status == 0) {
      return LiveStatus.reading;
    } else if (status == 1) {
      return LiveStatus.notLiving;
    } else {
      return LiveStatus.living;
    }
  }
}
