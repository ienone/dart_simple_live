import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:simple_live_app/services/media_session/media_session_state.dart';

/// Exposes the actual player on the user's Linux session bus.
class MprisSession extends DBusObject implements NativeMediaSession {
  MprisSession._(this._bus, this._command) : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  static const _root = 'org.mpris.MediaPlayer2';
  static const _player = 'org.mpris.MediaPlayer2.Player';
  final DBusClient _bus;
  final LiveMediaCommandHandler _command;
  LiveMediaState _state = const LiveMediaState();

  static Future<MprisSession> create(LiveMediaCommandHandler command) async {
    final bus = DBusClient.session();
    final session = MprisSession._(bus, command);
    try {
      await bus.registerObject(session);
      await bus.requestName(
        'org.mpris.MediaPlayer2.com.slotsun.slive.instance$pid',
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      return session;
    } catch (_) {
      await bus.close();
      rethrow;
    }
  }

  Map<String, DBusValue> get _rootProperties => {
        'CanQuit': const DBusBoolean(false),
        'CanRaise': const DBusBoolean(false),
        'HasTrackList': const DBusBoolean(false),
        'Identity': const DBusString('Slive'),
        'DesktopEntry': const DBusString('io.github.SlotSun.Slive'),
        'SupportedUriSchemes': DBusArray.string(const []),
        'SupportedMimeTypes': DBusArray.string(const []),
      };

  Map<String, DBusValue> get _playerProperties {
    final item = _state.item;
    // Encode every byte so IDs containing '-' or Unicode remain valid object paths.
    final track = item == null
        ? '/org/mpris/MediaPlayer2/TrackList/NoTrack'
        : '/com/slotsun/slive/track/${utf8.encode(item.id).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    return {
      'PlaybackStatus': DBusString(item == null
          ? 'Stopped'
          : _state.playing
              ? 'Playing'
              : 'Paused'),
      'LoopStatus': const DBusString('None'),
      'Rate': const DBusDouble(1),
      'Shuffle': const DBusBoolean(false),
      'Metadata': DBusDict.stringVariant({
        'mpris:trackid': DBusObjectPath(track),
        if (item != null) ...{
          'xesam:title': DBusString(item.title),
          'xesam:artist': DBusArray.string([item.artist]),
          if (item.artUri != null) 'mpris:artUrl': DBusString(item.artUri.toString()),
        },
      }),
      'Volume': const DBusDouble(1),
      'Position': const DBusInt64(0),
      'MinimumRate': const DBusDouble(1),
      'MaximumRate': const DBusDouble(1),
      'CanGoNext': DBusBoolean(item != null && _state.canSkip),
      'CanGoPrevious': DBusBoolean(item != null && _state.canSkip),
      'CanPlay': DBusBoolean(item != null),
      'CanPause': DBusBoolean(item != null),
      'CanSeek': const DBusBoolean(false),
      'CanControl': const DBusBoolean(true),
    };
  }

  Map<String, DBusValue>? _properties(String interface) => switch (interface) {
        _root => _rootProperties,
        _player => _playerProperties,
        _ => null,
      };

  @override
  List<DBusIntrospectInterface> introspect() => [
        for (final interface in [_root, _player])
          DBusIntrospectInterface(
            interface,
            methods: [
              for (final name in interface == _player
                  ? ['Play', 'Pause', 'PlayPause', 'Stop', 'Next', 'Previous']
                  : ['Raise', 'Quit'])
                DBusIntrospectMethod(name),
            ],
            properties: [
              for (final entry in _properties(interface)!.entries)
                DBusIntrospectProperty(entry.key, entry.value.signature, access: DBusPropertyAccess.read),
            ],
          ),
      ];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final properties = _properties(interface);
    if (properties == null) return DBusMethodErrorResponse.unknownInterface();
    final value = properties[name];
    return value == null ? DBusMethodErrorResponse.unknownProperty() : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    final properties = _properties(interface);
    return properties == null ? DBusMethodErrorResponse.unknownInterface() : DBusGetAllPropertiesResponse(properties);
  }

  @override
  Future<DBusMethodResponse> setProperty(String interface, String name, DBusValue value) async =>
      DBusMethodErrorResponse.propertyReadOnly();

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _root && methodCall.interface != _player) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (methodCall.values.isNotEmpty) return DBusMethodErrorResponse.invalidArgs();
    if (methodCall.interface == _root) return DBusMethodErrorResponse.notSupported();
    final command = switch (methodCall.name) {
      'Play' => LiveMediaCommand.play,
      'Pause' || 'Stop' => LiveMediaCommand.pause,
      'PlayPause' => LiveMediaCommand.toggle,
      'Next' => LiveMediaCommand.next,
      'Previous' => LiveMediaCommand.previous,
      _ => null,
    };
    if (command == null) return DBusMethodErrorResponse.unknownMethod();
    await _command(command);
    return DBusMethodSuccessResponse();
  }

  @override
  Future<void> publish(LiveMediaState state) async {
    final previous = _playerProperties;
    _state = state;
    final changed = Map<String, DBusValue>.fromEntries(
      _playerProperties.entries.where((entry) => previous[entry.key] != entry.value),
    );
    if (changed.isNotEmpty) {
      await emitPropertiesChanged(_player, changedProperties: changed);
    }
  }

  @override
  Future<void> dispose() => _bus.close();
}
