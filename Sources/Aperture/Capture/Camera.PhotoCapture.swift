//
//  Camera.PhotoCapture.swift
//  Aperture
//
//  Created by Yanan Li on 2025/12/27.
//

import Foundation
@preconcurrency import AVFoundation

extension Camera {
    /// Takes a photo of current scene.
    nonisolated public func takePhoto(
        configuration: PhotoCaptureConfiguration,
        dataRepresentationCustomizer: (any PhotoFileDataRepresentationCustomizer)? = nil
    ) async throws -> CapturedPhoto {
        let service = await profile.photoCaptureService

        let (photoOutput, photoSettings) = try await { @CameraActor in
            let context = coordinator.outputContext(for: PhotoCaptureService.self)
            guard let context else { throw CaptureError.noContext }

            let photoOutput = coordinator.captureOutput(of: PhotoCaptureService.self)
            guard let photoOutput, let service else { throw CaptureError.photoOutputServiceNotAvailable }

            let photoSettings = try await service.createPhotoSettings(
                output: photoOutput,
                configuration: configuration,
                context: context
            )
            return (photoOutput, photoSettings)
        }()

        let capturedPhoto = try await withPhotoOutputReadinessCoordinatorTracking(
            output: photoOutput,
            photoSettings: photoSettings
        ) {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = PhotoCaptureDelegate(
                    camera: self,
                    dataRepresentationCustomizer: dataRepresentationCustomizer,
                    continuation: continuation
                )
                Task { @MainActor in
                    self.inFlightPhotoCaptureDelegates[photoSettings.uniqueID] = delegate
                }

                photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
            }
        }

        Task { @MainActor in
            self.inFlightPhotoCaptureDelegates[photoSettings.uniqueID] = nil
        }

        return capturedPhoto
    }
    
    nonisolated private func withPhotoOutputReadinessCoordinatorTracking<T>(
        output: AVCapturePhotoOutput,
        photoSettings: AVCapturePhotoSettings,
        perform action: () async throws -> T
    ) async rethrows -> T {
        var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
        #if os(iOS)
        readinessCoordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: output)

        let delegate = await PhotoReadinessCoordinatorDelegate(camera: self)
        defer { _ = delegate }
        readinessCoordinator?.delegate = delegate
        #endif

        readinessCoordinator?.startTrackingCaptureRequest(using: photoSettings)
        defer { readinessCoordinator?.stopTrackingCaptureRequest(using: photoSettings.uniqueID) }
        return try await action()
    }
}

// MARK: - Delegate

final class PhotoReadinessCoordinatorDelegate: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate, @unchecked Sendable {
    unowned let camera: Camera

    @MainActor
    init(camera: Camera) {
        self.camera = camera
    }

    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        Task { @MainActor in
            camera.state.shutterDisabled = captureReadiness != .ready
            camera.state.isBusyProcessing = captureReadiness == .notReadyWaitingForProcessing
        }
    }
}

