import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:fractional_indexing_dart/fractional_indexing_dart.dart';
import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/follow_sync.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/interface/sync_resource.dart';
import 'package:simple_live_app/services/db_service.dart';

class FollowBundle {
  final List<FollowUser> follows;
  final List<FollowUserTag> tags;

  FollowBundle({
    List<FollowUser>? follows,
    List<FollowUserTag>? tags,
  })  : follows = follows ?? [],
        tags = tags ?? [];
}

class FollowSyncResource implements SyncResource<FollowBundle> {
  @override
  String get fileName => "SimpleLive_follows.json";

  String get tagFileName => "SimpleLive_Tags.json";

  @override
  Future<FollowBundle> loadLocal() async {
    // 同步时加载所有记录（包含墓碑），确保墓碑可以传播到其他设备
    var followList = DBService.instance
        .getAllFollowList()
        .map((item) => FollowUser.fromJson(item.toJson(), existing: item))
        .toList();
    var tagList = DBService.instance.getAllFollowTagList();
    return FollowBundle(
      follows: followList,
      tags: tagList,
    );
  }

  @override
  FollowBundle? loadRemote(Archive archive) {
    final followFile = archive.findFile(fileName);
    final tagFile = archive.findFile(tagFileName);
    if (followFile == null) return null;

    final followJsonData = jsonDecode(utf8.decode(followFile.content));
    final ids = <String>{};
    var followRemoteList = (followJsonData['data'] as List).map((record) {
      final json = Map<String, dynamic>.from(record as Map);
      final follow = FollowUser.fromJson(json, existing: DBService.instance.followBox.get(json['id']));
      if (follow.id.isEmpty || !ids.add(follow.id)) {
        throw const FormatException('关注记录标识无效或重复');
      }
      return follow;
    }).toList();
    final tagRemoteList = tagFile == null
        ? <FollowUserTag>[]
        : parseSyncedTagDefinitions(jsonDecode(utf8.decode(tagFile.content))['data']);
    return FollowBundle(
      follows: followRemoteList,
      tags: tagRemoteList,
    );
  }

  @override
  Future<void> saveLocal(FollowBundle data) async {
    await importSyncedFollows(
      data.follows.map((item) => item.toJson()).toList(),
      overlay: true,
      tags: data.tags,
    );
  }

  @override
  void saveRemote(Archive archive, FollowBundle data) {
    final followBytes = utf8.encode(jsonEncode({
      'data': data.follows.map((e) => e.toJson()).toList(),
    }));

    archive.addFile(
      ArchiveFile(
        fileName,
        followBytes.length,
        followBytes,
      ),
    );

    final tagBytes = utf8.encode(jsonEncode({
      'data': data.tags.map((e) => e.toJson()).toList(),
    }));

    archive.addFile(
      ArchiveFile(
        tagFileName,
        tagBytes.length,
        tagBytes,
      ),
    );
  }

  @override
  FollowBundle merge(
    FollowBundle local,
    FollowBundle remote,
  ) {
    var resFollows = _mergeFollowList(localList: local.follows, remoteList: remote.follows);
    final definitions = mergeSyncedTagDefinitions(local.tags, remote.tags);
    final tagMap = {for (final tag in definitions) tag.tag: tag.copyWith(userId: [])};
    String? lastKey;
    for (final tag in definitions) {
      if (lastKey == null || tag.id.compareTo(lastKey) > 0) lastKey = tag.id;
    }
    for (final follow in resFollows) {
      if (follow.deleted) continue;
      final memberships = <String>[];
      var metadataTime = follow.metadataUpdatedAt;
      for (final name in follow.tags) {
        var tag = tagMap[name];
        if (tag != null && tag.deleted) {
          if (tag.updatedAt > metadataTime) metadataTime = tag.updatedAt;
          continue;
        }
        if (tag == null) {
          lastKey = FractionalIndexing.generateKeyBetween(lastKey, null);
          tag = FollowUserTag(id: lastKey, tag: name, userId: [], updatedAt: follow.metadataUpdatedAt);
        }
        tagMap[name] = tag;
        tag.userId.add(follow.id);
        memberships.add(name);
      }
      follow.replaceTags(memberships);
      follow.metadataUpdatedAt = metadataTime;
    }
    return FollowBundle(follows: resFollows, tags: tagMap.values.toList());
  }

  // tombstone logic:
  // follow.deleted=true means the user was unfollowed
  // follow.updateTime stores the timestamp of the unfollow
  //
  // follow_watchDuration = webdav_watchDuration += syncDuration
  // syncDuration = 0
  List<FollowUser> _mergeFollowList({
    required List<FollowUser> localList,
    required List<FollowUser> remoteList,
  }) {
    final Map<String, FollowUser> result = {};
    final localMap = {for (var item in localList) item.id: item};
    final remoteMap = {for (var item in remoteList) item.id: item};

    for (var localItem in localList) {
      var remoteItem = remoteMap[localItem.id];
      if (remoteItem != null) {
        // 两边都有记录，需要合并
        if (localItem.deleted && remoteItem.deleted) {
          // 两边都是墓碑，保留 updateTime 更新的
          result[localItem.id] = localItem.updateTime >= remoteItem.updateTime ? localItem : remoteItem;
        } else if (localItem.deleted) {
          // 本地是墓碑，远程是正常记录
          // 如果本地墓碑时间晚于远程添加时间，则保留墓碑
          if (localItem.updateTime >= remoteItem.addTime.millisecondsSinceEpoch ~/ 1000) {
            result[localItem.id] = localItem;
          } else {
            // 远程重新关注了，清除墓碑
            remoteItem.deleted = false;
            remoteItem.updateTime = 0;
            result[remoteItem.id] = remoteItem;
          }
        } else if (remoteItem.deleted) {
          // 远程是墓碑，本地是正常记录
          // 如果远程墓碑时间晚于本地添加时间，则应用远程墓碑
          if (remoteItem.updateTime >= localItem.addTime.millisecondsSinceEpoch ~/ 1000) {
            result[remoteItem.id] = remoteItem;
          } else {
            // 本地重新关注了，保留本地
            result[localItem.id] = localItem;
          }
        } else {
          // 两边都是正常记录，合并观看时长
          if (remoteItem.metadataUpdatedAt > localItem.metadataUpdatedAt) {
            localItem.replaceTags(remoteItem.tags);
            localItem.metadataUpdatedAt = remoteItem.metadataUpdatedAt;
          }
          localItem.watchDurationSec = remoteItem.watchDurationSec + localItem.syncDuration;
          // Keep the legacy duration projection usable by older peers.
          // ignore: deprecated_member_use_from_same_package
          localItem.watchDuration = Duration(seconds: localItem.watchDurationSec).toHMSString();
          localItem.syncDuration = 0;
          result[localItem.id] = localItem;
        }
      } else {
        // Absence is not a deletion: old/partial backups may never have contained it.
        result[localItem.id] = localItem;
      }
    }

    for (var remoteItem in remoteList) {
      if (!localMap.containsKey(remoteItem.id)) {
        result[remoteItem.id] = remoteItem;
      }
    }
    return result.values.toList();
  }
}
