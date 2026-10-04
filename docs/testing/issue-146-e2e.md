# Issue #146 real application verification

## Acceptance and failure cases (defined before test implementation)

The runner starts `simple_live_app.main`, including Rust, Hive, media_kit, real desktop plugins and the actual LAN HTTP server. It uses a fresh, isolated XDG profile; it does not replace live sites, storage, players, network responses or platform channels. All assertions are behavioral. No new unit tests or generated-response golden files are used.

1. **Startup and native boundaries.** The first-run agreement can be accepted, the actual home/follow UI appears and the application's real `/info` HTTP endpoint answers. Missing display, Rust library, session bus, plugins or a port occupied by another app must fail visibly.
2. **Follow editing.** Create local follow records through the application's own service using public room identities, apply two tags through the UI, select both records and add/remove a tag in a batch, pin one record, move a record and change custom-order priority. Verify the rendered selection/filter/order and persisted data. Cancelled dialogs, stale tag indexes, inadvertent replacement of another tag, pin loss or a move that is not saved are failures. If metadata cannot be fetched, local records may use the public room identifiers already present in `simple_live_core/test/simple_live_core_test.dart`; they are user-created follow data, not fabricated service responses. Live API availability is reported separately.
3. **LAN and compatibility.** Send the app's genuine serialized follow records over HTTP to its `/sync/follow` route; verify tags/pin/order survive. Submit the equivalent legacy single-tag payload through that same real route, verifying the compatibility policy (existing local new metadata survives). No stub server stands in for a peer or live platform.
4. **Restart durability.** Exit and start the complete application again with the same isolated profile. Check tags, pin/order, settings and tag filters against the prior run's captured persisted records. A successful in-memory edit that disappears on restart is a failure.
5. **Incremental status.** Subscribe to the real service update stream while refreshing live-site APIs. Verify completed items become visible before the batch is complete, and overlapping refreshes/deletion do not resurrect removed follows. Unreachable/rate-limited APIs must be recorded as blocked for live behavior, and must not turn an unknown status into offline.
6. **Live playback.** Resolve a real currently-live public room and play its actual network stream through media_kit. Soft pause empties the active media playlist; resume resolves and starts the live edge. Audio-only disables the video track and must decode progressing audio with a valid native sample rate/channel count. The actual application must have an uncorked stream on the isolated PulseAudio software output. This verifies real stream decoding/output without claiming physical-speaker coverage. Dragging upward at the danmaku panel bottom changes the connection generation and clears stale queued messages without reopening the media. Failure to obtain/decode real video or connect a real danmaku server is blocked/failed with evidence, never substituted with a synthetic stream.
7. **System session and queue.** Query the actual Linux session bus, inspect MPRIS metadata/status and invoke Pause/Play/Next/Previous. Assert these commands reach the same native player/queue, tags constrain eligible real live follows and empty/single queues are safe. Other OS adapters require their actual devices and are explicitly outside the Linux execution result.
8. **Real WebDAV and tag definitions.** Upload to a real local WsgiDAV service, change local tags, recover the genuine uploaded ZIP, and perform bidirectional synchronization. Rename/delete a previously uploaded empty tag and synchronize/recover again: old names must not reappear, while intentionally created empty tags remain. Missing remote backup must initialize on upload; invalid DAV access must report failure without clearing local data. The server is an actual DAV implementation bound to loopback, with its own isolated directory and disposable test credentials.
9. **An actual offline peer.** Start a second complete application with a separate XDG/Hive profile, restore the real initial DAV backup, then stop it. Restart the owner, delete a shared tag and synchronize. Restart the peer with its older disk records and change only a pin: bidirectional sync must respect the owner's deletion. An explicit tag edit can recreate it. Import the peer's genuine exported file into the owner to verify the same rule at the file boundary. No fabricated peer payload or mocked clock is used.

## Running and artifacts

Run from the repository root:

```sh
source /workspace/toolchains/activate.sh
scripts/e2e/issue-146.sh /workspace/artifacts/issue-146
```

The runner requires Linux build prerequisites, Xvfb (or an existing display), a session D-Bus, ImageMagick `import`, FFmpeg's `ffprobe`, WsgiDAV/cheroot, PulseAudio with its ALSA plugin, and installed Flutter dependencies. The cloud installation provides `/workspace/toolchains/audio-session.sh` (override with `SLIVE_E2E_AUDIO_HELPER`), which starts an owned PulseAudio daemon, a software null sink and an ALSA default-device configuration. The runner stops only its own daemon; its native audio evidence includes `pactl` output. It starts the actual app five times (`exercise`, `peer-seed`, `owner-delete`, `peer-merge`, `restart`) while retaining the two separate real profiles. Proxy environment variables are used for actual HTTPS transport while preserving `NO_PROXY` for local endpoints; TLS verification stays enabled. Ensure no other Slive process owns ports 23234/23235.

