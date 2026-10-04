import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/interface/sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/blockwords_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/follow_block_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/follow_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/history_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/settings_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/user_account_cookie_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/common/sync_mode.dart';
import 'package:simple_live_app/requests/webdav_client.dart';
import 'package:simple_live_app/services/follow_service.dart';

class SyncExecutor {
  static final SyncExecutor instance = SyncExecutor._();

  late DAVClient _davClient;

  SyncExecutor._();

  final List<SyncResource> _resources = [];
  bool _syncing = false;

  void buildExecutorAttr(
    DAVClient davClient, {
    bool isSyncFollows = true,
    bool isSyncHistories = true,
    bool isSyncBlockWord = true,
    bool isSyncAccount = true,
    bool isSyncSetting = true,
  }) {
    _davClient = davClient;
    _resources.clear();
    _resources.addAll([
      if (isSyncHistories) HistorySyncResource(),
      if (isSyncFollows) FollowSyncResource(),
      if (isSyncBlockWord) BlockwordsSyncResource(),
      if (isSyncAccount) UserAccountCookieSyncResource(),
      if (isSyncSetting) SettingsSyncResource(),
      FollowBlockSyncResource(),
    ]);
  }

  // fetch -> local-> remote -> select sync-mode
  // migration is needed after recover data from remote
  // migration depends on setting-kHiveDbVer, user did not select sync setting maybe
  // todo: version.json is required, plan to implement this feature in v1.8.10
  Future<void> sync(SyncMode mode) async {
    if (_syncing) {
      throw StateError('同步正在进行');
    }
    _syncing = true;
    final davClient = _davClient;
    final resources = List<SyncResource>.of(_resources);
    try {
      // Keep edits/imports queued until their shared snapshot is committed.
      // The follow service lock is reentrant, including the resource receiver.
      await FollowService.instance.withFollowWrite(() async {
        final remoteArchive = await _doWebDAVFetch(davClient);
        if (remoteArchive == null && mode == SyncMode.recoveryAll) {
          throw StateError('云端没有备份');
        }
        final uploadArchive = Archive();
        // Preserve resources the user did not select for this sync.
        if (remoteArchive != null) {
          for (final file in remoteArchive) {
            uploadArchive.addFile(file);
          }
        }
        final pendingWrites = <Future<void> Function()>[];

        for (final resource in resources) {
          final local = await resource.loadLocal();
          final remote = remoteArchive == null ? null : resource.loadRemote(remoteArchive);

          switch (mode) {
            case SyncMode.uploadAll:
              resource.saveRemote(uploadArchive, local);
              break;
            case SyncMode.recoveryAll:
              if (remote != null) {
                pendingWrites.add(() => resource.saveLocal(remote));
              }
              break;
            case SyncMode.bidirectional:
              final merged = remote == null ? local : resource.merge(local, remote);
              resource.saveRemote(uploadArchive, merged);
              pendingWrites.add(() => resource.saveLocal(merged));
              break;
          }
        }

        if (mode != SyncMode.recoveryAll) {
          final zipBytes = ZipEncoder().encode(uploadArchive);
          if (!await davClient.backup(Uint8List.fromList(zipBytes))) {
            throw StateError('WebDAV 上传失败');
          }
        }
        // A failed upload must not clear the unsynced local viewing duration.
        for (final save in pendingWrites) {
          await save();
        }
      });
    } finally {
      _syncing = false;
    }
  }

  // 拉取webdav已有备份
  Future<Archive?> _doWebDAVFetch(DAVClient davClient) async {
    List<int> data;
    Archive? archive;
    try {
      data = await davClient.recovery();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
    archive = await Isolate.run<Archive>(() {
      final zipDecoder = ZipDecoder();
      return zipDecoder.decodeBytes(data);
    });
    return archive;
  }
}
