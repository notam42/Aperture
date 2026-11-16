//
//  CameraCoordinator.swift
//  Aperture
//
//  Created by Yanan Li on 2025/12/20.
//

@preconcurrency import AVFoundation
import Foundation
import Combine
import SwiftUI

/// A camera coordinator responsible for managing shared camera infrastructure, including capture session, device input, capture output and more.
@CameraActor
@_spi(Internal)
public final class CameraCoordinator: NSObject, Logging {
    /// The ``Camera`` instance.
    @MainActor weak var camera: Camera!
    /// The capture preview.
    nonisolated let cameraPreview: CameraPreview

    @MainActor internal init(configuration: CameraCaptureProfile) {
        self.cameraPreview = CameraPreview()
        self.profile = configuration
        super.init()
    }
    
    /// The aspect ratio (width / height) of the currently selected video format.
    private var cameraAspectRatio: CGFloat {
        guard let cameraInputDevice else { return 1.0 }
        
        let formatDescription = cameraInputDevice.activeFormat.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGFloat(dims.width) / CGFloat(dims.height)
    }
    
    // MARK: - Session
    
    /// The capture session.
    @_spi(Internal)
    public let captureSession = AVCaptureSession()
    /// The active capture profile applied to the underlying `AVCaptureSession`.
    ///
    /// - note: Update this value would trigger a session re-configuration.
    internal var profile: CameraCaptureProfile {
        didSet {
            do {
                try configureSession()
            } catch {
                logger.error("Failed to switch profile: \(error.localizedDescription)")
            }
        }
    }
    
    /// Configure current session and corresponding capture pipeline with current profile and devices.
    internal func configureSession() throws {
        setConfigurationState(true)
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
            setConfigurationState(false)
        }
        
        if captureSession.canSetSessionPreset(profile.sessionPreset) {
            captureSession.sessionPreset = profile.sessionPreset
        }
        
        #if os(iOS)
        captureSession.isMultitaskingCameraAccessEnabled = captureSession.isMultitaskingCameraAccessSupported
        #endif
        
        guard let inputDevice = cameraInputDevice else { throw CameraError.invalidCaptureDevice }
        
        let activeDevice = configureSessionInput(device: inputDevice)
        guard activeCameraInput != nil else { throw CameraError.failedToAddInput }
        configureSessionOutputs()
        
        cameraPreview.connect(to: captureSession)
        cameraPreview.adjustPreview(for: activeDevice)
        
        setupRotationCoordinator(for: activeDevice)
        