Each run retains scenario results, logs, screenshots and captured non-secret follow records. Full source patches and hash manifests are optional (`SLIVE_E2E_SEAL_ARTIFACTS=1`). The restart comparison uses a snapshot captured from the earlier process as its persistence golden. Temporary URL queries and credential-bearing log lines are redacted. Reusing the output directory is rejected to avoid mixing runs. Exit 0 means all selected Linux scenarios passed; exit 2 means external prerequisites prevented full verification; other failures return nonzero. Public-image errors undergo a real HTTP retry: inaccessible images are blocked, while a renderer error with successful HTTP is failed. A screenshot is actual application output, not a baseline image comparison.

For audio-mode changes alone, run:

```sh
SLIVE_E2E_PHASES=audio-switch scripts/e2e/issue-146.sh /tmp/slive-audio-switch-<run>
```

This checks a real Huya room: switching modes keeps its source open, rapid taps
settle on the last mode, pause stays stopped and resume fetches the live edge.
Audio must progress through the native player and PulseAudio, including while the
desktop window is hidden. Bilibili must still switch to its native audio source
and restore video. Desktop hiding does not certify Android/iOS lifecycle behavior.

## Native provider audio acceptance (before the additional test implementation)

The earlier decoder-disabled fallback is insufficient evidence for provider audio-only transport. Preserve all five full-process phases and the existing 26 baseline scenarios. Additional provider checks must use the actual application's Dart adapter and the URL opened by its native player.

- A provider may ignore an audio request, return an ordinary video URL, or expose an audio-named rendition that still carries video. Require the app's native-audio state, actual progressing native audio output, and a genuine short capture of the same selected stream. `ffprobe` must observe audio packets and no video stream or video packets. Disabling the player's video track alone does not meet this condition.
- Audio parameters, codec choices, CDN selection, signing and headers can drift. Preserve the official returned URL/headers through the production adapter; do not rewrite a test URL to manufacture audio mode. Record only its hash, host/path, parameter names and known audio flags in public evidence. Never publish a signed URL, cookie or authorization header. Keep the unmodified capture in the private profile; publish an identical copy only after checking it does not contain the source URL or long query values in metadata.
- The source may be unreachable or the room may stop broadcasting. First inspect the previously observed public room; if it is unavailable, inspect the same provider's current recommendations and confirm an online room through its real detail API. Record every attempted room and its provenance. Room discovery must not skip a selected room merely because its audio source or decoding fails. Keep the Bilibili baseline explicitly on Bilibili. Record the real HTTP/API/decoder evidence and distinguish an external prerequisite from an adapter assertion failure; never substitute fixtures or a synthetic media source.
- Resuming after soft pause and restoring video can accidentally reuse stale audio URLs or leave the decoder disabled. Exercise real audio pause/resume, require a fresh room resolution and another verified audio stream, then restore decoded progressing video. Existing in-app and MPRIS live-edge/queue checks remain active.
- Optional native-audio resolution can fail or finish after a room change. A fallback must remain audio playback with video disabled; late audio results must not reopen a disposed or replaced room. Do not claim that a failure/race branch ran unless a genuine event exercised it.
- Verify Bilibili's actual provider audio request in the baseline audio scenario. Add the same real application checks for reachable currently-live Douyu and Douyin rooms supplied by current official responses. Huya requires positive server-audio evidence before a native-audio success claim; its ordinary-stream fallback is a separate capability.

## Sustained native audio follow-up

The real Douyu check exposed a distinct transport behavior: a fresh source could
return a short, normally terminated HTTP/1.1 body through the cloud proxy while
the same official URL supplied continuous audio over HTTP/2. A four-second
native-player observation does not establish sustained playback. Before adding
this check, its failure cases are: native playback stops at short EOF, progress
stalls, the controller silently returns to mixed media, a queue transition opens
a different room, or the software audio output is corked after the sample.

Run the focused real-application phase without repeating the five persistence
phases:

```sh
SLIVE_E2E_PHASES=native-endurance scripts/e2e/issue-146.sh /workspace/artifacts/native-audio-endurance
```

This still launches the complete application with an isolated real profile and
native plugins. Each provider must keep the same native audio source and room
while its playback position advances for at least 30 seconds of wall time; the
prior full run already preserves raw-media composition evidence, and the actual PulseAudio output is inspected again at the end.
Every observation and the selected phase list is recorded. A stopped, stalled,
changed or mixed source fails this check; a successful short capture cannot hide
that failure. The previously sealed full run remains separate evidence.
