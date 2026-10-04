/// A live session deliberately has no duration or seek position.
class LiveMediaItem {
  const LiveMediaItem({
    required this.id,
    required this.title,
    required this.artist,
    this.artUri,
  });

  final String id;
  final String title;
  final String artist;
  final Uri? artUri;
}

class LiveMediaState {
  const LiveMediaState({
    this.item,
    this.playing = false,
    this.buffering = false,
    this.canSkip = false,
    this.queue = const [],
  });

  final LiveMediaItem? item;
  final bool playing;
  final bool buffering;
  final bool canSkip;
  final List<LiveMediaItem> queue;
}

enum LiveMediaCommand { play, pause, toggle, next, previous }

typedef LiveMediaCommandHandler = Future<void> Function(LiveMediaCommand command);

abstract class NativeMediaSession {
  Future<void> publish(LiveMediaState state);
  Future<void> dispose();
}
