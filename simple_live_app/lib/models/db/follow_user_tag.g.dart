// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'follow_user_tag.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class FollowUserTagAdapter extends TypeAdapter<FollowUserTag> {
  @override
  final typeId = 3;

  @override
  FollowUserTag read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FollowUserTag(
      id: fields[1] as String,
      tag: fields[2] as String,
      userId: (fields[3] as List).cast<String>(),
      deleted: fields[4] == null ? false : fields[4] as bool,
      updatedAt: fields[5] == null ? 0 : (fields[5] as num).toInt(),
    );
  }

  @override
  void write(BinaryWriter writer, FollowUserTag obj) {
    writer
      ..writeByte(5)
      ..writeByte(1)
      ..write(obj.id)
      ..writeByte(2)
      ..write(obj.tag)
      ..writeByte(3)
      ..write(obj.userId)
      ..writeByte(4)
      ..write(obj.deleted)
      ..writeByte(5)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FollowUserTagAdapter && runtimeType == other.runtimeType && typeId == other.typeId;
}
