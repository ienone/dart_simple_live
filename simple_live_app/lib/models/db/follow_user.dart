import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:simple_live_app/app/utils/dynamic_filter.dart';
import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';
import 'package:simple_live_app/models/db/follow_snapshot.dart';

part 'follow_user.g.dart';

@HiveType(typeId: 1)
class FollowUser implements Mappable {
  FollowUser({
    required this.id,
    required this.roomId,
    required this.siteId,
    required this.userName,
    required this.face,
    required this.addTime,
    this.watchDuration = "00:00:00",
    String tag = "全部",
    List<String>? tags,
    this.metadataUpdatedAt = 0,
    this.remark = "",
    this.romanName = "",
    this.syncDuration = 0,
    this.watchDurationSec = 0,
    this.deleted = false,
    this.updateTime = 0,
    this.lastWatchTime = 0,
  }) : tags = normalizeTags(tags ?? [tag]);

  static List<String> normalizeTags(Iterable<String> tags) =>
      tags.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty && tag != '全部').toSet().toList();

  void replaceTags(Iterable<String> values) {
    tags = normalizeTags(values);
  }

  ///id=siteId_roomId
  @HiveField(0)
  String id;

  @HiveField(1)
  String roomId;

  @HiveField(2)
  String siteId;

  @HiveField(3)
  String userName;

  @HiveField(4)
  String face;

  @HiveField(5)
  DateTime addTime;

  @Deprecated('Use watchDurationSec instead')
  @HiveField(6)
  String? watchDuration; // "00:00:00"

  @HiveField(7)
  String get tag => tags.firstOrNull ?? '全部';

  set tag(String value) => replaceTags([value]);

  @HiveField(8)
  String? remark;

  @HiveField(9)
  String? romanName;

  @HiveField(10, defaultValue: 0)
  int syncDuration; // 需要同步增加的观看时长

  @HiveField(11, defaultValue: 0)
  int watchDurationSec; // watchDuration -> sec easy to calculate

  /// 墓碑标记：true表示已取消关注
  @HiveField(12, defaultValue: false)
  bool deleted;

  /// 墓碑更新时间（秒级时间戳），用于定期清理
  @HiveField(13, defaultValue: 0)
  int updateTime;

  // 最后一次观看
  @HiveField(14, defaultValue: 0)
  int? lastWatchTime;

  @HiveField(15)
  List<String> tags;

  /// Milliseconds, independent of the seconds-based deletion tombstone.
  @HiveField(18, defaultValue: 0)
  int metadataUpdatedAt;

  void markMetadataChanged({int after = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = metadataUpdatedAt > after ? metadataUpdatedAt : after;
    metadataUpdatedAt = now > previous ? now : previous + 1;
  }

  /// 直播状态
  /// 0=未知(加载中) 1=未开播 2=直播中
  Rx<int> liveStatus = 0.obs;

  /// 直播封面
  Rx<String> cover = "".obs;

  /// 直播标题
  Rx<String> title = "".obs;

  Rx<int> online = 0.obs;

  factory FollowUser.fromJson(Map<String, dynamic> json, {FollowUser? existing}) {
    final int watchSeconds;
    if (json.containsKey('watchDurationSec')) {
      watchSeconds = json['watchDurationSec'] as int;
    } else if (json['watchDuration'] is String) {
      watchSeconds = (json['watchDuration'] as String).toDuration().inSeconds;
    } else {
      watchSeconds = existing?.watchDurationSec ?? 0;
    }
    final follow = FollowUser(
      id: json['id'],
      roomId: json['roomId'],
      siteId: json['siteId'],
      userName: json['userName'],
      face: json['face'],
      addTime: DateTime.parse(json['addTime']),
      watchDuration: Duration(seconds: watchSeconds).toHMSString(),
      tag: json["tag"] ?? "全部",
      tags: json.containsKey('tags') ? List<String>.from(json['tags'] as List) : existing?.tags,
      metadataUpdatedAt: json['metadataUpdatedAt'] as int? ?? existing?.metadataUpdatedAt ?? 0,
      remark: json["remark"] ?? "",
      romanName: json["romanName"] ?? "",
      syncDuration: json["syncDuration"] ?? 0,
      watchDurationSec: watchSeconds,
      deleted: json["deleted"] ?? false,
      updateTime: json["updateTime"] ?? 0,
      lastWatchTime: json["lastWatchTime"] ?? 0,
    );
    if (existing != null) {
      follow.applySnapshot(existing.toSnapshot());
    }
    return follow;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'siteId': siteId,
        'userName': userName,
        'face': face,
        'addTime': addTime.toString(),
        "watchDuration": watchDuration ?? "00:00:00",
        "tag": tags.firstOrNull ?? '全部',
        "tags": tags,
        "metadataUpdatedAt": metadataUpdatedAt,
        "remark": remark,
        "romanName": romanName,
        "syncDuration": syncDuration,
        "watchDurationSec": watchDurationSec,
        "deleted": deleted,
        "updateTime": updateTime,
        "lastWatchTime": lastWatchTime,
      };

  @override
  Map<String, dynamic> toMap() => toJson();

  FollowSnapshotItem toSnapshot() => FollowSnapshotItem(
        id: id,
        liveStatus: liveStatus.value,
        cover: cover.value,
        title: title.value,
        online: online.value,
      );

  void applySnapshot(FollowSnapshotItem snapshot) {
    liveStatus.value = snapshot.liveStatus;
    cover.value = snapshot.cover;
    title.value = snapshot.title;
    online.value = snapshot.online;
  }
}
