import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart' as ui;
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/main.dart' as application;
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/media_queue/media_queue_page.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/common/sync_mode.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/executor/sync_executor.dart';
import 'package:simple_live_app/requests/webdav_client.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/media_session_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_core/simple_live_core.dart' show CoreLog, LiveRoomDetail, BiliBiliDanmakuArgs;

// This changes only transport routing: every request still reaches the real
// server and uses the default certificate verification.
class _EnvironmentProxy extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (url) => HttpClient.findProxyFromEnvironment(url);
    return client;
  }
}

const _firstId = 'huya_danking';
const _secondId = 'huya_1995';
const _music = 'E2E 音乐';
const _games = 'E2E 游戏';
const _shared = 'E2E 共享';
const _peerTag = 'E2E 离线同步';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _EnvironmentProxy();
  final phase = Platform.environment['SLIVE_E2E_PHASE'] ?? 'exercise';
  final output = Platform.environment['SLIVE_E2E_ARTIFACT_DIR'];
  if (output == null) throw StateError('Use scripts/e2e/issue-146.sh to isolate the real app profile.');

  testWidgets('Issue 146 real Linux application: $phase', (tester) async {
    final run = _Run(tester, Directory(output), phase);
    // Navigator cancels active pointers when opening a route. The live binding
    // must deliver those real cancellation events so a long-press recognizer
    // can return to ready before the next gesture on the same followed room.
    final priorPointerPropagation = tester.binding.shouldPropagateDevicePointerEvents;
    tester.binding.shouldPropagateDevicePointerEvents = true;
    final originalErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      // Preserve public-image failures as their own real external boundary;
      // they must not be attributed to unrelated Hive or WebDAV assertions.
      // A real HTTP retry below decides blocked vs failed; neither is a pass.
      final message = details.exceptionAsString();
      final match = RegExp(r'https://[^\s]+').firstMatch(message);
      if (details.library == 'image resource service' && message.contains('Failed to load') && match != null) {
        final url = match.group(0)!.replaceFirst(RegExp(r'\.$'), '');
        run.imageFailures[url] = message;
        FlutterError.dumpErrorToConsole(details);
      } else {
        originalErrorHandler?.call(details);
      }
    };
    try {
      await run.check('startup-native-and-real-http', () async {
        application.main([]);
        await run.until(() => Get.isRegistered<FollowService>() && find.byType(application.MyApp).evaluate().isNotEmpty,
            'real application initialization',
            seconds: 90);
        await windowManager.setSize(const Size(1280, 900));
        await windowManager.setPosition(Offset.zero);
        await run.pump();
        await run.until(() => find.text('已阅读并同意').evaluate().isNotEmpty || !AppSettingsController.instance.firstRun,
            'first-run agreement');
        if (find.text('已阅读并同意').evaluate().isNotEmpty) {
          await tester.tap(find.text('已阅读并同意'));
          await run.pump();
        }
        CoreLog.enableLog = false;
        await FollowService.instance.ready;
        await run.until(() => SyncService.instance.httpRunning.value, 'real LAN server startup');
        final info = await run.http('/info');
        expect(info['port'], 23234);
        expect(info['type'], 'linux');
        await run.write('http-info-$phase.json', info);
        await run.screenshot('startup-$phase');
      });
      if (run.failures.isNotEmpty) throw TestFailure('Real application startup failed; see scenario artifact.');
      if (phase == 'audio-switch') {
        await _audioSwitchScenarios(run);
      } else if (phase == 'native-endurance') {
        await _additionalProviderAudio(run, Constant.kBiliBili, '6', enduranceOnly: true);
        await _additionalProviderAudio(run, Constant.kDouyu, '6512', enduranceOnly: true);
        await _additionalProviderAudio(run, Constant.kDouyin, '602812384617', enduranceOnly: true);
      } else if (phase == 'restart') {
        await _restart(run);
      } else if (phase == 'peer-seed') {
        await _seedPeer(run);
      } else if (phase == 'owner-delete') {
        await _ownerDeletesSharedTag(run);
      } else if (phase == 'peer-merge') {
        await _mergeOfflinePeer(run);
      } else {
        await _exercise(run);
      }
    } finally {
      tester.binding.shouldPropagateDevicePointerEvents = priorPointerPropagation;
      FlutterError.onError = originalErrorHandler;
      await run.verifyExternalImages();
      await run.finish();
    }
    expect(run.failures, isEmpty, reason: run.failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Future<void> _exercise(_Run run) async {
  final service = FollowService.instance;
  final database = DBService.instance;
  await run.check('local-follow-input-and-visible-list', () async {
    expect(database.getFollowList(), isEmpty, reason: 'The profile must be isolated from real user data.');
    // Public room identities already used by the repository's live API tests.
    // These names are local user input, never claimed to come from an API.
    for (final room in ['danking', '1995']) {
      await service.addFollow(FollowUser(
        id: 'huya_$room',
        roomId: room,
        siteId: Constant.kHuya,
        userName: room,
        face: '',
        addTime: DateTime.now(),
      ));
    }
    await run.write('input-provenance.json', {
      'kind': 'user-created local follow records',
      'room_identity_source': 'simple_live_core/test/simple_live_core_test.dart: danking / 1995',
      'names': 'locally entered room identifiers; no live-platform metadata assertion',
      'mocked_responses': false,
    });
    await run.openFollows();
    expect(find.byKey(const ValueKey('follow-row-$_firstId')), findsOneWidget);
    expect(find.byKey(const ValueKey('follow-row-$_secondId')), findsOneWidget);
  });

  await run.check('multi-tag-edit-filter-and-batch-add-remove', () async {
    await run.contextAction(_firstId, 'follow-action-tags');
    await run.createTag(_music);
    await run.createTag(_games);
    await run.tapKey('follow-tags-confirm');
    await run.until(() => database.followBox.get(_firstId)!.tags.length == 2, 'two persisted tags');
    expect(database.followBox.get(_firstId)!.tags, unorderedEquals([_music, _games]));
    await run.tapKey('follow-filter-$_music');
    expect(Get.find<FollowUserController>().list.map((f) => f.id), [_firstId]);
    expect(find.byKey(const ValueKey('follow-row-$_secondId')), findsNothing);
    await run.screenshot('filtered-multiple-tags');
    await run.tapKey('follow-filter-全部');

    await run.contextAction(_firstId, 'follow-action-select');
    await run.tapKey('follow-select-$_secondId');
    expect(Get.find<FollowUserController>().selectedIds.toSet(), {_firstId, _secondId});
    await run.tapKey('follow-batch-tags');
    await run.tapText('添加标签');
    await run.createTag(_shared);
    await run.tapKey('follow-tags-confirm');
    await run.until(() => database.getFollowList().every((f) => f.tags.contains(_shared)), 'batch add persisted');
    await run.screenshot('batch-tags');
    await run.tapKey('follow-batch-tags');
    await run.tapText('移除标签');
    await run.tapKey('follow-tag-option-$_shared');
    await run.tapKey('follow-tags-confirm');
    await run.until(() => database.getFollowList().every((f) => !f.tags.contains(_shared)), 'batch remove persisted');
    expect(database.followBox.get(_firstId)!.tags, unorderedEquals([_music, _games]));
    expect(database.followBox.get(_secondId)!.tags, isEmpty);
    await run.tapKey('follow-selection-close');
  });

  await run.check('manual-drag-pin-and-priority-setting', () async {
    await run.tapKey('follow-menu');
    await run.tapText('手动排序');
    final handle = find.byKey(const ValueKey('follow-order-handle-$_secondId'));
    final target = find.byKey(const ValueKey('follow-order-$_firstId'));
    await run.until(() => handle.evaluate().isNotEmpty && target.evaluate().isNotEmpty, 'manual order dialog');
    final from = run.tester.getCenter(handle);
    final to = run.tester.getCenter(target);
    await run.tester.timedDragFrom(from, Offset(0, to.dy - from.dy - 25), const Duration(milliseconds: 800));
    await run.pump();
    await run.tapKey('follow-order-done');
    expect(database.followBox.get(_secondId)!.manualOrder.compareTo(database.followBox.get(_firstId)!.manualOrder),
        lessThan(0),
        reason: 'Dragging the second room above the first must persist its order.');
    expect(AppSettingsController.instance.followSortMethod.value, SortMethod.manual);
    await run.contextAction(_firstId, 'follow-action-pin');
    await run.until(() => database.followBox.get(_firstId)!.pinned, 'pin saved');
    await run.tapKey('follow-menu');
    await run.tapText('关注设置');
    final priority = find.byKey(const ValueKey('follow-custom-order-priority'));
    await run.until(() => priority.evaluate().isNotEmpty, 'follow settings');
    await run.tester.ensureVisible(priority);
    await run.tester.tap(priority);
    await run.pump();
    expect(AppSettingsController.instance.customOrderBeforeLive.value, isTrue);
    expect(Get.find<FollowUserController>().list.first.id, _firstId,
        reason: 'After selecting custom-order priority, the pinned room precedes actual live rooms.');
    await run.screenshot('follow-order-settings');
    Get.back();
    await run.pump();
    await run.screenshot('pinned-follow-list');
  });

  await run.check('real-lan-modern-and-legacy-round-trip', () async {
    final before = database.getFollowList().map((f) => f.toJson()).toList();
    await run.write('follow-export.json', before);
    final reply = await run.http('/sync/follow?overlay=1', payload: before);
    expect(reply['status'], isTrue);
    await service.loadData(updateStatus: false);
    _assertMetadata(database.getFollowList(), before);
    // A real older peer supplies only the fields it understands. Preserve new
    // metadata already stored locally when receiving that legacy payload.
    final legacy = before
        .map((json) => Map<String, dynamic>.of(json)
          ..remove('tags')
          ..remove('pinned')
          ..remove('manualOrder')
          ..remove('metadataUpdatedAt'))
        .toList();
    final legacyReply = await run.http('/sync/follow', payload: legacy);
    expect(legacyReply['status'], isTrue);
    await service.loadData(updateStatus: false);
    _assertMetadata(database.getFollowList(), before);
    await run.write('lan-round-trip.json', {
      'modern_response': reply,
      'legacy_response': legacyReply,
      'stored_records': database.getFollowList().map((f) => f.toJson()).toList(),
    });
    await run.tapKey('follow-filter-$_music');
    expect(Get.find<FollowUserController>().list.map((f) => f.id), [_firstId]);
    await run.tapKey('follow-filter-全部');
  });

  await run.check('real-webdav-upload-recovery-bidirectional', () async {
    final url = Platform.environment['SLIVE_E2E_WEBDAV_URL'];
    if (url == null) throw StateError('The runner must start an actual local WebDAV server.');
    final client = DAVClient(url, 'e2e', 'local-test-only');
    expect(await client.pingCompleter.future, isTrue);
    final executor = SyncExecutor.instance;
    executor.buildExecutorAttr(client,
        isSyncFollows: true,
        isSyncHistories: false,
        isSyncAccount: false,
        isSyncBlockWord: false,
        isSyncSetting: false);
    final before = database.getFollowList().map((follow) => follow.toJson()).toList();
    await executor.sync(SyncMode.uploadAll);
    final uploaded = await client.recovery();
    expect(uploaded, isNotEmpty);
    final uploadedNames = ZipDecoder().decodeBytes(uploaded).map((file) => file.name).toList();
    expect(uploadedNames, containsAll(['SimpleLive_follows.json', 'SimpleLive_Tags.json']));
    expect(uploadedNames, isNot(contains('SimpleLive_Settings.json')));
    expect(uploadedNames, isNot(contains('SimpleLive_bilibili_account.json')));
    await File('${run.output.path}/webdav-upload.zip').writeAsBytes(uploaded);
    await service.setFollowTags(database.followBox.get(_firstId)!, [_music, _games, _shared]);
    expect(database.followBox.get(_firstId)!.tags, contains(_shared));
    await executor.sync(SyncMode.recoveryAll);
    _assertMetadata(database.getFollowList(), before);
    await executor.sync(SyncMode.bidirectional);
    _assertMetadata(database.getFollowList(), before);
    final remoteBeforeFailure = await client.recovery();
    await File('${run.output.path}/webdav-bidirectional.zip').writeAsBytes(remoteBeforeFailure);
    final rejected = DAVClient(url, 'e2e', 'deliberately-invalid-test-password');
    expect(await rejected.pingCompleter.future, isFalse);
    await expectLater(_executor(rejected).sync(SyncMode.bidirectional),
        throwsA(isA<DioException>().having((error) => error.response?.statusCode, 'actual HTTP status', 401)));
    _assertMetadata(database.getFollowList(), before);
    expect(await client.recovery(), remoteBeforeFailure,
        reason: 'Rejected real DAV access must preserve both local data and the server backup.');
    await run.write('webdav-access-failure.json', {
      'actual_http_status': 401,
      'local_metadata_retained': true,
      'remote_bytes_retained': true,
      'uploaded_resources': uploadedNames,
    });
    await run.write('webdav-observed.json', database.getFollowList().map((f) => f.toJson()).toList());
  });

  await run.check('mpris-real-session-idle-controls', () async {
    expect(Get.isRegistered<MediaSessionService>(), isTrue);
    expect(MediaSessionService.instance.available.value, isTrue, reason: 'A real session D-Bus is required.');
    final properties = await run.mpris('org.freedesktop.DBus.Properties.GetAll', ['org.mpris.MediaPlayer2.Player']);
    expect(properties, contains("'PlaybackStatus': <'Stopped'>"));
    expect(properties, contains("'CanSeek': <false>"));
    for (final command in ['Next', 'Previous', 'Pause', 'Play']) {
      await run.mpris('org.mpris.MediaPlayer2.Player.$command');
    }
    await run.write('mpris-idle-properties.json', {
      'get_all': properties,
      'commands': ['Next', 'Previous', 'Pause', 'Play']
    });
  });

  await run.check('real-webdav-empty-tag-rename-delete-do-not-resurrect', () async {
    const oldName = 'E2E 待改名';
    const newName = 'E2E 已改名';
    const retained = 'E2E 空标签';
    final client = DAVClient(Platform.environment['SLIVE_E2E_WEBDAV_URL']!, 'e2e', 'local-test-only');
    expect(await client.pingCompleter.future, isTrue);
    final executor = SyncExecutor.instance;
    executor.buildExecutorAttr(client,
        isSyncFollows: true,
        isSyncHistories: false,
        isSyncAccount: false,
        isSyncBlockWord: false,
        isSyncSetting: false);
    await service.addFollowUserTag(oldName);
    await service.addFollowUserTag(retained);
    await executor.sync(SyncMode.uploadAll);
    await service.updateTagName(service.followTagList.singleWhere((t) => t.tag == oldName), newName);
    await executor.sync(SyncMode.bidirectional);
    await executor.sync(SyncMode.recoveryAll);
    expect(service.followTagList.map((t) => t.tag), isNot(contains(oldName)));
    expect(service.followTagList.map((t) => t.tag), containsAll([newName, retained]));
    await service.removeFollowUserTag(service.followTagList.singleWhere((t) => t.tag == newName));
    await executor.sync(SyncMode.bidirectional);
    await executor.sync(SyncMode.recoveryAll);
    expect(service.followTagList.map((t) => t.tag), isNot(contains(newName)));
    expect(service.followTagList.map((t) => t.tag), contains(retained));
    await run.write('webdav-tag-definitions.json', database.getAllFollowTagList().map((t) => t.toJson()).toList());
    await File('${run.output.path}/webdav-tag-tombstones.zip').writeAsBytes(await client.recovery());
  });

  await run.check('actual-status-incremental-and-error-preservation', () async {
    final previous = {for (final follow in service.followList) follow.id: follow.liveStatus.value};
    final events = <Map<String, dynamic>>[];
    final subscription = service.updatedListStream.listen((_) {
      events.add({
        'elapsed_ms': run.clock.elapsedMilliseconds,
        'remaining_refreshes': service.followList.where((f) => f.refreshingStatus.value).length,
        'records': [
          for (final f in service.followList)
            {
              'id': f.id,
              'status': f.liveStatus.value,
              'failed': f.statusRefreshFailed.value,
              'refreshing': f.refreshingStatus.value
            }
        ],
      });
    });
    try {
      await service.startUpdateStatus().timeout(const Duration(seconds: 70));
      for (final follow in service.followList.where((f) => f.statusRefreshFailed.value)) {
        expect(follow.liveStatus.value, previous[follow.id], reason: 'A network failure is not an offline response.');
      }
      await run.write('real-status-events.json', events);
      if (service.followList.every((f) => f.statusRefreshFailed.value)) {
        run.blocked('incremental-successful-live-status',
            'Real platform status requests failed; previous/unknown state was retained. See real-status-events.json.');
      } else {
        expect(
            events.any((e) =>
                (e['remaining_refreshes'] as int) > 0 &&
                (e['records'] as List).any(
                    (record) => record['status'] != 0 && record['failed'] == false && record['refreshing'] == false)),
            isTrue,
            reason: 'At least one result must be published before the complete real request batch.');
      }
    } finally {
      await subscription.cancel();
    }
  });

  await run.check('overlapping-real-refresh-and-deletion', () async {
    final before = database.getFollowList().map((follow) => follow.toJson()).toList();
    final first = service.startUpdateStatus();
    expect(service.updating.value, isTrue);
    final newer = service.startUpdateStatus();
    await service.removeFollowUser(_secondId);
    await Future.wait([first, newer]).timeout(const Duration(seconds: 75));
    expect(database.getFollowExist(_secondId), isFalse);
    expect(service.followList.any((follow) => follow.id == _secondId), isFalse,
        reason: 'A late real request must not resurrect a deleted follow.');
    expect(service.updating.value, isFalse);
    expect(service.followList.any((follow) => follow.refreshingStatus.value), isFalse);
    await run.write('overlap-and-delete.json', {
      'remaining_ids': service.followList.map((follow) => follow.id).toList(),
      'deleted_record': database.followBox.get(_secondId)?.toJson(),
      'updating': service.updating.value,
    });
    expect((await run.http('/sync/follow?overlay=1', payload: before))['status'], isTrue);
    await service.loadData(updateStatus: false);
    _assertMetadata(database.getFollowList(), before);
  });

  await _liveScenarios(run);
  await _additionalProviderAudio(run, Constant.kDouyu, '6512');
  await _additionalProviderAudio(run, Constant.kDouyin, '602812384617');
  await run.check('prepare-real-second-profile-sync', () async {
    final client = await _peerDav();
    final item = database.followBox.get(_firstId)!;
    await service.setFollowTags(item, [...item.tags, _peerTag]);
    await _executor(client).sync(SyncMode.uploadAll);
    await File('${run.output.path}/peer-initial-backup.zip').writeAsBytes(await client.recovery());
  });
  await _saveRestartExpectation(run);
}

Future<void> _saveRestartExpectation(_Run run) async {
  final database = DBService.instance;
  await database.followBox.flush();
  await database.tagBox.flush();
  await run.write('restart-expected.json', {
    'records': database.getFollowList().map((f) => f.toJson()).toList(),
    'customOrderBeforeLive': AppSettingsController.instance.customOrderBeforeLive.value,
    'sortMethod': AppSettingsController.instance.followSortMethod.value.name,
  });
}

Future<DAVClient> _peerDav() async {
  final client = DAVClient(Platform.environment['SLIVE_E2E_WEBDAV_URL']!, 'e2e', 'local-test-only',
      webDAVDirectory: '/offline_peer');
  expect(await client.pingCompleter.future, isTrue);
  return client;
}

SyncExecutor _executor(DAVClient client) {
  final executor = SyncExecutor.instance;
  executor.buildExecutorAttr(client,
      isSyncFollows: true, isSyncHistories: false, isSyncAccount: false, isSyncBlockWord: false, isSyncSetting: false);
  return executor;
}

Future<void> _seedPeer(_Run run) async {
  await run.check('second-full-app-profile-restores-real-backup', () async {
    expect(DBService.instance.getFollowList(), isEmpty);
    await _executor(await _peerDav()).sync(SyncMode.recoveryAll);
    expect(DBService.instance.followBox.get(_firstId)!.tags, contains(_peerTag));
    await run.write('peer-seeded-follow.json', DBService.instance.followBox.get(_firstId)!.toJson());
  });
}

Future<void> _ownerDeletesSharedTag(_Run run) async {
  await run.check('owner-deletes-shared-tag-through-real-dav', () async {
    final service = FollowService.instance;
    await service.removeFollowUserTag(service.followTagList.singleWhere((tag) => tag.tag == _peerTag));
    final client = await _peerDav();
    await _executor(client).sync(SyncMode.bidirectional);
    expect(DBService.instance.followBox.get(_firstId)!.tags, isNot(contains(_peerTag)));
    await File('${run.output.path}/owner-deletion-backup.zip').writeAsBytes(await client.recovery());
    await _saveRestartExpectation(run);
  });
}

Future<void> _mergeOfflinePeer(_Run run) async {
  await run.check('offline-peer-pin-cannot-resurrect-deleted-tag', () async {
    final database = DBService.instance;
    final service = FollowService.instance;
    final stale = database.followBox.get(_firstId)!;
    expect(stale.tags, contains(_peerTag), reason: 'This actual second profile has not synced the owner deletion.');
    await service.setPinned(stale, !stale.pinned);
    expect(stale.tags, contains(_peerTag));
    final client = await _peerDav();
    await _executor(client).sync(SyncMode.bidirectional);
    expect(database.followBox.get(_firstId)!.tags, isNot(contains(_peerTag)));
    expect(service.followTagList.map((tag) => tag.tag), isNot(contains(_peerTag)));
    await run.write('peer-after-pin-merge.json', database.followBox.get(_firstId)!.toJson());
    final merged = database.followBox.get(_firstId)!;
    await service.setFollowTags(merged, [...merged.tags, _peerTag]);
    await _executor(client).sync(SyncMode.bidirectional);
    expect(database.followBox.get(_firstId)!.tags, contains(_peerTag),
        reason: 'An explicit tag edit must still be able to recreate a tag.');
    expect(service.followTagList.map((tag) => tag.tag), contains(_peerTag));
    await File('${run.output.path}/peer-explicit-readd-backup.zip').writeAsBytes(await client.recovery());
    await File('${run.output.path}/peer-explicit-readd-export.json').writeAsString(service.generateJson());
  });
}

Future<void> _restart(_Run run) async {
  await run.check('complete-process-restart-retains-metadata-and-filters', () async {
    final expected =
        jsonDecode(await File('${run.output.path}/restart-expected.json').readAsString()) as Map<String, dynamic>;
    _assertMetadata(DBService.instance.getFollowList(), expected['records'] as List);
    expect(AppSettingsController.instance.customOrderBeforeLive.value, expected['customOrderBeforeLive']);
    expect(AppSettingsController.instance.followSortMethod.value.name, expected['sortMethod']);
    await run.openFollows();
    expect(Get.find<FollowUserController>().list.first.id, _firstId);
    await run.tapKey('follow-filter-$_music');
    expect(Get.find<FollowUserController>().list.map((f) => f.id), [_firstId]);
    await run.screenshot('restart-filter-persistence');
    await run.write('restart-observed.json', DBService.instance.getFollowList().map((f) => f.toJson()).toList());
  });
  await run.check('real-export-file-import-explicitly-recreates-tag', () async {
    final service = FollowService.instance;
    expect(service.followTagList.map((tag) => tag.tag), isNot(contains(_peerTag)));
    final capturedExport = File('${run.output.path}/peer-explicit-readd-export.json');
    await service.inputJson(await capturedExport.readAsString());
    expect(DBService.instance.followBox.get(_firstId)!.tags, contains(_peerTag));
    expect(service.followTagList.map((tag) => tag.tag), contains(_peerTag));
    await run.write('file-import-observed.json', DBService.instance.followBox.get(_firstId)!.toJson());
  });
}

void _assertMetadata(List<FollowUser> actual, List<dynamic> expected) {
  expect(actual.map((f) => f.id), unorderedEquals(expected.map((f) => f['id'])));
  for (final json in expected) {
    final follow = actual.singleWhere((f) => f.id == json['id']);
    expect(follow.tags, unorderedEquals(json['tags'] as List));
    expect(follow.pinned, json['pinned']);
    expect(follow.manualOrder, json['manualOrder']);
  }
}

Future<void> _liveScenarios(_Run run) async {
  final live = <(Site, LiveRoomDetail)>[];
  // The baseline native-audio check is specifically Bilibili. A different
  // platform becoming live must not silently substitute for that contract.
  for (final (siteId, preferred) in [
    (Constant.kBiliBili, ['6']),
    (Constant.kHuya, ['danking', '1995']),
  ]) {
    final site = Sites.allSites[siteId]!;
    final detail = await _resolveRealLiveRoom(run, site, preferred, '$siteId-live-discovery.json');
    if (detail != null) live.add((site, detail));
  }
  await run.write('live-api-prerequisites.json', {
    'platform_evidence': ['bilibili-live-discovery.json', 'huya-live-discovery.json'],
    'synthetic_fallback': false,
  });
  if (live.isEmpty) {
    for (final scenario in [
      'native-live-pause-resume',
      'native-audio-only',
      'real-danmaku-reconnect',
      'mpris-live-queue-controls'
    ]) {
      run.blocked(scenario, 'No reachable currently-live public room. See live-api-prerequisites.json.');
    }
    return;
  }
  await run.write('real-room-metadata.json', [
    for (final (site, detail) in live)
      {
        'fetched_utc': DateTime.now().toUtc().toIso8601String(),
        'site': site.id,
        'roomId': detail.roomId,
        'userName': detail.userName,
        'title': detail.title,
        'status': detail.status,
      }
  ]);
  for (final (site, detail) in live) {
    final id = '${site.id}_${detail.roomId}';
    if (!DBService.instance.getFollowExist(id)) {
      await FollowService.instance.addFollow(FollowUser(
          id: id,
          roomId: detail.roomId,
          siteId: site.id,
          userName: detail.userName,
          face: detail.userAvatar,
          addTime: DateTime.now()));
    }
  }
  await FollowService.instance.startUpdateStatus();
  await run.check('custom-order-priority-against-real-live-status', () async {
    final service = FollowService.instance;
    final pinned = service.followList.singleWhere((follow) => follow.id == _firstId);
    if (pinned.liveStatus.value != 1 || !service.followList.any((follow) => follow.liveStatus.value == 2)) {
      throw _ExternalBlock('Actual live APIs did not provide both the pinned offline room and a live room.');
    }
    expect(pinned.pinned, isTrue);
    final page = Get.find<FollowUserController>();
    Future<void> togglePriority() async {
      await run.tapKey('follow-menu');
      await run.tapText('关注设置');
      await run.tapKey('follow-custom-order-priority');
      Get.back();
      await run.pump();
    }

    if (!AppSettingsController.instance.customOrderBeforeLive.value) await togglePriority();
    expect(page.list.first.id, _firstId, reason: 'Configured user priority places the pinned offline room first.');
    await togglePriority();
    expect(AppSettingsController.instance.customOrderBeforeLive.value, isFalse);
    expect(page.list.first.liveStatus.value, 2, reason: 'Live-first priority must reorder the actual mixed list.');
    final liveFirst = page.list.map((follow) => follow.id).toList();
    await togglePriority();
    expect(AppSettingsController.instance.customOrderBeforeLive.value, isTrue);
    expect(page.list.first.id, _firstId);
    await run.write('real-status-order-priority.json', {
      'live_first_order': liveFirst,
      'user_first_order': page.list.map((follow) => follow.id).toList(),
      'real_statuses': {for (final follow in service.followList) follow.id: follow.liveStatus.value},
    });
  });
  await _verifyNativePlayback(run, live.first.$1, live.first.$2);
}

Future<void> _verifyNativePlayback(_Run run, Site site, LiveRoomDetail detail) async {
  LiveRoomController? controller;
  await run.check('native-live-pause-resume', () async {
    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {'roomId': detail.roomId});
    await run.until(() => Get.isRegistered<LiveRoomController>(), 'real live-room route');
    controller = Get.find<LiveRoomController>();
    await run.until(
        () => controller!.playUrls.isNotEmpty || controller!.playbackPaused.value, 'actual platform stream resolution',
        seconds: 75);
    await run.write('native-stream-prerequisites.json', {
      'site': site.id,
      'roomId': detail.roomId,
      'stream_hosts': controller!.playUrls.map((url) => Uri.parse(url).host).toSet().toList(),
      'native_audio_only': controller!.nativeAudioOnly.value,
    });
    await run.until(
        () =>
            controller!.player.state.playing &&
            !controller!.player.state.buffering &&
            (controller!.player.state.width ?? 0) > 0 &&
            controller!.player.state.position.inSeconds > 1,
        'actual native decoding of the real live stream',
        seconds: 75);
    await run.screenshot('actual-live-playback');
    await run.revealControls(controller!);
    await run.tapKey('live-playback-toggle');
    await run.until(() => controller!.playbackPaused.value && controller!.player.state.playlist.medias.isEmpty,
        'soft pause releases the native media');
    final priorDetail = controller!.detail.value;
    await run.revealControls(controller!);
    await run.tapKey('live-playback-toggle');
    await run.until(
        () =>
            !controller!.playbackPaused.value &&
            controller!.player.state.playing &&
            !controller!.player.state.buffering &&
            (controller!.player.state.width ?? 0) > 0 &&
            controller!.player.state.position.inSeconds > 1,
        'fresh live playback after pause',
        seconds: 75);
    expect(identical(controller!.detail.value, priorDetail), isFalse,
        reason: 'Resume must resolve current live metadata, not reopen old buffered media.');
  });
  if (controller == null || !controller!.player.state.playing) {
    for (final scenario in ['native-audio-only', 'real-danmaku-reconnect', 'mpris-live-queue-controls']) {
      run.blocked(scenario, 'Native real live playback prerequisite failed.');
    }
    return;
  }
  final player = controller!;
  await run.check('native-audio-only', () async {
    if (site.id != Constant.kBiliBili) {
      throw _ExternalBlock('No actual Bilibili live room was available for the Bilibili native-audio contract.');
    }
    try {
      await run.revealControls(player);
      await run.tapKey('live-audio-only-toggle');
      await run.verifyProviderAudio(player, 'native-audio');
      await run.screenshot('actual-audio-only');
      await run.revealControls(player);
      await run.tapKey('live-playback-toggle');
      await run.until(() => player.playbackPaused.value && player.player.state.playlist.medias.isEmpty,
          'audio soft pause releases the native source');
      final pausedDetail = player.detail.value;
      await run.revealControls(player);
      await run.tapKey('live-playback-toggle');
      await run.verifyProviderAudio(player, 'native-audio-resumed');
      expect(identical(player.detail.value, pausedDetail), isFalse,
          reason: 'Audio resume must resolve the current room again through the Dart adapter.');
      await run.revealControls(player);
      await run.tapKey('live-audio-only-toggle');
      await run.until(
          () => !player.audioOnly.value && player.player.state.track.video.id != 'no', 'native video track restored');
      await run.decodedPlayback(player, 'restored video decodes and advances after native audio');
    } finally {
      if (player.audioOnly.value) {
        await run.revealControls(player);
        await run.tapKey('live-audio-only-toggle');
        await run.until(() => !player.audioOnly.value, 'leave audio mode after the independent audio check');
      }
    }
  });
  await run.check('real-danmaku-reconnect', () async {
    final panel = find.byKey(const ValueKey('live-danmaku-panel'));
    await run.until(() => panel.evaluate().isNotEmpty, 'actual chat panel');
    final generation = player.danmakuGeneration;
    final media = player.player.state.playlist.medias.toList();
    await run.tester.drag(panel, const Offset(0, -200));
    await run.until(() => player.danmakuGeneration > generation, 'upward gesture reconnects danmaku');
    expect(player.player.state.playlist.medias, media,
        reason: 'Danmaku reconnect must preserve the actual video source.');
    final args = player.detail.value?.danmakuData;
    if (!player.danmakuConnected.value && args is BiliBiliDanmakuArgs) {
      final transport = <String, dynamic>{'host': args.serverHost, 'product_connected': false};
      try {
        final socket = await WebSocket.connect('wss://${args.serverHost}/sub',
                headers: args.cookie.isEmpty ? null : {'Cookie': args.cookie})
            .timeout(const Duration(seconds: 20));
        transport['handshake'] = 'connected';
        await socket.close();
      } catch (error) {
        transport['handshake'] = 'failed';
        transport['error'] = '$error';
        await run.write('danmaku-transport.json', transport);
        throw _ExternalBlock('Real WebSocket handshake failed at ${args.serverHost}; see danmaku-transport.json.');
      }
      await run.write('danmaku-transport.json', transport);
    }
    await run.until(() => player.danmakuConnected.value, 'real replacement danmaku transport connected', seconds: 45);
    await run.write('danmaku-reconnect.json', {
      'before_generation': generation,
      'after_generation': player.danmakuGeneration,
      'native_media_preserved': true
    });
  });
  await run.check('mpris-live-queue-controls', () async {
    final properties = await run.mpris('org.freedesktop.DBus.Properties.GetAll', ['org.mpris.MediaPlayer2.Player']);
    expect(properties, contains('xesam:title'));
    expect(properties, contains("'PlaybackStatus': <'Playing'>"));
    await run.mpris('org.mpris.MediaPlayer2.Player.Pause');
    await run.until(() => player.playbackPaused.value && player.player.state.playlist.medias.isEmpty,
        'system pause reaches native player');
    await run.mpris('org.mpris.MediaPlayer2.Player.Play');
    await run.decodedPlayback(player, 'system play resolves and decodes the live edge');
    final queue = MediaSessionService.instance.liveQueue.toList();
    if (queue.length < 2) {
      run.blocked('mpris-next-previous-multiple-live-rooms',
          'Fewer than two actual live followed rooms; no synthetic live statuses were used.');
    } else {
      final original = player.roomId;
      await run.mpris('org.mpris.MediaPlayer2.Player.Next');
      await run.until(
          () => player.roomId != original && player.player.state.playing, 'system next switches to real next live room',
          seconds: 75);
      await run.decodedPlayback(player, 'system next decodes a progressing real stream');
      await run.mpris('org.mpris.MediaPlayer2.Player.Previous');
      await run.until(
          () => player.roomId == original && player.player.state.playing, 'system previous restores queue room',
          seconds: 75);
      await run.decodedPlayback(player, 'system previous decodes a progressing real stream');
    }
    await run
        .write('mpris-live-properties.json', {'get_all': properties, 'live_queue': queue.map((f) => f.id).toList()});
  });
  await run.check('real-live-queue-tag-filter-and-empty-single-boundaries', () async {
    const queueTag = 'E2E 播放';
    final session = MediaSessionService.instance;
    final currentId = '${player.site.id}_${player.roomId}';
    final follow = DBService.instance.followBox.get(currentId)!;
    await FollowService.instance.setFollowTags(follow, [...follow.tags, queueTag]);
    Get.to(() => const MediaQueuePage());
    await run.tapText('全部关注');
    expect(session.liveQueue, isEmpty, reason: 'A tag-filtered queue with no selected tags is empty.');
    await run.mpris('org.mpris.MediaPlayer2.Player.Next');
    expect('${player.site.id}_${player.roomId}', currentId);
    await run.tapText(queueTag);
    expect(session.liveQueue.map((entry) => entry.id), [currentId]);
    await run.mpris('org.mpris.MediaPlayer2.Player.Next');
    await run.mpris('org.mpris.MediaPlayer2.Player.Previous');
    expect('${player.site.id}_${player.roomId}', currentId,
        reason: 'Single-item queue commands must not replace the current live room.');
    await run.screenshot('actual-live-queue-tag-filter');
    await run.tapText('全部关注');
    expect(session.allFollows.value, isTrue);
    Get.back();
    await run.pump();
  });
  Get.back();
  await run.pump();
}

Future<LiveRoomDetail?> _resolveRealLiveRoom(
    _Run run, Site site, List<String> preferredRooms, String evidenceName) async {
  final attempts = <Map<String, dynamic>>[];
  final visited = <String>{};
  LiveRoomDetail? selected;
  Future<bool> inspect(String roomId, String provenance) async {
    if (!visited.add(roomId)) return false;
    final observation = <String, dynamic>{
      'requested_room': roomId,
      'provenance': provenance,
      'fetched_utc': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final detail = await site.liveSite.getRoomDetail(roomId: roomId).timeout(const Duration(seconds: 25));
      observation.addAll({
        'actual_room': detail.roomId,
        'actual_live_status': detail.status,
        'user_name': detail.userName,
      });
      if (detail.status) selected = detail;
    } catch (error) {
      observation['actual_api_error'] = '$error';
    }
    attempts.add(observation);
    return selected != null;
  }

  for (final roomId in preferredRooms) {
    if (await inspect(roomId, 'previously observed public room')) break;
  }
  if (selected == null) {
    try {
      final recommended = await site.liveSite.getRecommendRooms().timeout(const Duration(seconds: 25));
      for (final room in recommended.items.take(5)) {
        if (await inspect(room.roomId, 'actual current provider recommendation')) break;
      }
    } catch (error) {
      attempts.add({'provenance': 'actual provider recommendation API', 'actual_api_error': '$error'});
    }
  }
  await run.write(evidenceName, {
    'site': site.id,
    'actual_room': selected?.roomId,
    'actual_live_status': selected?.status ?? false,
    'user_name': selected?.userName,
    'attempts': attempts,
    'synthetic_fallback': false,
    'selection_policy': 'Only room availability is discovered; media or audio failures are not skipped.',
  });
  return selected;
}

Future<void> _additionalProviderAudio(_Run run, String siteId, String roomId, {bool enduranceOnly = false}) async {
  final scenario =
      enduranceOnly ? '$siteId-native-audio-endurance-30s' : '$siteId-native-audio-pause-resume-video-restore';
  await run.check(scenario, () async {
    final site = Sites.allSites[siteId]!;
    final detail = await _resolveRealLiveRoom(run, site, [roomId], '$siteId-native-audio-prerequisite.json');
    if (detail == null) throw _ExternalBlock('No actually live $siteId room was available; see prerequisite evidence.');
    await run.until(() => !Get.isRegistered<LiveRoomController>(), 'previous live room disposes');
    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {'roomId': detail.roomId});
    try {
      await run.until(() => Get.isRegistered<LiveRoomController>(), 'actual $siteId live-room route');
      final controller = Get.find<LiveRoomController>();
      await run.decodedPlayback(controller, '$siteId actual video before selecting native audio');
      await run.revealControls(controller);
      await run.tapKey('live-audio-only-toggle');
      if (enduranceOnly) {
        await run.verifySustainedAudio(controller, '$siteId-native-audio');
        await run.screenshot('$siteId-actual-native-audio-after-30s');
        return;
      }
      await run.verifyProviderAudio(controller, '$siteId-native-audio');
      await run.screenshot('$siteId-actual-native-audio');
      await run.revealControls(controller);
      await run.tapKey('live-playback-toggle');
      await run.until(() => controller.playbackPaused.value && controller.player.state.playlist.medias.isEmpty,
          '$siteId audio soft pause releases its actual source');
      final oldDetail = controller.detail.value;
      await run.revealControls(controller);
      await run.tapKey('live-playback-toggle');
      await run.verifyProviderAudio(controller, '$siteId-native-audio-resumed');
      expect(identical(controller.detail.value, oldDetail), isFalse);
      await run.revealControls(controller);
      await run.tapKey('live-audio-only-toggle');
      await run.until(() => !controller.audioOnly.value && controller.player.state.track.video.id != 'no',
          '$siteId leaves native audio mode');
      await run.decodedPlayback(controller, '$siteId restored actual video after native audio');
      await run.screenshot('$siteId-actual-restored-video');
    } finally {
      Get.back();
      await run.pump();
      await run.until(() => !Get.isRegistered<LiveRoomController>(), '$siteId live room disposes');
    }
  });
}

