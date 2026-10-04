import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/media_session/audio_service_session.dart';
import 'package:simple_live_app/services/media_session/media_session_state.dart';
import 'package:simple_live_app/services/media_session/mpris_session.dart';

/// One session and one live-follow queue, shared by the player and OS controls.
class MediaSessionService extends GetxService {
  static MediaSessionService get instance => Get.find<MediaSessionService>();

  static const _filterKey = 'LiveMediaQueueFilter';
  final allFollows = true.obs;
  final selectedTagIds = <String>[].obs;
  final liveQueue = <FollowUser>[].obs;
  final available = false.obs;
  final Map<String, String> _selectedTagNames = {};
  NativeMediaSession? _native;
  StreamSubscription<dynamic>? _followSubscription;
  Worker? _tagsWorker;
  Object? _owner;
  LiveMediaItem? _item;
  Future<void> Function()? _play;
  Future<void> Function()? _pause;
  Future<void> Function(FollowUser)? _openRoom;
  bool _playing = false;
  bool _buffering = false;
  bool _switching = false;
  bool _currentWasQueued = false;
  bool _disposed = false;
  bool _tagUpdateScheduled = false;
  bool _publicationPending = false;
  bool _drainingEnds = false;
  String? _pendingEndId;
  Object? _pendingEndOwner;
  String? _pendingSuccessorId;
  Future<void> _publication = Future.value();

  Future<MediaSessionService> init() async {
    final saved = LocalStorageService.instance.settingsBox.get(_filterKey);
    if (saved is Map) {
      allFollows.value = saved['all'] != false;
      final ids = saved['tagIds'];
      if (ids is List) selectedTagIds.assignAll(ids.whereType<String>().toSet());
      final names = saved['tagNames'];
      if (names is Map) {
        for (final entry in names.entries) {
          if (entry.key is String && entry.value is String) {
            _selectedTagNames[entry.key as String] = entry.value as String;
          }
        }
      }
    }
    _followSubscription = FollowService.instance.updatedListStream.listen((_) => _rebuildQueue());
    _tagsWorker = ever(FollowService.instance.followTagList, (_) => _scheduleTagUpdate());
    // FollowService initialization performs asynchronous schema/order migrations.
    await FollowService.instance.ready;
    _reconcileTags();
    _rebuildQueue();
    try {
      _native = Platform.isLinux ? await MprisSession.create(_command) : await AudioServiceSession.create(_command);
      available.value = true;
      _publish();
    } catch (error, stack) {
      // A missing session bus must not prevent the user from opening the player.
      Log.e('System media session could not be initialized: $error', stack);
    }
    return this;
  }

  Future<void> setQueueFilter({required bool all, required Iterable<String> tagIds}) async {
    allFollows.value = all;
    selectedTagIds.assignAll(tagIds.toSet());
    _reconcileTags();
    await _saveFilter();
    _rebuildQueue(advanceOffline: false);
  }

  Future<void> _saveFilter() => LocalStorageService.instance.settingsBox.put(_filterKey, {
        'all': allFollows.value,
        'tagIds': selectedTagIds.toList(),
        'tagNames': Map<String, String>.from(_selectedTagNames),
      });

  void _scheduleTagUpdate() {
    if (_tagUpdateScheduled || _disposed) return;
    _tagUpdateScheduled = true;
    scheduleMicrotask(() {
      _tagUpdateScheduled = false;
      if (_disposed) return;
      _reconcileTags();
      unawaited(_saveFilter());
      _rebuildQueue(advanceOffline: false);
    });
  }

  void _reconcileTags() {
    final tags = FollowService.instance.followTagList;
    final selected = <String, String>{};
    for (final id in selectedTagIds) {
      // Tag IDs are fractional sort keys: reorder changes IDs, rename changes names.
      final tag = tags.firstWhereOrNull((tag) => tag.id == id) ??
          tags.firstWhereOrNull((tag) => tag.tag == _selectedTagNames[id]);
      if (tag != null) selected[tag.id] = tag.tag;
    }
    selectedTagIds.assignAll(selected.keys);
    _selectedTagNames
      ..clear()
      ..addAll(selected);
  }