        updateOutputServices()
    }
    
    internal func switchCaptureDevice(to device: AVCaptureDevice) throws {
        precondition(activeCameraInput != nil, "Switch capture device requires an existing capture device.")
        
        setConfigurationState(true)
        cameraPreview.freezePreview(true)
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
            
            let sessionIsRunning = self.captureSession.isRunning
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                withAnimation(sessionIsRunning ? .easeInOut(duration: 0.15) : nil) {
                    self.camera?.state.previewDimming = true
                } completion: {
                    self.cameraPreview.freezePreview(false)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.camera?.state.previewDimming = false
                    }
                    Task { @CameraActor in
                        self.setConfigurationState(false)
                    }
                }
            }
        }
        
        if captureSession.canSetSessionPreset(profile.sessionPreset) {
            captureSession.sessionPreset = profile.sessionPreset
        }
        
        let activeDevice = configureSessionInput(device: device)
        cameraPreview.adjustPreview(for: activeDevice)
        setupRotationCoordinator(for: activeDevice)
        updateOutputServices()
    }
    
    /// Replaces the session input with the one created from the given device.
    ///
    /// - Returns: The device that is actually connected to the session. This is the previous device if the requested one cannot be used.
    @discardableResult
    private func configureSessionInput(device requestedDevice: AVCaptureDevice) -> AVCaptureDevice {
        $zoomInformationObservers.cancelAll()
        
        let device: AVCaptureDevice
        do {
            if let activeCameraInput {
                captureSession.removeInput(activeCameraInput)
            }
            self.activeCameraInput = try addInput(from: requestedDevice)
            device = requestedDevice
        } catch {
            logger.error("Failed to use \(requestedDevice.localizedName) as capture input: \(error.localizedDescription)")
            
            guard let activeCameraInput else { return requestedDevice }
            
            // Roll back to the previous input and keep the coordinator in sync with the session.
            if captureSession.canAddInput(activeCameraInput) {
                captureSession.addInput(activeCameraInput)
            }
            device = activeCameraInput.device
            if cameraInputDevice != device {
                cameraInputDevice = device // no-op in `didSet` since it matches the active input.
            }
        }
        
        let displayZoomFactorMultiplier: CGFloat
        if #available(iOS 18.0, macOS 14.0, *) {
            displayZoomFactorMultiplier = observeDisplayZoomFactorMultiplier()
        } else {
            let wideAngleCameraZoomFactor = self.wideAngleCameraZoomFactor
            displayZoomFactorMultiplier = 1 / wideAngleCameraZoomFactor
            updateCamera { camera in
                camera.state.displayZoomFactorMultiplier = 1 / wideAngleCameraZoomFactor
            }
        }
        #if os(iOS)
        if device.isVirtualDevice && !device.constituentDevices.isEmpty {
            withCurrentCaptureDevice { device in
                device.videoZoomFactor = 1 / displayZoomFactorMultiplier
            }
        }
        observeDeviceZoomFactor()
        #endif
        
        updateCamera { camera in
            camera.state.flash.deviceEligible = device.hasFlash
        }

        #if os(iOS)
        if #available(iOS 18.0, *) {
            configureControls(for: device)
        }
        #endif
        
        return device
    }
    
    private func configureSessionOutputs() {
        guard let activeCameraInput else { return }
        
        let services = profile.outputServices
        let activeOutputs = self.activeOutputs
        
        self.activeOutputs.forEach {
            captureSession.removeOutput($0)
        }
        
        self.activeOutputs = []
        do {
            for service in services {
                func makeOutput<S: OutputService>(service: S) -> AVCaptureOutput {
                    let coordinator: S.Coordinator
                    if let existingCoordinator = outputServiceCoordinators.first(byUnwrapping: {
                        $0 as? S.Coordinator
                    }) {
                        coordinator = existingCoordinator
                    } else {
                        coordinator = service.makeCoordinator()
                        outputServiceCoordinators.append(coordinator)
                    }
                    
                    // FIXME: This is a backdoor for `PhotoCaptureService`
                    if let coordinator = coordinator as? PhotoCaptureService.Coordinator {
                        coordinator.cameraCoordinator = self
                    }
                    
                    let context = OutputServiceContext<S>(
                        coordinator: coordinator,
                        session: captureSession,
                        input: activeCameraInput
                    )
                    return service.makeOutput(context: context)
                }
                
                let output = _openExistential(service, do: makeOutput(service:))
                try addOutput(output)
                self.activeOutputs.append(output)
            }
        } catch {
            self.activeOutputs.forEach({ captureSession.removeOutput($0) })
            
            activeOutputs.forEach({ captureSession.addOutput($0) })
            self.activeOutputs = activeOutputs
        }
    }
    
    private func setupRotationCoordinator(for device: AVCaptureDevice) {
        Task { @MainActor in
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: cameraPreview.layer
            )
            observeRotationCoordinator()
        }
    }
    
    // MARK: - Input
    
    /// The active camera device input used by the session.
    @_spi(Internal)
    public var activeCameraInput: AVCaptureDeviceInput?
    /// The active capture device used by the session.
    @_spi(Internal)
    public var cameraInputDevice: AVCaptureDevice! {
        didSet {
            guard let cameraInputDevice, let activeCameraInput else { return }
            // The session is already using this device.
            guard activeCameraInput.device != cameraInputDevice else { return }
            
            do {
                try switchCaptureDevice(to: cameraInputDevice)
            } catch {
                logger.error("\(error.localizedDescription)")
            }
        }
    }
    
    /// Makes device input from the capture device and add it to the pipeline if possible.
    @discardableResult
    private func addInput(from inputDevice: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let deviceInput = try AVCaptureDeviceInput(device: inputDevice)
        if captureSession.canAddInput(deviceInput) {
            captureSession.addInput(deviceInput)
        } else {
            throw CameraError.failedToAddInput
        }
        return deviceInput
    }
    
    @discardableResult
    @available(iOS 18.0, macOS 14.0, *)
    private func observeDisplayZoomFactorMultiplier() -> CGFloat {
        withValueObservation(
            of: cameraInputDevice,
            keyPath: \.displayVideoZoomFactorMultiplier,
            cancellables: &zoomInformationObservers
        ) { [weak self] displayVideoZoomFactorMultiplier in
            self?.updateCamera { camera in
                camera.state.displayZoomFactorMultiplier = displayVideoZoomFactorMultiplier
            }
        }
        
        return cameraInputDevice.displayVideoZoomFactorMultiplier
    }
    #if os(iOS)
    @available(iOS 18.0, *)
    private func configureControls(for device: AVCaptureDevice) {
        guard captureSession.supportsControls else { return }

        for control in captureSession.controls {
            captureSession.removeControl(control)
        }

        let zoomSlider = AVCaptureSystemZoomSlider(device: device)
        let exposureSlider = AVCaptureSystemExposureBiasSlider(device: device)

        for control in [zoomSlider as AVCaptureControl, exposureSlider] {
            if captureSession.canAddControl(control) {
                captureSession.addControl(control)
            } else {
                logger.warning("Unable to add capture control \(control).")
            }
        }

        updateCamera { $0.state.isSystemZoomSliderActive = false }
        captureSession.setControlsDelegate(self, queue: .main)
    }

    /// A boolean value indicating whether the capture device is setting its zoom factor.
    @_spi(Internal)
    public var isSettingZoomFactor = false
    private func observeDeviceZoomFactor() {
        withValueObservation(
            of: cameraInputDevice,
            keyPath: \.videoZoomFactor,
            cancellables: &zoomInformationObservers
        ) { [weak self] videoZoomFactor in
            guard let self else { return }
            guard !self.isSettingZoomFactor else { return }
            self.updateCamera { camera in
                camera.state.syncZoomFactorFromDevice(videoZoomFactor)
            }
        }
    }
    #endif
    @Cancellables private var zoomInformationObservers
    
    private var wideAngleCameraZoomFactor: CGFloat {
        var switchOverZoomFactor: CGFloat = 1
        
        guard let device = self.cameraInputDevice else { return switchOverZoomFactor }
        
        #if os(iOS)
        let wideAngleCameraOffset = device.constituentDevices
            .enumerated()
            .first(where: { $0.element.deviceType == .builtInWideAngleCamera })?
            .offset
        guard let wideAngleCameraOffset else { return switchOverZoomFactor }
        
        // "These factors progress in the same order as the devices listed in that property." -- documentation
        // Since switchOverVideoZoomFactor count is N - 1 (where N == constituentDevices.count), shift left by one to remove 1.0x
        let switchOverZoomFactorOffset = wideAngleCameraOffset - /* 1.0x */ 1
        guard switchOverZoomFactorOffset >= 0 else { return switchOverZoomFactor }
        
        switchOverZoomFactor = CGFloat(
            truncating: device.virtualDeviceSwitchOverVideoZoomFactors[switchOverZoomFactorOffset]
        )
        #endif
        
        return switchOverZoomFactor
    }
    
    // MARK: - Output
    
    /// The active camera device input used by the session.
    private var activeOutputs: [AVCaptureOutput] = []
    private var outputServiceCoordinators: [Any] = []
    
    /// Adds the capture output to the pipeline if possible.
    private func addOutput(_ output: AVCaptureOutput) throws(CameraError) {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw CameraError.failedToAddOutput
        }
    }
    
    /// Retrieves the created capture output of an output service if it has been created.
    @_spi(Internal)
    public func captureOutput<T: OutputService>(of: T.Type) -> T.Output? {
        activeOutputs.first(byUnwrapping: { $0 as? T.Output })
    }
    
    /// Gets current context of the output service.
    @_spi(Internal)
    public func outputContext<T: OutputService>(for: T.Type) -> OutputServiceContext<T>? {
        guard let activeCameraInput else { return nil }
        
        let coordinator = outputServiceCoordinators.first(byUnwrapping: { $0 as? T.Coordinator })
        guard let coordinator else { return nil }
        
        return .init(coordinator: coordinator, session: captureSession, input: activeCameraInput)
    }
    
    private func updateOutputServices() {
        func updateOutput<S: OutputService>(service: S) throws {
            let output = activeOutputs.first(byUnwrapping: { $0 as? S.Output })
            let context = outputContext(for: S.self)
            
            guard let output, let context else { throw CameraError.failedToUpdateOutputService }
            service.updateOutput(output: output, context: context)
        }
        
        for service in profile.outputServices {
            do {
                try _openExistential(service, do: updateOutput(service:))
            } catch {
                logger.error("Failed to update output service (\(String(reflecting: service))): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Rotation Coordinator
    
    /// A set of observers that observe the properties of `rotationCoordinator`.
    @Cancellables private var rotationObservers
    /// A rotation coordinator that monitors physical orientation to ensure the level of preview and captured content is relative to gravity.
    // nonisolated(unsafe): mutation and reads both occur on MainActor (inside setupRotationCoordinator's Task { @MainActor in … }); nonisolated(unsafe) is required because property wrappers and actor isolation don't compose.
    nonisolated(unsafe) private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    nonisolated private func observeRotationCoordinator() {
        guard let rotationCoordinator else { return }
        $rotationObservers.cancelAll()

        withValueObservation(
            of: rotationCoordinator,
            keyPath: \.videoRotationAngleForHorizonLevelCapture,
            cancellables: &$rotationObservers.wrappedValue // Swift does not support `nonisolated(unsafe)` directly on properties with property wrappers
        ) { [weak self] angle in
            guard let self else { return }
            Task { @CameraActor [self] in
                for output in self.activeOutputs {
                    guard let connection = output.connection(with: .video),
                          connection.isVideoRotationAngleSupported(angle) else { continue }
                    connection.videoRotationAngle = angle
                }
            }
            self.updateCamera {
                $0.state.captureRotationAngle = angle
            }
        }

        withValueObservation(
            of: rotationCoordinator,
            keyPath: \.videoRotationAngleForHorizonLevelPreview,
            cancellables: &$rotationObservers.wrappedValue // Swift does not support `nonisolated(unsafe)` directly on properties with property wrappers
        ) { [weak self] angle in
            guard let self else { return }
            self.updateCamera { camera in
                camera.state.previewRotationAngle = angle
                if let connection = self.cameraPreview.preview.videoPreviewLayer.connection,
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }
    
    @_spi(Internal)
    public func withCurrentCaptureDevice(
        perform action: @escaping (AVCaptureDevice) throws -> Void
    ) {
        guard let cameraInputDevice else { return }
        do {
            try cameraInputDevice.lockForConfiguration()
            defer { cameraInputDevice.unlockForConfiguration() }
            
            try action(cameraInputDevice)
        } catch {
            logger.error("Cannot lock device for configuration: \(error.localizedDescription)")
        }
    }
}

// MARK: - Auxiliary

extension CameraCoordinator {
    nonisolated private func updateCamera(
        perform action: @MainActor @Sendable @escaping (Camera) -> Void
    ) {
        Task { @MainActor [weak self] in
            // The camera may have been released while this update was in flight.
            guard let self, let camera = self.camera else { return }
            action(camera)
        }
    }

    private func setConfigurationState(_ isConfiguring: Bool) {
        let sessionIsRunning = captureSession.isRunning
        updateCamera { camera in
            let currentState = camera.state.captureSessionState

            switch (currentState, isConfiguring) {
                case (.running, true):
                    camera.state.captureSessionState = .configuring
                case (.configuring, false):
                    camera.state.captureSessionState = sessionIsRunning ? .running : .idle
                default:
                    break
            }
        }
    }
}

// MARK: - Camera Control (iOS)

#if os(iOS)
@available(iOS 18.0, *)
extension CameraCoordinator: AVCaptureSessionControlsDelegate {
    nonisolated public func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        updateCamera { $0.state.isSystemZoomSliderActive = true }
    }

    nonisolated public func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        updateCamera { $0.state.controlsFullscreen = true }
    }

    nonisolated public func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        updateCamera { $0.state.controlsFullscreen = false }
    }

    nonisolated public func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        updateCamera { $0.state.isSystemZoomSliderActive = false }
    }
}
#endif