Future<void> _audioSwitchScenarios(_Run run) async {
  // Behavior gaps: a mixed-source toggle must not stop/reload playback, rapid
  // taps must settle on the last choice, paused playback must stay stopped,
  // and the shortcut must not bypass a provider's native audio source.
  Future<void> withRoom(String siteId, List<String> rooms,
      Future<void> Function(LiveRoomController) exercise) async {
    final site = Sites.allSites[siteId]!;
    final detail = await _resolveRealLiveRoom(run, site, rooms, '$siteId-audio-switch-room.json');
    if (detail == null) throw _ExternalBlock('No currently live $siteId room was reachable.');
    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {'roomId': detail.roomId});
    try {
      await run.until(() => Get.isRegistered<LiveRoomController>(), 'actual $siteId live-room route');
      final controller = Get.find<LiveRoomController>();
      await run.decodedPlayback(controller, '$siteId initial live video');
      await exercise(controller);
    } finally {
      Get.back();
      await run.pump();
      await run.until(() => !Get.isRegistered<LiveRoomController>(), '$siteId live room disposes');
    }
  }

  Future<void> toggle(LiveRoomController controller) async {
    await run.revealControls(controller);
    await run.tapKey('live-audio-only-toggle');
  }

  await run.check('huya-continuous-audio-toggle-pause-and-background', () async {
    await withRoom(Constant.kHuya, ['31311340', '457041', 'danking', '1995'], (controller) async {
      final originalUri = controller.player.state.playlist.medias.single.uri;
      final originalDetail = controller.detail.value;
      final originalLine = controller.currentLineIndex;
      final originalQuality = controller.currentQuality;
      var sourceInterrupted = false;
      final playlistSubscription = controller.player.stream.playlist.listen((playlist) {
        if (playlist.medias.length != 1 || playlist.medias.single.uri != originalUri) sourceInterrupted = true;
      });
      try {
        await toggle(controller);
        await run.playingAudio(controller);
        expect(controller.nativeAudioOnly.value, isFalse);
        expect(controller.player.state.playlist.medias.single.uri, originalUri);
        expect(identical(controller.detail.value, originalDetail), isTrue);
        expect(controller.currentLineIndex, originalLine);
        expect(controller.currentQuality, originalQuality);

        await toggle(controller);
        await run.until(() => !controller.audioOnly.value && controller.player.state.track.video.id != 'no',
            'Huya video track restored on the existing source');
        await run.decodedPlayback(controller, 'Huya video after listening');

        // Real consecutive widget taps without waiting for each async native
        // track change. The last tap selects audio; a second burst selects video.
        for (final desiredAudio in [true, false]) {
          await run.revealControls(controller);
          for (var tap = 0; tap < 3; tap++) {
            await run.tester.tap(find.byKey(const ValueKey('live-audio-only-toggle')));
            await run.tester.pump();
          }
          await run.until(
              () => controller.audioOnly.value == desiredAudio &&
                  (controller.player.state.track.video.id == 'no') == desiredAudio,
              'rapid Huya toggles settle on the last selection');
          if (desiredAudio) {
            await run.playingAudio(controller);
          } else {
            await run.decodedPlayback(controller, 'video after rapid toggles');
          }
        }
        expect(sourceInterrupted, isFalse, reason: 'Listening must not stop or replace the playing Huya source.');
      } finally {
        await playlistSubscription.cancel();
      }

      await run.revealControls(controller);
      await run.tapKey('live-playback-toggle');
      await run.until(() => controller.playbackPaused.value && controller.player.state.playlist.medias.isEmpty,
          'pause releases the actual stream');
      final pausedDetail = controller.detail.value;
      await toggle(controller);
      expect(controller.audioOnly.value, isTrue);
      expect(controller.playbackPaused.value, isTrue);
      expect(controller.player.state.playlist.medias, isEmpty);
      await run.revealControls(controller);
      await run.tapKey('live-playback-toggle');
      await run.playingAudio(controller);
      expect(identical(controller.detail.value, pausedDetail), isFalse,
          reason: 'Resuming must fetch the live edge rather than retain buffered playback.');

      final settings = AppSettingsController.instance;
      final previousAutoPause = settings.playerAutoPause.value;
      final backgroundUri = controller.player.state.playlist.medias.single.uri;
      settings.setPlayerAutoPause(true);
      try {
        // Exercise the actual native desktop window, without fabricating a
        // mobile lifecycle callback or replacing the platform implementation.
        await windowManager.hide();
        expect(await windowManager.isVisible(), isFalse);
        // A hidden Flutter window does not produce frames, so tester.pump()
        // cannot complete here. Native media events and wall-clock timers still
        // run; observe those directly until the real window is shown again.
        final hiddenAt = DateTime.now();
        final hiddenPosition = controller.player.state.position;
        while (DateTime.now().difference(hiddenAt) < const Duration(seconds: 3) ||
            controller.player.state.position <= hiddenPosition + const Duration(seconds: 2) ||
            !controller.player.state.playing || controller.player.state.buffering) {
          if (DateTime.now().difference(hiddenAt) > const Duration(seconds: 15)) {
            throw TimeoutException('Actual audio must keep progressing while the window is hidden.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(controller.audioOnly.value, isTrue);
        expect(controller.player.state.track.video.id, 'no');
        expect(controller.player.state.audioParams.sampleRate ?? 0, greaterThan(0));
        expect(controller.player.state.audioParams.channelCount ?? 0, greaterThan(0));
        final pulse = await Process.run('pactl', ['--format=json', 'list', 'sink-inputs'])
            .timeout(const Duration(seconds: 5));
        expect(pulse.exitCode, 0);
        final inputs = jsonDecode(pulse.stdout as String) as List<dynamic>;
        expect(inputs.any((input) =>
            input['corked'] == false && input['properties']['application.process.id'] == '$pid'), isTrue,
            reason: 'The hidden application must still output actual decoded audio.');
        expect(controller.playbackPaused.value, isFalse);
        expect(controller.player.state.playlist.medias.single.uri, backgroundUri);
      } finally {
        await windowManager.show();
        await windowManager.focus();
        settings.setPlayerAutoPause(previousAutoPause);
      }
      await run.playingAudio(controller);
      expect(controller.player.state.playlist.medias.single.uri, backgroundUri);
      await toggle(controller);
      await run.until(() => !controller.audioOnly.value && controller.player.state.track.video.id != 'no',
          'video restored after resumed audio and background playback');
      await run.decodedPlayback(controller, 'Huya final restored video');
    });
  });

  await run.check('bilibili-retains-native-audio-source-switch', () async {
    await withRoom(Constant.kBiliBili, ['6'], (controller) async {
      final videoUri = controller.player.state.playlist.medias.single.uri;
      await toggle(controller);
      await run.playingAudio(controller);
      expect(controller.nativeAudioOnly.value, isTrue);
      final audioUri = controller.player.state.playlist.medias.single.uri;
      expect(audioUri, isNot(videoUri), reason: 'A native audio provider must still replace the video source.');
      expect(Uri.parse(audioUri).queryParameters['ptype'], '1');
      expect(controller.player.state.tracks.video.where((track) => track.id != 'auto' && track.id != 'no'), isEmpty,
          reason: 'The actual provider source must contain no selectable video track.');
      await toggle(controller);
      await run.until(() => !controller.audioOnly.value && !controller.nativeAudioOnly.value &&
          controller.player.state.track.video.id != 'no', 'Bilibili leaves its native audio source');
      await run.decodedPlayback(controller, 'Bilibili video after native audio');
      expect(controller.player.state.playlist.medias.single.uri, isNot(audioUri));
    });
  });
}

class _Run {
  final WidgetTester tester;
  final Directory output;
  final String phase;
  final clock = Stopwatch()..start();
  final results = <Map<String, dynamic>>[];
  final failures = <String>[];
  final imageFailures = <String, String>{};

  _Run(this.tester, this.output, this.phase);

  Future<void> pump() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> until(bool Function() condition, String reason, {int seconds = 20}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException(reason, Duration(seconds: seconds));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await pump();
  }

  Future<void> tapKey(String key) async {
    final finder = find.byKey(ValueKey(key));
    await until(() => finder.evaluate().isNotEmpty, 'control $key');
    await tester.ensureVisible(finder);
    await until(() => finder.hitTestable().evaluate().isNotEmpty, 'visible control $key');
    await tester.tap(finder);
    await pump();
  }

  Future<void> tapText(String text) async {
    final finder = find.text(text);
    await until(() => finder.evaluate().isNotEmpty, 'text $text');
    await tester.tap(finder.last);
    await pump();
  }

  Future<void> openFollows() async {
    Get.toNamed(RoutePath.kFollowUser);
    await until(() => find.byKey(const ValueKey('follow-menu')).evaluate().isNotEmpty, 'real follow page');
    await FollowService.instance.loadData(updateStatus: false);
    await until(() => !FollowService.instance.updating.value, 'initial real status refresh completes', seconds: 90);
    await pump();
  }

  Future<void> contextAction(String id, String action) async {
    final row = find.byKey(ValueKey('follow-row-$id'));
    await until(() => row.evaluate().isNotEmpty, 'follow row $id');
    await tester.ensureVisible(row);
    await until(() => row.hitTestable().evaluate().isNotEmpty, 'visible follow row $id');
    final gesture = await tester.startGesture(tester.getCenter(row));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await pump();
    await tapKey(action);
  }

  Future<void> createTag(String name) async {
    await tapKey('follow-tag-create');
    final field = find.byKey(const ValueKey('follow-tag-name'));
    await until(() => field.evaluate().isNotEmpty, 'tag name field');
    await tester.enterText(field, name);
    await tapKey('follow-tag-create-confirm');
    final option = find.byKey(ValueKey('follow-tag-option-$name'));
    await until(() => field.evaluate().isEmpty && option.hitTestable().evaluate().isNotEmpty,
        'created tag appears in its parent picker');
    expect(tester.widget<ui.CheckboxListTile>(option).value, isTrue);
  }

  Future<void> revealControls(LiveRoomController controller) async {
    if (!controller.showControlsState.value) {
      await tester.tapAt(tester.getCenter(find.byKey(controller.globalPlayerKey)));
      await pump();
    }
  }

  Future<void> decodedPlayback(LiveRoomController controller, String reason) async {
    await until(
        () =>
            !controller.playbackPaused.value &&
            controller.player.state.playing &&
            !controller.player.state.buffering &&
            (controller.player.state.width ?? 0) > 0 &&
            controller.player.state.position.inSeconds > 1,
        reason,
        seconds: 75);
    final position = controller.player.state.position;
    await until(() => controller.player.state.position > position + const Duration(seconds: 1),
        '$reason: playback position advances');
  }

  Future<void> playingAudio(LiveRoomController controller) async {
    await until(
        () => controller.audioOnly.value && !controller.playbackPaused.value &&
            controller.player.state.track.video.id == 'no' && controller.player.state.playing &&
            !controller.player.state.buffering &&
            (controller.player.state.audioParams.sampleRate ?? 0) > 0 &&
            (controller.player.state.audioParams.channelCount ?? 0) > 0,
        'actual audio decoding with video disabled', seconds: 75);
    final position = controller.player.state.position;
    await until(() => controller.player.state.position > position + const Duration(seconds: 2),
        'audio keeps progressing');
    final pulse = await Process.run('pactl', ['--format=json', 'list', 'sink-inputs']);
    expect(pulse.exitCode, 0);
    final inputs = jsonDecode(pulse.stdout as String) as List<dynamic>;
    expect(inputs.any((input) => input['corked'] == false && input['properties']['application.process.id'] == '$pid'),
        isTrue, reason: 'The actual application must output decoded audio.');
  }

  Future<void> verifyProviderAudio(LiveRoomController controller, String prefix) async {
    await until(
        () =>
            controller.audioOnly.value &&
            controller.nativeAudioOnly.value &&
            controller.player.state.track.video.id == 'no' &&
            controller.player.state.playing &&
            !controller.player.state.buffering &&
            (controller.player.state.audioParams.sampleRate ?? 0) > 0 &&
            (controller.player.state.audioParams.channelCount ?? 0) > 0 &&
            controller.player.state.position.inSeconds > 1,
        'the production Dart adapter supplies progressing native provider audio',
        seconds: 75);
    final position = controller.player.state.position;
    await until(() => controller.player.state.position > position + const Duration(seconds: 1),
        'provider audio advances without a video track');
    await write('$prefix-decoder.json', {
      'site': controller.site.id,
      'room_id': controller.roomId,
      'sample_rate': controller.player.state.audioParams.sampleRate,
      'channel_count': controller.player.state.audioParams.channelCount,
      'audio_format': controller.player.state.audioParams.format,
      'video_track': controller.player.state.track.video.id,
      'position_ms': controller.player.state.position.inMilliseconds,
      'native_audio_only': controller.nativeAudioOnly.value,
      'physical_speaker_verified': false,
    });
    final pulse = await Process.run('pactl', ['--format=json', 'list', 'sink-inputs']);
    expect(pulse.exitCode, 0, reason: 'Inspect this run\'s real PulseAudio output: ${pulse.stderr}');
    final inputs = jsonDecode(pulse.stdout as String) as List<dynamic>;
    await write('$prefix-sink-inputs.json', inputs);
    expect(inputs.any((input) => input['corked'] == false && input['properties']['application.process.id'] == '$pid'),
        isTrue,
        reason: 'The application must output its decoded audio to the actual isolated software device.');

    // This is the exact URI already opened by the production controller and
    // native player, including the adapter's unmodified temporary signature.
    // It is never written to public artifacts or passed to a subprocess.
    final media = controller.player.state.playlist.medias.single;
    final sourceUri = Uri.parse(media.uri);
    final hashProcess = await Process.start('sha256sum', []);
    hashProcess.stdin.add(utf8.encode(media.uri));
    await hashProcess.stdin.close();
    final urlHash = (await hashProcess.stdout.transform(utf8.decoder).join()).split(' ').first;
    expect(await hashProcess.exitCode, 0);
    final sourceEvidence = <String, dynamic>{
      'source': 'actual native player Media selected by production Dart adapter',
      'site': controller.site.id,
      'room_id': controller.roomId,
      'scheme': sourceUri.scheme,
      'host': sourceUri.host,
      'path': sourceUri.path,
      'url_sha256': urlHash,
      'query_keys': sourceUri.queryParameters.keys.toList()..sort(),
      'known_audio_flags': {
        for (final key in ['only_audio', 'only-audio', 'aud', 'ptype'])
          if (sourceUri.queryParameters.containsKey(key)) key: sourceUri.queryParameters[key],
      },
      'header_names': (controller.playHeaders?.keys.toList() ?? [])..sort(),
    };
    final capture = File('${output.path}/profile/media-samples/$prefix.flv');
    await capture.parent.create(recursive: true);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final sink = capture.openWrite();
    var bytes = 0;
    final captureClock = Stopwatch();
    StreamSubscription<List<int>>? subscription;
    Timer? deadline;
    try {
      final request = await client.getUrl(sourceUri);
      controller.playHeaders?.forEach((name, value) => request.headers.set(name, value));
      final response = await request.close().timeout(const Duration(seconds: 20));
      sourceEvidence['http_status'] = response.statusCode;
      if (response.statusCode != 200 && response.statusCode != 206) {
        await write('$prefix-source.json', sourceEvidence);
        throw _ExternalBlock(
            'The actual selected audio source returned HTTP ${response.statusCode} at ${sourceUri.host}.');
      }
      final completed = Completer<void>();
      captureClock.start();
      subscription = response.listen((chunk) {
        sink.add(chunk);
        bytes += chunk.length;
        if (bytes >= 2 * 1024 * 1024 && !completed.isCompleted) completed.complete();
      }, onDone: () {
        if (!completed.isCompleted) completed.complete();
      }, onError: (Object error, StackTrace stack) {
        if (!completed.isCompleted) completed.completeError(error, stack);
      });
      deadline = Timer(const Duration(seconds: 10), () {
        if (!completed.isCompleted) completed.complete();
      });
      await completed.future;
    } finally {
      captureClock.stop();
      deadline?.cancel();
      await subscription?.cancel();
      await sink.close();
      client.close(force: true);
    }
    sourceEvidence['captured_bytes'] = bytes;
    sourceEvidence['capture_elapsed_ms'] = captureClock.elapsedMilliseconds;
    final captureHash = await Process.run('sha256sum', [capture.path]);
    expect(captureHash.exitCode, 0);
    sourceEvidence['raw_capture_sha256'] = (captureHash.stdout as String).split(' ').first;
    final rawText = latin1.decode(await capture.readAsBytes());
    final containsSourceCredentials = rawText.contains(media.uri) ||
        sourceUri.queryParameters.values.any((value) => value.length >= 12 && rawText.contains(value));
    sourceEvidence['public_capture'] = containsSourceCredentials
        ? 'withheld: possible source authorization metadata; original retained in private profile'
        : '$prefix.flv';
    if (!containsSourceCredentials) await capture.copy('${output.path}/$prefix.flv');
    await write('$prefix-source.json', sourceEvidence);
    expect(bytes, greaterThan(0), reason: 'The artifact must contain actual provider media bytes.');
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_streams',
      '-show_packets',
      '-show_entries',
      'stream=index,codec_type,codec_name,sample_rate,channels:packet=stream_index,codec_type,size',
      '-of',
      'json',
      capture.path,
    ]).timeout(const Duration(seconds: 20));
    expect(probe.exitCode, 0, reason: 'Parse the unmodified captured provider stream: ${probe.stderr}');
    final observed = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
    observed['stderr'] = probe.stderr;
    await write('$prefix-packets.json', observed);
    final streams = observed['streams'] as List<dynamic>;
    final packets = observed['packets'] as List<dynamic>;
    expect(streams.any((stream) => stream['codec_type'] == 'audio'), isTrue);
    expect(streams.where((stream) => stream['codec_type'] == 'video'), isEmpty,
        reason: 'Disabling the native video decoder must not conceal a video-bearing provider response.');
    expect(packets.where((packet) => packet['codec_type'] == 'audio'), isNotEmpty);
    expect(packets.where((packet) => packet['codec_type'] == 'video'), isEmpty);
    expect(controller.player.state.playlist.medias.single.uri, media.uri,
        reason: 'The captured source must still be the one actually played by this application.');
    expect(controller.nativeAudioOnly.value, isTrue);
  }

  Future<void> verifySustainedAudio(LiveRoomController controller, String prefix) async {
    await until(
        () =>
            controller.nativeAudioOnly.value &&
            controller.audioOnly.value &&
            controller.player.state.track.video.id == 'no' &&
            controller.player.state.playing &&
            !controller.player.state.buffering &&
            controller.player.state.position.inSeconds > 1 &&
            (controller.player.state.audioParams.sampleRate ?? 0) > 0 &&
            (controller.player.state.audioParams.channelCount ?? 0) > 0,
        'actual native audio decoder before the sustained observation',
        seconds: 75);
    final originalMedia = controller.player.state.playlist.medias.single.uri;
    final originalRoom = controller.roomId;
    final originalSite = controller.site.id;
    final sourceUri = Uri.parse(originalMedia);
    final hashProcess = await Process.start('sha256sum', []);
    hashProcess.stdin.add(utf8.encode(originalMedia));
    await hashProcess.stdin.close();
    final sourceHash = (await hashProcess.stdout.transform(utf8.decoder).join()).split(' ').first;
    expect(await hashProcess.exitCode, 0);
    final mapped = await File('/proc/self/maps').readAsLines();
    await write('$prefix-native-libraries.json', {
      'actual_app_pid': pid,
      'libraries': mapped
          .map((line) => line.split(RegExp(r'\s+')).last)
          .where((path) => RegExp(r'lib(mpv|avcodec|avformat|avutil|swresample|swscale)').hasMatch(path))
          .toSet()
          .toList()
        ..sort(),
    });
    final observationClock = Stopwatch()..start();
    final observations = <Map<String, dynamic>>[];
    void observe() {
      final sameSource = controller.player.state.playlist.medias.length == 1 &&
          controller.player.state.playlist.medias.single.uri == originalMedia;
      observations.add({
        'elapsed_ms': observationClock.elapsedMilliseconds,
        'site': controller.site.id,
        'room_id': controller.roomId,
        'same_source': sameSource,
        'native_audio_only': controller.nativeAudioOnly.value,
        'audio_only': controller.audioOnly.value,
        'video_track': controller.player.state.track.video.id,
        'playing': controller.player.state.playing,
        'buffering': controller.player.state.buffering,
        'position_ms': controller.player.state.position.inMilliseconds,
        'sample_rate': controller.player.state.audioParams.sampleRate,
        'channel_count': controller.player.state.audioParams.channelCount,
      });
      expect(controller.site.id, originalSite, reason: 'Sustained audio must not change platform.');
      expect(controller.roomId, originalRoom, reason: 'An ended audio source must not silently advance the queue.');
      expect(sameSource, isTrue, reason: 'Sustained audio must retain the actual provider audio source.');
      expect(controller.nativeAudioOnly.value, isTrue, reason: 'Sustained playback must not fall back to mixed media.');
      expect(controller.audioOnly.value, isTrue);
      expect(controller.player.state.track.video.id, 'no');
    }

    try {
      var position = controller.player.state.position;
      while (observationClock.elapsed < const Duration(seconds: 30)) {
        await until(() {
          observe();
          return controller.player.state.playing &&
              !controller.player.state.buffering &&
              controller.player.state.position > position + const Duration(seconds: 1);
        }, 'native audio continues advancing during the 30-second observation', seconds: 10);
        position = controller.player.state.position;
      }
      observe();
      final pulse = await Process.run('pactl', ['--format=json', 'list', 'sink-inputs']);
      expect(pulse.exitCode, 0);
      final inputs = jsonDecode(pulse.stdout as String) as List<dynamic>;
      await write('$prefix-sink-inputs-after-30s.json', inputs);
      expect(inputs.any((input) => input['corked'] == false && input['properties']['application.process.id'] == '$pid'),
          isTrue,
          reason: 'The same application must still output actual audio after the sustained observation.');
    } finally {
      await write('$prefix-endurance.json', {
        'required_wall_seconds': 30,
        'actual_wall_ms': observationClock.elapsedMilliseconds,
        'physical_speaker_verified': false,
        'original_site': originalSite,
        'original_room': originalRoom,
        'source_host': sourceUri.host,
        'source_path': sourceUri.path,
        'source_url_sha256': sourceHash,
        'known_audio_flags': {
          for (final key in ['only_audio', 'only-audio', 'aud', 'ptype'])
            if (sourceUri.queryParameters.containsKey(key)) key: sourceUri.queryParameters[key],
        },
        'observations': observations,
      });
    }
  }

  Future<String> mpris(String method, [List<String> arguments = const []]) async {
    final process = await Process.run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.mpris.MediaPlayer2.com.slotsun.slive.instance$pid',
      '--object-path',
      '/org/mpris/MediaPlayer2',
      '--method',
      method,
      ...arguments
    ]).timeout(const Duration(seconds: 90));
    expect(process.exitCode, 0, reason: 'Actual MPRIS call $method: ${process.stderr}');
    return process.stdout as String;
  }

  Future<Map<String, dynamic>> http(String path, {Object? payload}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('http://127.0.0.1:${SyncService.httpPort}$path');
      final request = payload == null ? await client.getUrl(uri) : await client.postUrl(uri);
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(payload));
      }
      final response = await request.close().timeout(const Duration(seconds: 20));
      expect(response.statusCode, 200);
      return jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> write(String name, Object? data) =>
      File('${output.path}/$name').writeAsString('${const JsonEncoder.withIndent('  ').convert(data)}\n').then((_) {});

  Future<void> screenshot(String name) async {
    await pump();
    final process = await Process.run('import', ['-window', 'root', '${output.path}/$name.png']);
    expect(process.exitCode, 0, reason: 'Capture actual X11 app output: ${process.stderr}');
  }

  void blocked(String name, String reason) {
    results.add({'scenario': name, 'phase': phase, 'status': 'blocked', 'reason': reason});
  }

  Future<void> check(String name, Future<void> Function() body) async {
    final start = clock.elapsedMilliseconds;
    try {
      await body();
      final exception = tester.takeException();
      if (exception != null) throw exception;
      results
          .add({'scenario': name, 'phase': phase, 'status': 'passed', 'elapsed_ms': clock.elapsedMilliseconds - start});
    } catch (error, stack) {
      if (error is _ExternalBlock) {
        blocked(name, error.reason);
      } else {
        failures.add('$name: $error');
        results.add({
          'scenario': name,
          'phase': phase,
          'status': 'failed',
          'error': '$error',
          'stack': '$stack',
          'elapsed_ms': clock.elapsedMilliseconds - start
        });
      }
      try {
        await screenshot('failure-$phase-${results.length}');
      } catch (_) {/* Preserve original failure. */}
    }
    await write('scenarios-$phase.json', results);
  }

  Future<void> finish() async {
    await write('scenarios-$phase.json', results);
  }

  Future<void> verifyExternalImages() async {
    final sampledHosts = <String>{};
    final evidence = <Map<String, dynamic>>[];
    for (final entry in imageFailures.entries) {
      final uri = Uri.parse(entry.key);
      if (!sampledHosts.add(uri.host)) continue;
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final response = await (await client.getUrl(uri)).close().timeout(const Duration(seconds: 15));
        await response.drain<void>();
        evidence.add({'url': entry.key, 'original_error': entry.value, 'http_retry_status': response.statusCode});
        if (response.statusCode == 200) {
          failures.add('Public image failed in renderer while HTTP retry succeeded: ${uri.host}');
          results.add({
            'scenario': 'public-image-${uri.host}',
            'phase': phase,
            'status': 'failed',
            'error': 'A real image failed; HTTP retry now succeeds. Inspect public-image-errors-$phase.json.'
          });
        } else {
          blocked('public-image-${uri.host}',
              'Real image loading and HTTP retry failed (${response.statusCode}); see public-image-errors-$phase.json.');
        }
      } catch (error) {
        evidence.add({'url': entry.key, 'original_error': entry.value, 'http_retry_error': '$error'});
        blocked('public-image-${uri.host}',
            'Real image loading and real HTTP retry failed; see public-image-errors-$phase.json.');
      } finally {
        client.close(force: true);
      }
    }
    if (evidence.isNotEmpty) await write('public-image-errors-$phase.json', evidence);
  }
}

class _ExternalBlock implements Exception {
  final String reason;
  _ExternalBlock(this.reason);
}
