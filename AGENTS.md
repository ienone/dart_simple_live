# Repository working agreement

## Product and scope

- This fork implements the owner's requests in [upstream issue #146](https://github.com/SlotSun/dart_simple_live/issues/146). Track acceptance and remaining work in `GOALS.md`.
- Read the current code and upstream discussion before changing behavior. Preserve fork-specific commits and user changes when synchronizing upstream; never reset them away.
- Use the existing checkout. Cloud tasks already run in isolation; do not create additional worktrees unless requested.
- Keep feature boundaries reviewable. Related correctness, accessibility and compatibility work is welcome; unrelated redesigns and speculative features are not.
- Prioritize working features and practical bug checks. Use reasonable inferences to build and try an implementation; do not require an exhaustive research or proof exercise before making progress. Keep implementation notes short. Do not create long reports or evidence bundles unless explicitly requested.

## UI

- Keep the existing visual language and density. Add controls where users perform the action, with short, concrete labels.
- Never fill empty space with promotional, explanatory or AI-like filler. Do not display debug information, architecture, test status or implementation details in product UI.
- Prefer existing menus, contextual actions and standard controls over new panels. Preserve responsive desktop/mobile layouts and accessible tooltips/semantics.
- Keep full room refresh available. A danmaku-only reconnect must explicitly reset its own connection/buffer without silently restarting video.

## Data and playback

- Treat Hive fields, imports/exports, LAN sync and WebDAV payloads as public compatibility boundaries. Preserve old records and accept legacy single-tag data when extending follow metadata.
- Account for overlapping async operations, cancellation, disposal, partial network failures and stale responses. A failed status lookup must not silently become an offline result.
- Soft resume must reconnect to the live edge; do not resume buffered historical video. Audio-only mode must disable video work and use native audio streams when actually supported.
- Start provider audio work from working open-source implementations and official code, then test promising approaches with real streams. Distinguish server audio from locally discarding video when describing bandwidth savings. Favor a useful, tested implementation over exhaustive protocol research.
- System media controls must call the same playback/queue actions as in-app controls. Queue entries must be live, ordered deterministically and updated safely when rooms go offline.
- Never log or commit cookies, account credentials or captured private account data.

## Testing agreement (takes precedence over the older contributing guide)

- Strongly prefer real end-to-end tests as the only new test mechanism: start the actual application and exercise real persistence, platform plugins and API boundaries. Do not use mocks, fakes or simulated live-service responses.
- Define the behavioral acceptance checks and failure cases before implementation. Do not write unit tests after implementation, and do not add unit tests as a substitute for the requested E2E coverage.
- Integration tests are justified for a real data/API boundary that cannot be covered meaningfully by the E2E flow. If isolation is necessary, first document the ways that subsystem can fail.
- Golden checks must use genuine captured data or application output, with provenance and reviewable expectations. They must protect a real behavior gap, not mirror implementation details.
- Redundant tests and change-detection tests are harmful. Do not add regression tests merely because a bug was fixed; identify an actual missing behavior first.
- Record the commands and meaningful test results briefly. Preserve useful failure logs while debugging; do not build separate evidence packages, source-hash inventories or lengthy verification reports as a default deliverable.
- Never claim a real-service scenario passed when its network, account or device prerequisite was unavailable. Do not weaken assertions to obtain a green result.

## Development

- The main app is `simple_live_app`; platform APIs are in `simple_live_core`. Use the current `.fvmrc` / `pubspec.yaml` Flutter version (updated by upstream).
- Use GetX and the existing service boundaries. Avoid introducing competing state-management patterns.
- In this cloud workspace, source `/workspace/toolchains/activate.sh` before commands. Keep tool caches and environment-specific setup outside the repository. Update the SDK if upstream pins change.
- Restore dependencies with a lock-preserving command where possible; dependency changes required by an approved feature must be intentional and reviewed.
- Run meaningful analysis/build/E2E checks for affected paths. Protect existing generated-file contents from unrelated tooling churn; regenerate adapters only when their schemas actually change.
- Use parallel agents for independent areas when useful, with explicit file ownership and shared interface contracts. Do not overwrite another agent's work.
- Do not push, publish releases, or send issue/PR comments unless explicitly requested.

## Branch workflow

- `master` integrates all fork features. Develop PR-sized changes from the narrowest required feature branch and merge them into `master`; do not merge `master` back into an upstream PR branch.
- Follow the feature dependencies and target-branch porting instructions in `docs/branch-workflow.md`. Current feature branches use upstream `master`; a PR targeting upstream `dev` needs an explicitly tested port of the selected commits.
