# Aperture Code Audit

Audit of the full `Sources/Aperture` tree (54 Swift files, ~4,900 lines), focused on
correctness bugs and AVFoundation/SwiftUI best practices around session setup, capture,
and the public options API. File/line references are against branch
`claude/camera-library-swiftui-audit-lpknen` at the time of the audit.

> **Status:** items 1.1–1.7 (all criticals) and 2.1 (`startRunning` error propagation)
> are fixed on this branch in the commit following the audit. Sections 2.2–2.9 and
> below remain open.

---

## 1. Critical — crashes

### 1.1 KVO observers are never removed (crash when `Camera` deallocates)
`Camera.AutomaticCameraObserver` (`Capture/Camera.swift:183-239`) registers two KVO
observers on `AVCaptureDevice.self` (`systemPreferredCamera`, `userPreferredCamera`) in
its initializer but has no `deinit` that calls `removeObserver(_:forKeyPath:)`.
Every `Camera` creates one of these in `init`. When a `Camera` instance is released
(e.g. the camera screen is dismissed and the `@State` goes away), the observer is
deallocated while still registered, which raises an NSKeyValueObserving exception the
next time either class property changes — a delayed, hard-to-reproduce crash.

**Fix:** add `deinit { AVCaptureDevice.self.removeObserver(self, forKeyPath: ...) }`
for both key paths, or migrate to block-based observation (`NSKeyValueObservation`)
which auto-invalidates.

### 1.2 Unclamped `videoZoomFactor` (Objective-C exception)
`Camera.State.zoomFactor.didSet` → `applyZoomFactor` (`Capture/Camera.State.swift:64-86`)
writes `device.videoZoomFactor = zoomFactor` with no clamping. AVFoundation throws
`NSInvalidArgumentException` for values outside
`minAvailableVideoZoomFactor...maxAvailableVideoZoomFactor`.