  void bind({
    required Object owner,
    required String id,
    required String title,
    required String artist,
    String? artUri,
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function(FollowUser) openRoom,
  }) {
    if (_disposed) return;
    if (_item?.id != id || !identical(_owner, owner)) {
      _playing = false;
      _buffering = false;
      _currentWasQueued = false;
      _pendingEndId = null;
    }
    _owner = owner;
    final uri = artUri == null ? null : Uri.tryParse(artUri);
    _item = LiveMediaItem(
      id: id,
      title: title,
      artist: artist,
      artUri: uri != null && ['https', 'http'].contains(uri.scheme) ? uri : null,
    );
    _play = play;
    _pause = pause;
    _openRoom = openRoom;
    _rebuildQueue(advanceOffline: false);
  }

  void update(Object owner, {required bool playing, required bool buffering}) {
    if (_disposed || !identical(_owner, owner)) return;
    _playing = playing;
    _buffering = buffering;
    _publish();
  }

  void unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _item = null;
    _play = null;
    _pause = null;
    _openRoom = null;
    _playing = false;
    _buffering = false;
    _currentWasQueued = false;
    _pendingEndId = null;
    _publish();
  }

  bool get canSkip => _owner != null && liveQueue.any((entry) => entry.id != _item?.id);

  bool isQueueTransition(Object owner) => identical(_owner, owner) && _switching;

  /// Called by every explicit pause path, including the in-app control.
  void cancelPendingAdvance(Object owner) {
    if (!identical(_owner, owner)) return;
    _pendingEndId = null;
    _pendingEndOwner = null;
    _pendingSuccessorId = null;
  }

  Future<void> play() => _command(LiveMediaCommand.play);
  Future<void> pause() => _command(LiveMediaCommand.pause);
  Future<void> next() => _command(LiveMediaCommand.next);
  Future<void> previous() => _command(LiveMediaCommand.previous);

  Future<void> onPlaybackEnded(Object owner, {bool offline = false}) async {
    if (!identical(_owner, owner) || _disposed) return;
    final id = _item?.id;
    if (id == null) return;
    final index = liveQueue.indexWhere((entry) => entry.id == id);
    _pendingSuccessorId = liveQueue.length > 1 && index >= 0 ? liveQueue[(index + 1) % liveQueue.length].id : null;
    if (offline) FollowService.instance.applyKnownLiveStatus(id, false);
    _pendingEndOwner = owner;
    _pendingEndId = id;
    if (!_switching) await _drainEndedRooms();
  }

  Future<void> _drainEndedRooms() async {
    if (_drainingEnds || _switching || _disposed) return;
    _drainingEnds = true;
    final visited = <String>{};
    try {
      while (_pendingEndId != null && identical(_pendingEndOwner, _owner) && !_disposed) {
        final endedId = _pendingEndId!;
        final successorId = _pendingSuccessorId;
        _pendingEndId = null;
        if (_item?.id != endedId || !visited.add(endedId)) break;
        _rebuildQueue(advanceOffline: false);
        final candidates = liveQueue.where((entry) => !visited.contains(entry.id)).toList();
        if (candidates.isEmpty) {
          await pause();
          break;
        }
        final successor = candidates.firstWhereOrNull((entry) => entry.id == successorId) ?? candidates.first;
        await _switchTo(successor);
      }
    } finally {
      _drainingEnds = false;
    }
  }

  void _rebuildQueue({bool advanceOffline = true}) {
    if (_disposed) return;
    final follows = FollowService.instance;
    final previousQueue = liveQueue.toList();
    final names = follows.followTagList.where((tag) => selectedTagIds.contains(tag.id)).map((tag) => tag.tag).toSet();
    final entries = follows.followList
        .where((follow) =>
            !follow.deleted &&
            follow.liveStatus.value == 2 &&
            !follow.statusRefreshFailed.value &&
            (allFollows.value || follow.tags.any(names.contains)))
        .toList();
    follows.listSortByMethod(entries, AppSettingsController.instance.followSortMethod.value);
    liveQueue.assignAll(entries);
    if (entries.any((entry) => entry.id == _item?.id)) _currentWasQueued = true;
    _publish();
    if (!advanceOffline || !_playing || _owner == null || _switching) return;
    // Keep membership history across lookup failures, which temporarily remove
    // an unverified room from the queue without declaring that it has ended.
    if (!_currentWasQueued) return;
    final current = follows.followList.firstWhereOrNull((entry) => entry.id == _item?.id);
    // A failed lookup is not an offline event. Filters do not interrupt a room.
    final ended =
        current == null || current.deleted || (current.liveStatus.value == 1 && !current.statusRefreshFailed.value);
    if (ended) unawaited(_advanceFromRemoved(previousQueue));
  }

  Future<void> _advanceFromRemoved(List<FollowUser> previousQueue) async {
    if (liveQueue.isEmpty) {
      await pause();
      return;
    }
    final oldIndex = previousQueue.indexWhere((entry) => entry.id == _item?.id);
    for (var offset = 1; offset <= previousQueue.length; offset++) {
      final id = previousQueue[(oldIndex + offset) % previousQueue.length].id;
      final candidate = liveQueue.firstWhereOrNull((entry) => entry.id == id);
      if (candidate != null) {
        await _switchTo(candidate);
        return;
      }
    }
    await _switchTo(liveQueue.first);
  }

  Future<void> _command(LiveMediaCommand command) async {
    if (_disposed || _owner == null) return;
    try {
      switch (command) {
        case LiveMediaCommand.play:
          if (!_playing) await _play?.call();
        case LiveMediaCommand.pause:
          cancelPendingAdvance(_owner!);
          if (_playing || _buffering) await _pause?.call();
        case LiveMediaCommand.toggle:
          if (_playing) cancelPendingAdvance(_owner!);
          await (_playing ? _pause : _play)?.call();
        case LiveMediaCommand.next:
        case LiveMediaCommand.previous:
          if (!canSkip || _switching) return;
          final index = liveQueue.indexWhere((entry) => entry.id == _item?.id);
          final direction = command == LiveMediaCommand.next ? 1 : -1;
          final target =
              index < 0 ? (direction == 1 ? 0 : liveQueue.length - 1) : (index + direction) % liveQueue.length;
          await _switchTo(liveQueue[target]);
      }
    } catch (error, stack) {
      Log.e('System media command failed: $error', stack);
    }
  }

  Future<void> _switchTo(FollowUser follow) async {
    final openRoom = _openRoom;
    if (_switching || _disposed || openRoom == null) return;
    // Re-check membership at dispatch; status refresh and deletions can overlap.
    if (!liveQueue.any((entry) => entry.id == follow.id)) return;
    _switching = true;
    try {
      await openRoom(follow);
    } catch (error, stack) {
      Log.e('Live queue room change failed: $error', stack);
    } finally {
      _switching = false;
      if (_pendingEndId != null && !_drainingEnds) unawaited(_drainEndedRooms());
    }
  }

  void _publish() {
    if (_native == null || _disposed || _publicationPending) return;
    _publicationPending = true;
    // Serialize platform writes so late artwork/native calls cannot restore an old room.
    _publication = _publication.then((_) async {
      _publicationPending = false;
      if (_disposed) return;
      final state = LiveMediaState(
        item: _item,
        playing: _playing,
        buffering: _buffering,
        canSkip: canSkip,
        queue: liveQueue
            .map((follow) => LiveMediaItem(
                  id: follow.id,
                  title: follow.title.value.isEmpty ? follow.userName : follow.title.value,
                  artist: follow.userName,
                ))
            .toList(growable: false),
      );
      await _native?.publish(state);
    }).catchError((Object error, StackTrace stack) {
      Log.e('System media state update failed: $error', stack);
    });
  }

  @override
  void onClose() {
    _disposed = true;
    _followSubscription?.cancel();
    _tagsWorker?.dispose();
    _owner = null;
    unawaited(_publication.whenComplete(() async => _native?.dispose()));
    super.onClose();
  }
}
