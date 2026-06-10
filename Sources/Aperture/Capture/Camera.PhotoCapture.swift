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

        let captureID = photoSettings.uniqueID
        func performCapture() async throws -> CapturedPhoto {
            try await withPhotoOutputReadinessCoordinatorTracking(
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
                        self.inFlightPhotoCaptureDelegates[captureID] = delegate
                    }

                    // Interactions with the capture output are serialized on the session actor.
                    Task { @CameraActor in
                        photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
                    }
                }
            }
        }

        // Release the in-flight delegate on success and failure alike,
        // so failed captures don't leak their delegate.
        do {
            let capturedPhoto = try await performCapture()
            await MainActor.run { self.inFlightPhotoCaptureDelegates[captureID] = nil }
            return capturedPhoto
        } catch {
            await MainActor.run { self.inFlightPhotoCaptureDelegates[captureID] = nil }
            throw error
        }
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

