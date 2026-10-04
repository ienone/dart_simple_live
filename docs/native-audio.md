# Native live audio

The existing audio-mode control now resolves a provider-native audio source when
the provider explicitly supplies one. The player still disables the video track.
If the optional lookup fails or the provider has no usable audio source, playback
keeps the ordinary live source with video decoding disabled. That fallback still
downloads any video carried by the source.

## Provider contracts

| Provider | Request / response contract | Selection boundary |
| --- | --- | --- |
| Bilibili | `getRoomPlayInfo` with `only_audio=1`; use the returned `http_stream/flv/avc` URL with server-issued `ptype=1`. | Preserve the complete returned URL and headers. The same response can contain mixed HLS; never mark those URLs audio-only merely because the request used the flag. An explicit HLS audio rendition remains a separate valid source. |
| Douyu | Signed `getH5PlayV1` with `fa=1`, `hevc=0`, `rate=0`; accept returned URLs identifying `only-audio=1`. | The audio request has its own quality contract. It must not overwrite the user's selected video quality or invent a CDN query parameter. |
| Douyin | Use the official `live_core_sdk_data.pull_data.stream_data.data.ao.main` resource, retaining `only_audio=1` and its signature. | Current official HTML can store `stream_data` as a React Flight text reference such as `$13`; resolve that referenced text before parsing its JSON. Missing or unusable audio data falls back safely. |
| Huya | A usable native audio source for ordinary rooms has not been verified. | Keep the decoder-disabled fallback. Official SDKs can select audio subscriptions, but a capability enum or successful proxy allocation does not prove that the requested media exists. The separate `_audio.flv` FLAC path is gated by a compatible-stream flag. |

The capability remains optional through `LiveAudioSource.getAudioOnlyUrls`.
Source resolution is subject to the existing playback generation checks, so a
late result cannot undo pause, room switching or disposal. Returning from a native
audio source resolves the ordinary video source again. Source-resolution errors are logged
without exposing stream URLs or implementation details in the UI.

## Switching modes without reconnecting

For an already playing mixed source, Huya switches the existing player's video
track between `VideoTrack.no()` and `VideoTrack.auto()`. The URL, selected line and
audio connection stay in place. Native player operations remain serialized;
pause and room changes invalidate older operations. Screen-awake behavior updates
with the selected mode. A failed track change falls back to resolving a new source.
Paused playback stays stopped, and resume still resolves the current live edge.

The reference [pure_live](https://github.com/liuchuancong/pure_live/tree/958f72156304af4228c064cbef9e043ea1f3517a)
also uses ordinary Huya streams. Its manual listening mode hides video; background
and ASMR playback can disable the video track. We retain decoder disabling during
manual listening and borrow the continuous-connection behavior. This saves video
decoding work, but does not remove video bytes from Huya's network stream.

Run the focused real-app check with
`SLIVE_E2E_PHASES=audio-switch scripts/e2e/issue-146.sh /tmp/slive-audio-switch-<run>`.
It covers Huya mode changes, rapid taps, pause/resume and desktop window hiding,
plus Bilibili native audio and video restoration.

2026-10-04: the focused Linux run passed all three scenarios (startup, Huya,
Bilibili), using real live streams, the native player and PulseAudio output.

## Evidence and limits

Research used current official responses and immutable open-source revisions:

- [PiliPlus: Bilibili audio request](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/334d758127c8126e7f3bb3df7470b3229bc9b0ee/lib/http/live.dart#L81-L100).
- [biliLive-tools: Douyu signed audio request](https://github.com/renmu123/biliLive-tools/blob/fc72b6e639e3589fb7ede13bcef0c561336f0521/packages/StreamGet/src/douyu/h5-play-v1.ts#L36-L53).
- [biliLive-tools: Douyin official audio quality](https://github.com/renmu123/biliLive-tools/blob/fc72b6e639e3589fb7ede13bcef0c561336f0521/packages/DouYinRecorder/src/douyin_api.ts#L548-L597).

The cloud research records and raw-stream probes are in
`/workspace/task-artifacts/audio-research/`; the consolidated implementation
verification is written to `/workspace/task-artifacts/audio-research/verification.md`.
These observations describe the rooms, formats and dates in their records, not a
permanent guarantee about every provider CDN or account.

The 2026-10-04 Huya follow-up tested ordinary game and entertainment rooms. The
existing official Web `AudioMgr` sent an actual request while a game room's video
was playing; the server returned `EGetVP_FUZZY_NO_MATCH`. A separate PCDN experiment
used the official schema and real ordinary stream names: both video codec 440 and
AAC codec 35 were allocated successfully, with codec 35 retained in the response.
The game room's actual AL and TX video `.slice` downloads were HTTP 200 and decoded
to AAC plus H.264. Its official AAC codec 35/36/37 candidates returned HTTP 404 on
both CDNs using fresh official tokens. These
are different results: signaling success alone must never mark a source native
audio. The follow-up evidence and repeatable tools are in
`/workspace/task-artifacts/huya-native-audio-20261004/`.

This establishes the tested request outcomes, not that Huya has no ordinary-room
audio capability. A real application session must still receive and decode a
usable audio source before this provider implements `LiveAudioSource`. Hiding the
video surface, background playback, or a proprietary SDK's unsubscribe API is
insufficient evidence of reduced network traffic.

Checks capture the actual server response bytes, without removing video locally,
and inspect both stream types and packet counts. Native application checks must
also show progressing playback and real audio output, then successfully restore
video. Download-byte comparisons are samples, not fixed savings promises.

See [the real E2E workflow](testing/issue-146-e2e.md) for the full application run.
No synthetic stream, mocked provider response or new unit test is used to certify
this feature. Signed stream URLs and private cookies are excluded from shared
artifacts; fresh URLs are resolved on each repeat run.
