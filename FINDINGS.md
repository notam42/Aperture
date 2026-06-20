# Aperture — Findings & Status Tracker

This file tracks every finding from the code audit and its current state. Detailed
analysis for each item lives in [`AUDIT.md`](AUDIT.md); this file is the at-a-glance
status board.

## Status legend

Each finding carries one of three statuses:

| Badge | Status | Meaning |
|-------|--------|---------|
| ✅ | **Fixed** | Addressed with a code change on branch `claude/camera-library-swiftui-audit-lpknen`. Not yet compiled/run here (no Apple SDK in this environment) — relies on CI / your verification. |
| ⬜ | **Open** | Intentionally not changed. Reason given in Notes. |
| ☑️ | **Verified by you** | You have confirmed the fix builds and behaves correctly. Flip the box in the "Verified" column once you've checked it on-device. |

A couple of items were **investigated and found to need no change** — they are marked
✅ with a Notes explanation rather than a code edit.

**Commits**
- `d52f63f` — audit document
- `aad5b96` — critical fixes (§1)
- `1ac04bb` — high-severity fixes (§2)
- `68bbc72` — medium/low fixes (§3–4)
- `10d6e0c` — automatic deferred start feature

---

## 1. Critical — crashes

| ID | Finding | Status | Verified | Commit | Notes |
|----|---------|--------|----------|--------|-------|
| 1.1 | KVO observers never removed (crash on `Camera` dealloc) | ✅ Fixed | ☐ | `aad5b96` | Added `deinit` removing `systemPreferredCamera`/`userPreferredCamera` observers. |
| 1.2 | Unclamped `videoZoomFactor` → `NSInvalidArgumentException` | ✅ Fixed | ☐ | `aad5b96` | Clamp to device `min…maxAvailableVideoZoomFactor` in `applyZoomFactor`. |
| 1.3 | Safe-area inset copy-paste bug breaks aspect-ratio fitting | ✅ Fixed | ☐ | `aad5b96` | Top/bottom insets now added to `height`, not `width`. |
| 1.4 | `fatalError` on unknown flash mode | ✅ Fixed | ☐ | `aad5b96` | `@unknown default` returns `false`. |
| 1.5 | Unbalanced `unlockForConfiguration()` in exposure slider | ✅ Fixed | ☐ | `aad5b96` | Routed through `withCurrentCaptureDevice` on `CameraActor`; removed manual lock/unlock + `isUnlocked`. |
| 1.6 | Live Photo request on non-supporting output (exception) | ✅ Fixed | ☐ | `aad5b96` | Gate `livePhotoMovieFileURL` on `output.isLivePhotoCaptureEnabled`. |
| 1.7 | IUO chains / preconditions can trap mid-flight | ✅ Fixed | ☐ | `aad5b96` | Tolerant `guard` instead of `precondition`; back-references wired synchronously in `Camera.init`. |

## 2. High — broken behavior / silent failures

| ID | Finding | Status | Verified | Commit | Notes |
|----|---------|--------|----------|--------|-------|
| 2.1 | `startRunning()` doesn't await, swallows errors, lies about state | ✅ Fixed | ☐ | `aad5b96` | Now `await`s the `@CameraActor` task and propagates configuration errors; sets state from real outcome. |
| 2.2 | Session interruptions / runtime errors not handled | ✅ Fixed | ☐ | `1ac04bb` | New `CaptureSessionState.interrupted`; observers for `wasInterrupted`/`interruptionEnded`/`runtimeError`; auto-restart on media-services reset. |
| 2.3 | Photo capture: real errors replaced by generic `noPhotoData` | ✅ Fixed | ☐ | `1ac04bb` | Delegate stores first error; continuation throws it. |
| 2.4 | In-flight delegate leak on failed captures | ✅ Fixed | ☐ | `1ac04bb` | Cleanup runs on success and failure (`do`/`catch`). |
| 2.5 | `capturePhoto` invoked off the session queue | ✅ Fixed | ☐ | `1ac04bb` | Dispatched on `@CameraActor`. |
| 2.6 | Camera errors can never reach the UI (dead overlay) | ✅ Fixed | ☐ | `1ac04bb` | New `Camera.State.sessionError`; `CameraViewFinder` renders the overlay from it. |
| 2.7 | `CameraZoomButton` silently drops its `animation` parameter | ✅ Fixed | ☐ | `1ac04bb` | `self.animation = animation` assigned in init. |
| 2.8 | `stopRunning()` wipes user state, reports `.idle` early | ✅ Fixed | ☐ | `1ac04bb` | `resetTransientState()` preserves flash mode/zoom and the `State` identity. |
| 2.9 | Mac Catalyst Live Photo bookkeeping leak; Catalyst platform floor | ✅ Fixed | ☐ | `1ac04bb` | Live Photo disabled on Catalyst to match delegate availability; Catalyst floor raised (later → 26 in `10d6e0c`). |

## 3. Medium

