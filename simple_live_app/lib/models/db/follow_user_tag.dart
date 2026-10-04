import 'package:hive_ce/hive_ce.dart';

part 'follow_user_tag.g.dart';

@HiveType(typeId: 3)
class FollowUserTag {
  @HiveField(1)
  String id;

  // 用户自定义tag
  @HiveField(2)
  String tag;

  // followUserId
  @HiveField(3)
  List<String> userId;

  @HiveField(4, defaultValue: false)
  bool deleted;

  @HiveField(5, defaultValue: 0)
  int updatedAt;

  FollowUserTag({
    required this.id,
    required this.tag,
    required this.userId,
    this.deleted = false,
    this.updatedAt = 0,
  });

  void markChanged({int after = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = updatedAt > after ? updatedAt : after;
    updatedAt = now > previous ? now : previous + 1;
  }

  factory FollowUserTag.fromJson(Map<String, dynamic> json) {
    return FollowUserTag(
      id: json['id'],
      tag: json['tag'],
      userId: List<String>.from(json['userId']),
      deleted: json['deleted'] as bool? ?? false,
      updatedAt: json['updatedAt'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tag': tag,
      'userId': userId,
      'deleted': deleted,
      'updatedAt': updatedAt,
    };
  }

  FollowUserTag copyWith({
    String? id,
    String? tag,
    List<String>? userId,
    bool? deleted,
    int? updatedAt,
  }) {
    return FollowUserTag(
      id: id ?? this.id,
      tag: tag ?? this.tag,
      userId: userId ?? this.userId,
      deleted: deleted ?? this.deleted,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
