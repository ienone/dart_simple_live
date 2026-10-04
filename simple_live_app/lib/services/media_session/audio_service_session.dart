import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service_win/audio_service_win.dart';
import 'package:simple_live_app/services/media_session/media_session_state.dart';

/// MediaSession on Android, Now Playing on Apple, and SMTC on Windows.
class AudioServiceSession implements NativeMediaSession {
  AudioServiceSession._(this._handler, this._session, this._subscriptions);

  final _LiveAudioHandler _handler;
  final AudioSession? _session;
  final List<StreamSubscription<dynamic>> _subscriptions;
  bool _active = false;

  static Future<AudioServiceSession> create(LiveMediaCommandHandler command) async {
    if (Platform.isWindows) AudioServiceWin.registerWith();
    final handler = await AudioService.init(
      builder: () => _LiveAudioHandler(command),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.slotsun.slive.playback',
        androidNotificationChannelName: '直播播放',
        // A paused live stream can be resumed by the headset in the background.
        androidStopForegroundOnPause: false,
        androidNotificationIcon: 'drawable/ic_media_notification',
      ),
    );
    AudioSession? session;
    final subscriptions = <StreamSubscription<dynamic>>[];
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      subscriptions.add(session.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(command(LiveMediaCommand.pause));
      }));
      subscriptions.add(session.becomingNoisyEventStream.listen((_) {
        unawaited(command(LiveMediaCommand.pause));
      }));
    }
    return AudioServiceSession._(handler, session, subscriptions);
  }

  @override
  Future<void> publish(LiveMediaState state) async {
    MediaItem convert(LiveMediaItem item) => MediaItem(
          id: item.id,
          title: item.title,
          artist: item.artist,
          artUri: item.artUri,
          isLive: true,
        );
    final item = state.item;
    _handler.mediaItem.add(item == null ? null : convert(item));
    _handler.queue.add(state.queue.map(convert).toList(growable: false));
    final index = state.queue.indexWhere((entry) => entry.id == item?.id);
    _handler.playbackState.add(PlaybackState(
      controls: [
        if (item != null && state.canSkip) MediaControl.skipToPrevious,
        if (item != null) state.playing ? MediaControl.pause : MediaControl.play,
        if (item != null && state.canSkip) MediaControl.skipToNext,
      ],
      processingState: item == null
          ? AudioProcessingState.idle
          : state.buffering
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready,
      playing: state.playing,
      queueIndex: index < 0 ? null : index,
      systemActions: const {},
    ));
    if (_active != state.playing) {
      final granted = await _session?.setActive(state.playing) ?? true;
      if (granted) {
        _active = state.playing;
      } else if (state.playing) {
        // Keep OS controls and the actual player consistent when a phone call
        // or another exclusive session refuses audio focus.
        await _handler.pause();
      }
    }
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await publish(const LiveMediaState());
  }
}

class _LiveAudioHandler extends BaseAudioHandler {
  _LiveAudioHandler(this.command);

  final LiveMediaCommandHandler command;

  @override
  Future<void> play() => command(LiveMediaCommand.play);
  @override
  Future<void> pause() => command(LiveMediaCommand.pause);
  @override
  Future<void> stop() => pause();
  @override
  Future<void> skipToNext() => command(LiveMediaCommand.next);
  @override
  Future<void> skipToPrevious() => command(LiveMediaCommand.previous);
  @override
  Future<void> onTaskRemoved() => stop();
}
