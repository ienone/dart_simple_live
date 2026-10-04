# Feature branches and upstream PRs

`ienone/dart_simple_live:master` is the integration branch: it contains all seven
issue #146 features and fork-specific working notes.
Keep it usable for daily development. Feature branches preserve reviewable work;
do not use the integration branch as the head of a single-feature upstream PR.

## Current feature stack

The tested baseline is upstream `master` at `25e5568`. These are dependent stacks,
not seven branches that can all be submitted independently at the same time.

| Idea | Branch | Feature commit | Prerequisite |
| --- | --- | --- | --- |
| 6: multiple tags and batch tagging | `feature/follow-tags` | `7e66a03c917c` | baseline |
| 7: pinning and manual order | `feature/follow-order` | `6ab97adec32c` | follow-tags |
| 5: incremental live status | `feature/follow-live-status` | `e3ae86896dce` | follow-order |
| 1: independent danmaku reconnect | `feature/danmaku-reconnect` | `bba771a21028` | baseline |
| 2: soft pause and live-edge resume | `feature/live-soft-pause` | `0eb42bc434c0` | danmaku-reconnect |
| 3: listening mode and native audio | `feature/audio-only` | `b62899633aad` | live-soft-pause |
| 4: system controls and live queue | `feature/media-session-queue` | `b40e9b96f68f` | both complete stacks |

The media branch merges the two prerequisite stacks before its own feature commit.
Subsequent integration commits adapt Douyin room-ID migration to the new follow
model, initialize Flutter before platform calls, and remove debug overlays. These
integration fixes remain on `master`.

## Continuing development

For a new feature, branch from its narrowest required feature branch. For example:

```sh
git switch -c feature/audio-focus feature/audio-only
# Implement and commit the new feature here.
git push -u origin feature/audio-focus
git switch master
git merge --no-ff feature/audio-focus
git push origin master
```

Changes that should stay fork-only can branch from `master`. Merge upstream
updates into `master` normally; do not reset the fork to upstream or rewrite the
published integration history. Do not merge `master` back into a PR branch: that
would pull unrelated features into its diff.

## Preparing an upstream PR

The issue discussion mentions upstream `dev`. It has diverged substantially from
`master`, so these tested master-based branches are **not ready-made PR heads for
dev**. Confirm the target, then create a fresh `pr/*` branch from that target and
cherry-pick only the selected feature commit. Resolve any porting conflicts and
test the resulting branch before opening the PR. For the first tags PR:

```sh
git fetch upstream
git switch -c pr/follow-tags upstream/dev
git cherry-pick 7e66a03c917c
# Resolve any conflicts, then test the port against dev.
git diff --stat upstream/dev...HEAD
git push -u origin pr/follow-tags
```

For dependent features, land the prerequisite first, fetch the updated target,
and create the next `pr/*` branch from it. Cherry-pick that feature's commit only;
do not replay prerequisite commits already merged or squash-merged upstream.
GitHub cannot use a fork-only prerequisite branch as the base of a PR in the
upstream repository. Until prerequisites land there, a later PR will include
them; label it dependent or wait. The follow stack is the natural first set of
upstream PRs given the maintainer's response in issue #146.

The split preserves the previously tested integrated product code. Every feature
tip was checked with `dart analyze --format machine lib` in the real app checkout
(no errors; existing deprecation/unused warnings remain). This does not replace
testing a later port to `dev`. Historical runtime acceptance is recorded in
[`GOALS.md`](../GOALS.md).
