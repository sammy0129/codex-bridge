# Repository Guidelines

## Project Structure & Architecture

- `apps/bridge/src/`: TypeScript HTTPS/WebSocket Bridge, SQLite persistence, and Codex adapter. Tests live in `src/test/`.
- `apps/android/lib/`: Flutter client; `data/` contains transport, storage, and Riverpod-backed state, while `ui/` contains screens. Tests live in `test/` and `integration_test/`; Android resources live in `android/app/src/main/res/`.
- `packages/protocol/`: Bridge contracts, generated Codex TypeScript types, and JSON schemas.
- `scripts/`, `deploy/`, and `.github/workflows/`: helpers, deployment templates, and CI. See `docs/TESTING.md` and `docs/VALIDATION.md` for verification details.

## Build, Test, and Development Commands

Use Node 24 LTS, Flutter 3.47.5/Dart 3.13.4, and Codex CLI **0.155.1**.

From the repository root:

- `npm ci`: install locked workspace dependencies.
- `npm run build`: compile protocol and Bridge packages.
- `npm test`: build and run Bridge tests.
- `npm run bridge -- init`: initialize local certificates/configuration once; `npm run bridge -- serve` starts the service.
- `npm run smoke`: exercise real Codex initialization and PTY; adding `-- --agent` runs a real coding task and consumes usage.

From `apps/android`:

- `flutter pub get`: install dependencies.
- `dart format lib test integration_test`: format Dart sources.
- `flutter analyze` and `flutter test`: run static checks and unit/widget tests.
- `flutter build apk --debug`: build the normal application APK. Rebuild after integration tests before distributing.
- Default Android delivery is ARM64-only unless requested otherwise: `flutter build apk --debug --target-platform android-arm64 --split-per-abi`. Deliver `apps/android/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk` and verify its native libraries contain only `arm64-v8a`. Do not deliver an integration-test APK.

## Chat Image Invariants

- Keep camera and gallery selection in the existing composer style. Attachments remain removable drafts until explicit send; support image-only messages and preserve text/image order. Cancelled selection must not create an attachment.
- Track local preview, uploading, uploaded, and failed states separately. Disable send while uploads are incomplete, preserve attachments on failure, and never automatically retry uploads or sends with unknown outcomes.
- Bind selection and upload results to host, project, task, and draft identity. Discard stale results after context changes. Android lost-selection recovery returns images only to the original draft, without automatic upload or send.
- Uploads remain PNG/JPEG with a 20 MiB per-image limit. Historical previews support PNG/JPEG/WebP/GIF up to 20 MiB. Show Chinese errors for permissions, unavailable cameras, unsupported formats, oversized or unavailable images; never expose raw Base64.
- Render user-message images from `localImage.path` and embedded/HTTPS `image.url` references. Never interpret a remote host path as a phone-local file. Use lazy loading, bounded host-isolated memory caching, thumbnail decode limits, and a full-screen zoom/pan preview. Assistant Markdown and image-tool output are outside this scope.
- Historical local images use authenticated `GET /v1/thread-images` with `projectId`, `threadId`, `itemId`, and `contentIndex`; never accept arbitrary client paths. Verify project ownership and resolve references from trusted task history without resuming, taking over, or executing the task.
- Project-external image access is limited to the exact historical reference; do not widen file browsing/editing permissions. Validate regular files, real paths, file identity around reads, image signatures, and size; reject link/target replacement attempts.
- Preserve Bearer authentication, HTTPS/certificate pinning, no authenticated redirects, correct image MIME types, and private/no-store response headers. External HTTPS images use a separate client without Bridge credentials; Bridge must not proxy arbitrary URLs.
- Check the `imageRead` capability. Older Bridge versions must show an upgrade prompt rather than load indefinitely. Missing originals or legacy `[图片]` text without image references must show unavailable, not imply recovery. See `docs/PROTOCOL.md` and `docs/SECURITY.md`.

## Coding Style & Naming

Use two-space indentation. TypeScript uses ESM, single quotes, semicolons, and `.js` import suffixes. Dart files use `snake_case.dart`, classes use `PascalCase`, and members use `camelCase`; follow `flutter_lints`. No JavaScript formatter is configured. Separate UI from transport/persistence. Do not hand-edit generated protocol files; use `npm run protocol:generate` with the pinned CLI.

## Testing Guidelines

Bridge tests use `node:test` and `*.test.ts`; Flutter uses `flutter_test`, `integration_test`, and `*_test.dart`. Add regressions for authentication, replay, idempotency, conflicts, and host isolation. No coverage threshold is configured. Keep fixtures out of production; follow documented emulator setup.

For image changes, run `npm test`, `flutter analyze`, and `flutter test`. Maintain regressions for camera/gallery cancellation and errors, draft recovery and context switching, mixed/multiple images, preview/delete/zoom, failed sends, corrupt images, cache isolation, and historical reopening. Bridge coverage must include revoked/unpaired devices, forged/cross-project references, valid external references, link replacement, missing files, format/size limits, and binary responses. Report physical-device camera, orientation, and background-recovery checks separately; do not claim them from widget tests. Do not run usage-consuming real model tasks by default.

## Local Bridge Upgrade & Restart

- Building Bridge updates disk files, not an already-running process. If images show an upgrade prompt, check the running process and its `imageRead` support before changing the client.
- Obtain explicit user approval before restarting a running Bridge. A prior approval is not blanket permission for future restarts. Check for active tasks, terminals, approvals, and pending requests before stopping; do not interrupt active work without confirmation.
- Identify the exact repository process, executable, bind address, and data directory. Multiple unrelated services can use the same port on different addresses; never terminate by process name or port alone. Scope any child-process cleanup to the verified Bridge process tree.
- Preserve the existing `BRIDGE_DATA_DIR`, pairing records, certificates, and configuration. Start background helpers hidden; do not change firewall or startup settings. Never print credentials or private state while diagnosing.
- After restart, verify startup logs, listener ownership, and HTTPS using the configured certificate, not disabled TLS validation. An unauthenticated `/v1/thread-images` returning 401 rather than 404 confirms route registration only, not successful authenticated image loading. Reconnect the Android client to refresh capabilities; normal upgrades should not require re-pairing.

## Commits & Pull Requests

No Git history is available to establish existing conventions. Prefer imperative, scoped subjects such as `fix(bridge): reject stale approvals`. PRs should describe changes, link issues, list checks and limitations, and include screenshots for UI changes.

## Security & Agent Instructions

Never commit pairing codes, device tokens, certificates/private keys, SQLite state, or signing secrets. Preserve HTTPS/pinning, explicit approvals, and unknown-outcome handling; never automatically replay uncertain writes. Use isolated `BRIDGE_DATA_DIR` values for tests. Prefer FastCtx inspection tools when available and `apply_patch` for edits. Do not restart running services or change firewall/startup settings for unrelated work.
