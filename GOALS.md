# Issue #146 implementation goal

Source: https://github.com/SlotSun/dart_simple_live/issues/146 (owner: `ienone`).

Deliver all seven requested improvements in this fork, starting with the independently useful follow-list changes (7, 6, 5). Keep the UI restrained and retain full room refresh. Upstream discussion raises synchronization, danmaku alignment and platform-audio constraints; address those explicitly rather than silently dropping the requested behavior.

## Baseline

- Fork baseline: `23a09a35b30e2180824ccd9038879868578fa8fa`.
- Synced upstream master: `25e55686e90639c3f2b52bf20f5971538f2a781e` (10 commits, fast-forward, no conflicts). Recovery branch: `backup/before-upstream-issue-146`.
- No fork-only or local-only commits were present at synchronization.
- Upstream requires Flutter 3.47.5. The cloud SDK has been upgraded to that version (Dart 3.13.4), and locked dependency restoration passed.

## Implementation goals

Checked items mean the behavior is implemented. Runtime acceptance and remaining platform/network prerequisites are recorded separately in the verification report below.

- [x] **7 — Pinning and manual order:** persist a user's order/pins; expose concise actions; allow their priority relative to live status to be configured; retain ordinary sorting and cross-device compatibility.
- [x] **6 — Multiple tags and batch tagging:** one follow can belong to multiple tags; tag filtering remains correct; select several follows and apply/remove tags together; migrate old single-tag data without loss; round-trip LAN/WebDAV/export/import data.
  - macOS follow-up: multi-select now supports drag ranges, shrinking a range, dragging to deselect and edge auto-scroll in compact/card layouts. Native E2E passed with persisted follows, normal clicks, wheel and trackpad scrolling.
- [x] **5 — Incremental live status:** apply each valid status result as it arrives, reorder the visible list without waiting for the batch, and handle cancellation/repeated refresh/deleted follows/failed requests safely.
- [x] **1 — Danmaku reconnect:** upward gesture on the danmaku panel reconnects only danmaku and clears stale queued messages; retain full player refresh and remove the redundant out-of-player refresh control.
  - macOS follow-up: added pull/release/connecting/result feedback with desktop dragging, disabled automatic loading, and wait for WebSocket readiness. Real macOS integration passed short-pull cancellation, release-only single reconnect, visible states and unchanged video source.
- [x] **2 — Soft pause:** player and system controls stop live playback on pause; resume obtains a current live stream rather than playing old buffered content; room changes and failures leave consistent state.
- [x] **3 — Audio-only:** provide a minimal mode control, disable video decoding/rendering, prefer verified native audio streams where available, and preserve playback across mode changes and background transitions.
- [x] **4 — System media and queue:** a shared session exposes room metadata, play/pause and previous/next; real platform adapters cover Android/Apple, Windows and Linux; the queue includes live followed rooms, supports all/tags and configured ordering, and handles start/end transitions.

## Behavioral failure inventory (written before implementation)

- Follow data: missing/new/legacy fields; empty/duplicate/renamed/deleted tags; old peer payloads; concurrent imports; lost manual order; pins that disappear after restart; status sort overriding a user's configured priority.
- Refresh: overlapping batches; navigating away; a follow deleted mid-request; timeout/rate-limit treated as offline; stale batch overwriting a newer result; list jumps that reset the scroll position.
- Playback: pause during stream resolution; resume after stream URL expiry; late results after room switch; duplicate players; audio/video switch races; stale danmaku after reconnect; disposal while reconnecting.
- Media session/queue: OS commands before initialization/after disposal; empty/single-item queue; offline/deleted current room; tag membership changes; missing native backend; an OS pause that differs from the in-app pause.
- End-to-end prerequisites: missing display/session bus/device, unavailable live API or required account, unsaved plugin/toolchain updates. Record these as blocked, never simulated success.

## Validation plan

Use Flutter's real Linux application integration runner and native platform/API boundaries; this is not a web application. Capture the actual persisted/serialized data and screenshots at observable checkpoints. Do not create post-implementation unit tests. Golden expectations must derive from real captured records. Keep real-service tests distinct from local application flows and report device-only checks that cannot run here.