| ID | Finding | Status | Verified | Commit | Notes |
|----|---------|--------|----------|--------|-------|
| 3.1 | Device switch can silently desync when device resolves to `nil` | ✅ Fixed | ☐ | `68bbc72` | Keep & revert to current device; log error. |
| 3.2 | Failed input/output restore lacks `canAdd*` checks | ✅ Fixed | ☐ | `68bbc72` | Restore paths now guard with `canAddInput`/`canAddOutput` and log the original error. |
| 3.3 | `displayVideoZoomFactorMultiplier` availability gate looks wrong | ✅ Fixed | ☐ | — | **Investigated, no change needed.** Verified against Apple docs: API is iOS 18.0 / macOS 14.0 / Mac Catalyst 14.0 — the existing gate is correct. |
| 3.4 | Live Photo pipeline force-enabled (memory/power cost) | ⬜ Open | ☐ | — | Needs a new `PhotoCaptureOptions` flag — an API-design decision for the maintainer. |
| 3.5 | Live Photo temp movies never cleaned up | ✅ Fixed | ☐ | `68bbc72` | Documented file ownership on `CapturedPhoto.livePhotoMovieURL` (caller owns/deletes). No auto-delete to avoid destroying data the caller still wants. |
| 3.6 | Lens-position busy-polling for focus completion | ✅ Fixed | ☐ | `68bbc72` | Replaced 10 ms polling with KVO on `isAdjustingFocus`. |
| 3.7 | Subject-area-change reset is unfiltered (cross-device) | ✅ Fixed | ☐ | `68bbc72` | Notification filtered to this camera's device by `uniqueID`. |
| 3.8 | `startRunning` TOCTOU (double entry) | ✅ Fixed | ☐ | `68bbc72` | State claimed as `.configuring` synchronously before the async work. |
| 3.9 | Readiness tracking can leave shutter disabled | ✅ Fixed | ☐ | `68bbc72` | `shutterDisabled`/`isBusyProcessing` reset when no captures remain in flight. |

## 4. Low / polish

| ID | Finding | Status | Verified | Commit | Notes |
|----|---------|--------|----------|--------|-------|
| 4.1 | `sessionAlreadStarted` public-API typo | ✅ Fixed | ☐ | `68bbc72` | Renamed to `sessionAlreadyStarted` (source-breaking, pre-1.0). |
| 4.2 | `MovieCaptureService.configuraton` typo | ✅ Fixed | ☐ | `68bbc72` | Renamed to `configuration`. |
| 4.3 | Doc-comment typos (configuation, potrait, senerios, lantency, …) | ✅ Fixed | ☐ | `68bbc72` | ~10 fixed across the tree. |
| 4.4 | `Camera.isAccessible` is a side-effecting getter | ✅ Fixed | ☐ | `68bbc72` | Added `Camera.authorizationStatus` and `Camera.requestAccess()`; `isAccessible` kept for compatibility. |
| 4.5 | `CameraCaptureProfile` `==` without `Equatable`; setter doesn't skip no-ops | ✅ Fixed | ☐ | `68bbc72` | Now conforms to `Equatable`; `profile` setter skips reconfiguration when equal. |
| 4.6 | `withValueObservation` pointless `.share()` | ✅ Fixed | ☐ | `68bbc72` | Removed. |
| 4.7 | `hd1080p` / `hd4k` private dead-code presets | ⬜ Open | ☐ | — | Blocked on `MovieCaptureService` being completed (it's an `@_spi` stub with no record/stop API). |
| 4.8 | `Logging` allocates a new `Logger` per access | ⬜ Open | ☐ | — | Harmless nit; left as-is. |
| 4.9 | `CameraPreview` shares one view instance per `Camera` | ⬜ Open | ☐ | — | Known limitation: two `CameraViewFinder`s for one `Camera` re-parent the single preview. Worth documenting if it ever bites. |
| 4.10 | `_ZoomGesture` hardcodes front-camera zoom (1.3/1.0) and rear cap | ⬜ Open | ☐ | — | Left as-is; candidate for an option/constant. |
| 4.11 | Portrait-matte delivery keyed off `.deliversDepthData` | ⬜ Open | ☐ | — | Intentional per the option's documentation; a separate option would be cleaner. |

## Feature work

| ID | Item | Status | Verified | Commit | Notes |
|----|------|--------|----------|--------|-------|
| F.1 | Adopt automatic deferred start (faster time-to-preview) | ✅ Fixed | ☐ | `10d6e0c` | `automaticallyRunsDeferredStart`; data outputs `isDeferredStartEnabled = true`; preview layer never deferred; deferred-start delegate on the `CameraActor` queue. **Requires the iOS 26 SDK to build.** |
| F.2 | Raise deployment target to iOS/macOS/Mac Catalyst 26 | ✅ Fixed | ☐ | `10d6e0c` | `Package.swift` + README updated. Existing `@available(iOS 18 …)` gates are now redundant but harmless (left in place). |

---

## Summary

- **Fixed:** all of §1 (7), all of §2 (9), §3 (8 of 9; 3.4 open), §4 (6 of 11; 4.7–4.11 open), plus 2 feature items.
- **Investigated, no change:** 3.3 (availability gate was already correct).
- **Open (deferred, by choice):** 3.4, 4.7, 4.8, 4.9, 4.10, 4.11 — reasons in Notes.
- **Not yet verified on-device:** everything. No Apple SDK is available in this
  environment, so nothing here has been compiled or run. The repo's iOS + macOS CI is
  the first real compile gate; F.1/F.2 additionally require an Xcode 26 toolchain.