`zoomFactor` is a *public, writable* property (via `Camera`'s dynamic-member subscript),
and `CameraZoomButton` / `CameraZoomProxy.zoom(toVideoZoomFactor:)` forward arbitrary
caller-provided values. The pinch gesture clamps (`CameraViewFinder.zoom.swift:48`), but
nothing else does — `CameraZoomButton(camera: camera, zoomFactor: 100)` on most devices
crashes. There is also a race on device flip: a SwiftUI zoom animation in flight keeps
interpolating values that were valid for the *old* device into the *new* device.

**Fix:** clamp in `applyZoomFactor` against the active device's min/max. Consider
`ramp(toVideoZoomFactor:withRate:)` for button-driven zoom instead of driving 60 Hz of
discrete `videoZoomFactor` writes (each acquiring `lockForConfiguration()`) through a
SwiftUI `Animatable` modifier.

### 1.3 Safe-area inset copy-paste bug breaks aspect-ratio fitting
`_FitAspectRatioViewModifier.updatePaddings`
(`Internal/UI/FitAspectRatioViewModifier.swift:92-103`) adds the **top and bottom**
safe-area insets to the **width**:

```swift
if ignoreSafeAreaEdges.contains(.bottom) {
    safeAreaInsetsIgnoredSize.width += safeAreaInsets.bottom   // should be .height
}
...
if ignoreSafeAreaEdges.contains(.top) {
    safeAreaInsetsIgnoredSize.width += safeAreaInsets.top      // should be .height
}
```

Any use that ignores top/bottom safe areas (the standard full-bleed camera layout on
iPhone) computes the wrong aspect ratio and wrong compensating padding.

### 1.4 `fatalError` on unknown flash mode
`CameraFlash.isEnabled` (`Capture/CameraFlash.swift:32-33`) has
`@unknown default: fatalError("Unknown flash mode")`. If Apple ever adds a flash mode,
apps using this library crash in a *computed property used for UI tinting*.
**Fix:** return `false` (or treat as `.auto`).

### 1.5 Unbalanced `unlockForConfiguration()` in the exposure slider
`_FocusTargetBoundingBox.exposureAdjustmentGesture`
(`UI/View Finder/_FocusTargetBoundingBox.swift:174-200`):

- `onEnded` calls `device.unlockForConfiguration()` unconditionally, even when
  `lockForConfiguration()` was never successfully acquired (`isUnlocked == false`),
  producing an unbalanced unlock (AVFoundation raises/logs).
- The lock is held for the whole drag gesture and the device is mutated directly on the
  main thread, bypassing `CameraActor`/`withCurrentCaptureDevice` that the rest of the
  library uses — racing the session queue.
- `device.exposureMode = .autoExpose` is re-set on every drag tick.

**Fix:** route through `camera.coordinator.withCurrentCaptureDevice` per change (or
lock/unlock symmetrically guarded by `isUnlocked`), and only unlock if locked.

### 1.6 Live Photo request on a non-supporting output (exception)
`createPhotoSettings` (`PhotoCaptureService.swift:169`) sets
`photoSettings.livePhotoMovieFileURL` whenever `configuration.capturesLivePhoto` is
true. If the active output has `isLivePhotoCaptureEnabled == false` (unsupported device,
e.g. external/Continuity cameras on iPad), `capturePhoto(with:delegate:)` throws an
Objective-C exception → crash, and the checked continuation in `takePhoto` is never
resumed. **Fix:** gate on `output.isLivePhotoCaptureEnabled`.

### 1.7 IUO chains that can be nil mid-flight
- `PhotoCaptureService.Coordinator.setFlashScene` (`PhotoCaptureService.swift:101-106`):
  `precondition(cameraCoordinator != nil)` then `cameraCoordinator?.camera.state` —
  `camera` is `weak ... !`; if the `Camera` deallocated while a flash-scene KVO callback
  is queued, the force-unwrap traps.
- `createPhotoSettings` line 174: `context.coordinator.cameraCoordinator.camera.state.flash`
  — same double-IUO chain.
- `CameraCoordinator.updateCamera` (`CameraCoordinator.swift:419-428`):
  `precondition(self.camera != nil)`. `coordinator.camera` is assigned *asynchronously*
  after `Camera.init` (deferred `Task`), while `AutomaticCameraObserver` KVO can fire
  immediately and trigger a device switch → `updateCamera` → precondition race window.

**Fix:** make these paths tolerate nil (early-return) instead of trapping; assign
`coordinator.camera`/`state.camera` synchronously in `Camera.init` (both are
`@MainActor`, the hop through `Task` is unnecessary for the MainActor half).

---

## 2. High — broken behavior, silent failures

### 2.1 `startRunning()` doesn't await, swallows errors, and lies about state
`Camera.startRunning` (`Capture/Camera.swift:96-112`) is declared `async throws`, but
the actual work (`configureSession()` + `captureSession.startRunning()`) happens in an
un-awaited `Task { @CameraActor }`:

- `configureSession()` errors (`invalidCaptureDevice`, `failedToAddInput/Output`) are
  thrown inside the unobserved task and **vanish** — the caller's `try await` succeeds.
- The method returns before the session is configured/started, so callers cannot
  sequence "session is up" logic.
- `.running` is only published if `isRunning` happens to be true immediately after
  `startRunning()`; failures leave the UI permanently on the blurred placeholder with no
  signal (see also 2.6).

**Fix:** `try await Task { @CameraActor in ... }.value` (or make the body
`@CameraActor`), propagate errors, and set state from the actual outcome.
Also: the error case is misspelled `sessionAlreadStarted` (public API).

### 2.2 Session interruptions and runtime errors are not handled
There is no observation of `AVCaptureSession.wasInterruptedNotification`,
`.interruptionEndedNotification`, `.runtimeErrorNotification`, or
`.didStartRunning/.didStopRunning`. Standard camera-app lifecycle (phone call, Split
View on iPad, Control Center camera grab, media-services reset) leaves
`captureSessionState` stuck at `.running` while the session is actually stopped, with no
auto-restart hook. This is the biggest gap versus Apple's AVCam reference. **Fix:**
observe these notifications in `CameraCoordinator`, reflect them in `Camera.State`
(e.g. an `.interrupted(reason:)` case), and restart on `runtimeError` when
`AVError.Code.mediaServicesWereReset`.

### 2.3 Photo capture: real errors are replaced by a generic one
`PhotoCaptureDelegate` (`PhotoCaptureDelegate.swift`):

- `didFinishProcessingPhoto` logs the AVFoundation error and returns (line 59-62).
- `didFinishCaptureFor` then resumes the continuation with the generic
  `PhotoCaptureError.noPhotoData` (line 152-155).

The caller never sees *why* the capture failed (flash unavailable, disk full, session
torn down…). **Fix:** stash the first delegate error and resume the continuation by
throwing it.

### 2.4 In-flight delegate leak on failed captures
`Camera.takePhoto` (`Capture/Camera.PhotoCapture.swift:52-54`) removes the delegate from
`inFlightPhotoCaptureDelegates` *after* the `try await` — on a thrown capture error the
cleanup never runs, so every failed capture permanently leaks a `PhotoCaptureDelegate`
in the dictionary. **Fix:** remove in a `defer` (or `withTaskCancellationHandler`-style
cleanup) so both paths clean up.

### 2.5 `capturePhoto` is invoked off the session queue
Also in `takePhoto`: settings are created on `@CameraActor`, but
`photoOutput.capturePhoto(with:photoSettings, delegate:)` (line 48) runs on the caller's
executor. All other session/output interaction in this library is serialized on
`CameraActor` (the session queue); this one races concurrent reconfiguration (e.g. a
camera flip mid-shot). **Fix:** hop to `@CameraActor` for the `capturePhoto` call.

### 2.6 Camera errors can never reach the UI
`CameraViewFinder.cameraError` / `errorOverlay` (`UI/View Finder/CameraViewFinder.swift:63,
95-104`) is dead code — nothing ever assigns `cameraError`, so the "Camera Unavailable"
overlay is unreachable. Combined with 2.1, a permission denial or configuration failure
shows a blurred black rectangle forever. **Fix:** surface `CameraError` through
`Camera.State` and render the overlay from it.

### 2.7 `CameraZoomButton` silently drops its `animation` parameter
`CameraZoomButton.init` (`UI/CameraZoomButton.swift:23-32`) never assigns
`self.animation = animation`; the property keeps its `.smooth` default and the
caller-provided animation (default `.default`) is ignored.

### 2.8 `stopRunning()` resets all user state and reports `.idle` early
`Capture/Camera.swift:115-122` replaces the whole `State` object
(`state = State(camera: self)`):

- User-visible settings (selected flash mode, zoom display multiplier) are wiped.
- Any view/closure still holding the old `State` instance observes a dead object.
- `captureSessionState` is set to `.idle` *before* the session actually stops on the
  session queue.

**Fix:** reset individual fields after `stopRunning()` completes; don't swap the object.

### 2.9 Mac Catalyst: Live Photo bookkeeping leaks
`willCapturePhotoFor` increments `inProgressLivePhotoCount` under `#if os(iOS)` (which
*includes* Catalyst), but the decrementing callback
`didFinishRecordingLivePhotoMovieForEventualFileAt` and the movie-delivery callback are
compiled out with `#if os(iOS) && !targetEnvironment(macCatalyst)`
(`PhotoCaptureDelegate.swift:37-43,95-141`). On Catalyst the count only ever goes up and
the movie URL is never delivered. Similarly `Package.swift` declares
`.macCatalyst(.v14)` against `.iOS(.v17)` — Catalyst 14 predates many APIs used here;
it should presumably be `.v17`+.

---

## 3. Medium

- **Device switch can silently desync.** `Camera.device.willSet`
  (`Camera.swift:26-33`) debounces 0.2 s and then assigns
  `coordinator.cameraInputDevice = newValue.captureDevice`. If the new semantic camera
  resolves to `nil` (e.g. `TelephotoCamera` on a non-Pro phone), the coordinator keeps
  the old device while `camera.device` reports the new one; no error, wrong UI. The
  `Task<Void, Error>` is also unobserved. Validate `captureDevice != nil` before
  accepting the assignment, or revert and report.
- **Failed input/output restore lacks `canAdd*` checks.**
  `configureSessionInput`'s catch path re-adds the previous input without
  `canAddInput`, and `configureSessionOutputs`' rollback re-adds old outputs without
  `canAddOutput` (`CameraCoordinator.swift:122-134,201-206`). If the preset changed in
  the same `beginConfiguration` block, the restore itself can raise. Both paths also
  swallow the original error.
- **`displayVideoZoomFactorMultiplier` availability gate looks wrong.**
  `CameraCoordinator.swift:137,251`: gated on `iOS 18.0, macOS 14.0`. The API is
  documented as iOS 17.2+ / macOS 14.2+. As written, iOS 17.2–17.x users unnecessarily
  fall back to the manual wide-angle computation, and `macOS 14.0` is *below* the API's
  introduction (worth verifying it actually builds against the macOS SDK — CI builds
  macOS, so double-check the annotation rather than trusting it).
- **Live Photo pipeline is force-enabled.** `updateOutput`
  (`PhotoCaptureService.swift:64`) sets
  `isLivePhotoCaptureEnabled = isLivePhotoCaptureSupported` unconditionally. Keeping the
  Live Photo pipeline hot costs memory/power even for apps that never capture one; this
  should be a `PhotoCaptureOptions` flag like the other toggles.
- **Live Photo temp movies are never cleaned up.** `URL.movieFileURL`
  (`PhotoCaptureService.swift:264-271`) writes to the temporary directory; nothing
  deletes the file if the caller ignores `livePhotoMovieURL` or the capture fails.
  Document the ownership or delete on delegate teardown.
- **Lens-position polling.** `_FocusTargetBoundingBox.trackFocusState`
  (`_FocusTargetBoundingBox.swift:202-237`) busy-polls `device.lensPosition` every 10 ms
  from a detached task to detect focus completion. KVO on
  `AVCaptureDevice.isAdjustingFocus` is the supported, cheaper signal.
- **Subject-area-change reset is unfiltered.** `_FocusGestureRespondingView.onReceive`
  (`CameraViewFinder.focus.swift:67-87`) subscribes to
  `.AVCaptureDeviceSubjectAreaDidChange` without an `object:` filter, so notifications
  from *any* device (including a second `Camera`) reset this view's focus state.
- **`startRunning` TOCTOU.** The `captureSessionState == .idle` guard runs on the main
  actor and the work is detached; two quick calls both pass the guard. Harmless today
  (`startRunning` on a running session is a no-op) but the thrown
  `sessionAlreadStarted` contract is not actually enforced.
- **Readiness tracking can leave the shutter disabled.**
  `PhotoReadinessCoordinatorDelegate` updates `shutterDisabled` asynchronously; the
  readiness coordinator is released when `takePhoto` returns, so a final
  `.notReady...` callback racing teardown can leave `shutterDisabled == true` with
  nothing to clear it.

---

## 4. Low / polish

- `CameraError.sessionAlreadStarted` → `sessionAlreadyStarted` (public API typo);
  `MovieCaptureService.configuraton` → `configuration`; doc typos ("configuation",
  "potrait", "senerios", "lantency", "caprturing", "interst", "Pintch").
- `Camera.isAccessible` is a `static var` getter that triggers the system permission
  dialog (`requestAccess`). A side-effecting getter is surprising API; prefer an
  explicit `requestAccess()` method, check `authorizationStatus` first, and let apps
  distinguish `.denied` from `.notDetermined` to drive "open Settings" UI.
- `CameraCaptureProfile.hd1080p` / `.hd4k` (`CameraCaptureProfile.swift:66-75`) are
  `private` — dead code (presumably waiting on `MovieCaptureService`, which is an
  `@_spi` stub with no record/stop API; `CaptureError.movieOutputServiceNotAvailable`
  is never thrown).
- `CameraCaptureProfile` defines `static func ==` without conforming to `Equatable`,
  so the operator is only found in limited contexts; `Camera.profile` setter doesn't
  use it to skip no-op reconfigurations (every assignment triggers a full session
  reconfiguration even if equal).
- `withValueObservation` (`Internal/ValueObservation.swift:21`) applies `.share()` to a
  publisher with a single subscriber — no effect.
- `Logging` creates a new `Logger` on every access; cheap, but a cached static would be
  idiomatic.
- `CameraPreview` returns the same `UIView`/`NSView` instance from
  `makeUIView`/`makeNSView`; instantiating two `CameraViewFinder`s for one `Camera`
  silently re-parents the single preview view. Worth documenting.
- `_ZoomGesture` hardcodes front-camera zoom to `1.3`/`1.0`
  (`CameraViewFinder.zoom.swift:44-47`) and caps rear zoom at `5 ×` last switch-over
  factor — both deserve a comment or an option.
- `PhotoCaptureService.updateOutput` keys portrait-matte delivery off
  `.deliversDepthData` (`PhotoCaptureService.swift:76-78`) — intentional per the option's
  doc, but a separate option would be cleaner.

---

## 5. Best-practices review: camera bring-up and options API

What the library does **well**:

- Dedicated serial session queue via a custom global actor (`CameraActor`) whose
  executor is a `DispatchSerialQueue` — the modern equivalent of AVCam's
  `sessionQueue`, and `startRunning()` is correctly kept off the main thread.
- `beginConfiguration`/`commitConfiguration` bracketing with `defer`, `canSetSessionPreset`
  / `canAddInput` / `canAddOutput` checks on the happy path.
- `AVCaptureDevice.RotationCoordinator` for preview/capture rotation, with angles
  propagated to both the preview connection and output connections.
- `isMultitaskingCameraAccessEnabled` opt-in, zero-shutter-lag / responsive-capture /
  fast-capture-prioritization / deferred delivery / constant color all guarded by their
  `isSupported` counterparts; per-shot `maxPhotoDimensions` chosen from
  `supportedMaxPhotoDimensions`.
- Readiness coordination (`AVCapturePhotoOutputReadinessCoordinator`) to drive shutter
  availability, and `photoSettingsForSceneMonitoring` for flash-scene recommendation.
- The options surface (`PhotoCaptureOptions` as an `OptionSet` + per-shot
  `PhotoCaptureConfiguration` + presets like `.prioritizingShotToShotLatency`) is a
  genuinely nice API design, with honest "request, not guarantee" documentation.

The main structural gaps, in priority order:

1. No session interruption/runtime-error handling (2.2) — required for production use.
2. Fire-and-forget bring-up: `startRunning` must propagate configuration errors and
   reflect real session state (2.1, 2.6).
3. Exception-prone device writes: zoom clamping (1.2), Live Photo gating (1.6),
   exposure-lock balance (1.5).
4. Observer lifecycle: KVO removal (1.1) and `deinit`-time teardown generally
   (`Camera` never stops the session or cancels `_cameraSwitchingTask` on dealloc).
5. Capture-path hygiene: errors propagated to the awaiting caller (2.3), delegate map
   cleanup (2.4), session-queue discipline for `capturePhoto` (2.5).