Record the test commands and meaningful results briefly. Keep useful diagnostic logs; do not create separate reports or evidence packages by default. Additional work is limited to migration, synchronization, accessibility, lifecycle and build fixes necessary for these seven goals.

## Implementation delivered

All seven code paths are implemented; implementation completion is separate from the real-run acceptance results. Follow editing uses existing contextual menus and compact dialogs. Pin/order/tag metadata is persisted in Hive and synchronized through legacy-compatible JSON, LAN, SignalR and WebDAV. Versioned tag deletion records prevent old peers or unrelated pin edits from resurrecting removed tags. An entirely empty legacy follow-array file/SignalR message cannot carry standalone tag definitions; LAN's separate tag resource and WebDAV can.

Pause stops the native player and resume resolves current room/stream data. Playback, room changes, danmaku and queued native operations have cancellation guards. The chat-panel gesture reconnects its transport and clears old messages without reopening video. Audio mode disables video decoding and prefers native audio: Bilibili's `only_audio=1` FLV response, Douyu's signed `fa=1` response, and Douyin's official `ao` resource. Mixed HLS is not inferred to be audio-only from a request flag. Huya retains the decoder-disabled fallback until a usable general audio source is verified. Provider contracts, source research and current validation references are documented in `docs/native-audio.md`.

System controls use one shared live-follow queue, with Android/Apple audio_service, Windows audio_service_win and Linux D-Bus MPRIS adapters. Queue filtering follows the selected tags and persisted ordering. Real Android, Apple and Windows device checks remain required; Linux cannot certify them.

The 2026-10-04 Huya ordinary-room follow-up distinguishes successful audio proxy allocation from actual media delivery. Official PCDN accepted an AAC group, but the tested AAC media request failed while its video control succeeded. This does not establish universal absence of audio support; the provider stays on the documented fallback until real audio delivery is verified. Detailed observations and reproduction tools are in `/workspace/task-artifacts/huya-native-audio-20261004/`.

- [ ] **Huya native audio follow-up:** obtain actual audio-only media for ordinary rooms, then implement and verify real playback, mode restoration and lifecycle cancellation. Proxy allocation or a visible audio control alone does not complete this goal.

Following the owner's `pure_live` reference, Huya now switches a playing mixed source between video and listening without reconnecting. It keeps the current URL and line, serializes rapid mode changes, updates screen-awake behavior, and preserves soft pause/live-edge resume. Native-audio providers still switch to their audio source. `pure_live` does not supply a separate ordinary-room Huya audio URL.

Necessary adjacent fixes include Linux startup/quality selection without NetworkManager's system bus, safe tag-dialog submission, status-refresh slot wakeups after cancellation, old JSON watch-duration migration, and removal of the floating debug-log button/banner. Obsolete counter/Rust demo test templates were removed. The issue-specific test harness was removed at the owner's request after real-application validation.

## Runtime acceptance

### macOS existing-profile acceptance (2026-10-04)

Real application checks passed for multi-tag editing/filtering/batch changes,
manual order/pinning, native soft pause/resume, Huya decoder-only listening and
rapid mode changes, and live queue filtering/next/previous. Fixed playback/audio
buttons not resetting control auto-hide and desktop calls to unregistered mobile
brightness plugins. One full rerun timed out decoding video after Previous;
a focused queue rerun passed, so the intermittent timeout remains unexplained.
No physical OS media-button or cross-device sync claim. Original six Hive files
were restored and matched the pre-test backup hashes before normal debug launch.

## Side-by-side test packages

`publish_app_test.yaml` builds tags named `test-*` into a prerelease with Android,
iOS, macOS, Windows and Linux packages. CI applies `scripts/prepare_test_build.py`
to its disposable checkout; formal builds retain their existing identity.
Android uses the fixed `TEST_ANDROID_KEYSTORE_BASE64` repository secret, iOS is unsigned, macOS is ad-hoc signed and
Windows is unsigned. Test application IDs and desktop data directories are
separate from the formal app. Firebase is disabled in the test packages.
