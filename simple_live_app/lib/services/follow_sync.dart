import 'package:fractional_indexing_dart/fractional_indexing_dart.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

Future<void> importSyncedFollows(
  dynamic records, {
  bool overlay = false,
  List<FollowUserTag>? tags,
}) {
  return FollowService.instance.withFollowWrite(() async {
    if (records is! List) {
      throw const FormatException('关注列表格式无效');
    }
    final box = DBService.instance.followBox;
    final incoming = <String, FollowUser>{};
    // Parse everything before deleting or replacing any persisted records.
    for (final record in records) {
      if (record is! Map) {
        throw const FormatException('关注记录格式无效');
      }
      final json = Map<String, dynamic>.from(record);
      final user = FollowUser.fromJson(json, existing: box.get(json['id']));
      if (user.id.isEmpty || incoming.containsKey(user.id)) {
        throw const FormatException('关注记录标识无效或重复');
      }
      incoming[user.id] = user;
    }
    final definitions = tags ??
        (records.isNotEmpty && records.first is Map && (records.first as Map).containsKey('tagDefinitions')
            ? parseSyncedTagDefinitions((records.first as Map)['tagDefinitions'])
            : null);
    final mergedTags = definitions == null
        ? null
        : mergeSyncedTagDefinitions(DBService.instance.getAllFollowTagList(), definitions, overlay: overlay);
    FollowService.instance.cancelStatusUpdate();
    if (overlay) {
      await box.deleteAll(box.keys.where((key) => !incoming.containsKey(key)).toList());
    }
    await box.putAll(incoming);
    if (mergedTags != null) {
      await DBService.instance.tagBox.clear();
      await DBService.instance.tagBox.putAll({for (final tag in mergedTags) tag.id: tag});
    }
    await FollowService.instance.followUserAllDataCheck();
  });
}

Future<void> importSyncedTags(dynamic records, {bool overlay = false}) {
  return FollowService.instance.withFollowWrite(() async {
    final tags = mergeSyncedTagDefinitions(
      DBService.instance.getAllFollowTagList(),
      parseSyncedTagDefinitions(records),
      overlay: overlay,
    );
    FollowService.instance.cancelStatusUpdate();
    await DBService.instance.tagBox.clear();
    await DBService.instance.tagBox.putAll({for (final tag in tags) tag.id: tag});
    // Membership is derived from the follows; an old peer's single-tag index
    // must not erase additional memberships already stored on this device.
    await FollowService.instance.followUserAllDataCheck();
  });
}

List<FollowUserTag> parseSyncedTagDefinitions(dynamic records) {
  if (records is! List) throw const FormatException('标签列表格式无效');
  return records.map((record) {
    if (record is! Map) throw const FormatException('标签记录格式无效');
    return FollowUserTag.fromJson(Map<String, dynamic>.from(record));
  }).toList();
}

/// A tag's name identifies its definition; fractional IDs only determine order.
/// Keep deletion records so a legacy peer cannot bring a removed name back.
List<FollowUserTag> mergeSyncedTagDefinitions(
  Iterable<FollowUserTag> local,
  Iterable<FollowUserTag> incoming, {
  bool overlay = false,
}) {
  final localTags = local.toList();
  final incomingTags = incoming.toList();
  final incomingNames = incomingTags.map((tag) => tag.tag).toSet();
  final definitions = <String, FollowUserTag>{};
  for (final candidate in [
    ...localTags.where((tag) => !overlay || tag.deleted || incomingNames.contains(tag.tag)),
    ...incomingTags,
  ]) {
    final name = candidate.tag.trim();
    if (name.isEmpty || name == '全部') continue;
    final current = definitions[name];
    if (current == null ||
        candidate.updatedAt > current.updatedAt ||
        (candidate.updatedAt == current.updatedAt && candidate.deleted && !current.deleted)) {
      definitions[name] = candidate.copyWith(tag: name, userId: List<String>.from(candidate.userId));
    }
  }
  bool validId(String id) {
    try {
      FractionalIndexing.validateOrderKey(id, FractionalIndexing.base62Digits);
      return true;
    } catch (_) {
      return false;
    }
  }

  String? lastKey;
  for (final tag in definitions.values) {
    if (validId(tag.id) && (lastKey == null || tag.id.compareTo(lastKey) > 0)) lastKey = tag.id;
  }
  final usedIds = <String>{};
  return definitions.values.map((tag) {
    if (!validId(tag.id) || !usedIds.add(tag.id)) {
      lastKey = FractionalIndexing.generateKeyBetween(lastKey, null);
      usedIds.add(lastKey!);
      return tag.copyWith(id: lastKey);
    }
    return tag;
  }).toList();
}
