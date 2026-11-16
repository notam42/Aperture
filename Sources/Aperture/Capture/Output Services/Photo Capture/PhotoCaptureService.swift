//
//  PhotoCaptureService.swift
//  Aperture
//
//  Created by Yanan Li on 2025/12/21.
//

@preconcurrency import AVFoundation
import Foundation
import Combine
import OSLog

/// An output service that outputs photo data, including Live Photo.
public struct PhotoCaptureService: OutputService, Logging {
    /// A photo settings specifically configured for scene monitoring.
    ///
    /// This is NOT used when capturing a photo. It's only using for scene monitoring.
    public let sceneMonitoringPhotoSettings = AVCapturePhotoSettings()
    @Cancellables private var flashSceneObservers: Set<AnyCancellable>
    
    /// The option set that is used to configure the output.
    public var options: PhotoCaptureOptions
    
    /// Create an output service that takes photo from connected session.
    public init(options: PhotoCaptureOptions = .default) {
        self.options = options
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public static func == (lhs: PhotoCaptureService, rhs: PhotoCaptureService) -> Bool {
        // Two services are interchangeable when they request the same options.
        // (Reference-typed implementation details must not participate in the comparison.)
        lhs.options == rhs.options
    }
    
    public func makeOutput(context: Context) -> AVCapturePhotoOutput {
        let output = AVCapturePhotoOutput()
        output.maxPhotoQualityPrioritization = .quality

        #if os(iOS)
        sceneMonitoringPhotoSettings.flashMode = .auto
        output.photoSettingsForSceneMonitoring = sceneMonitoringPhotoSettings
        #endif
        
        return output
    }
    
    public func updateOutput(output: AVCapturePhotoOutput, context: Context) {
        let maxSupportedPhotoDimensions = context.inputDevice
            .activeFormat
            .supportedMaxPhotoDimensions
            .last
        if let maxSupportedPhotoDimensions {
            output.maxPhotoDimensions = maxSupportedPhotoDimensions
        }
    
        if output.isZeroShutterLagSupported {
            output.isZeroShutterLagEnabled = options.contains(.zeroShutterLag)
        }
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = options.contains(.responsiveCapture)
            if output.isFastCapturePrioritizationSupported {
                output.isFastCapturePrioritizationEnabled = options.contains(.fastCapturePrioritization)
            }
        }
        #if os(iOS)
        output.isLivePhotoCaptureEnabled = output.isLivePhotoCaptureSupported
        if output.isAutoDeferredPhotoDeliverySupported {
            output.isAutoDeferredPhotoDeliveryEnabled = options.contains(.autoDeferredPhotoDelivery)
        }
        if output.isAppleProRAWSupported {
            output.isAppleProRAWEnabled = options.contains(.appleProRAW)
        } else if options.contains(.appleProRAW) {
            logger.error("[Apple ProRAW] Current device or configuration doesn't support Apple ProRAW.")
        }
        if output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = options.contains(.deliversDepthData)
        }
        if output.isPortraitEffectsMatteDeliverySupported {
            output.isPortraitEffectsMatteDeliveryEnabled = options.contains(.deliversDepthData)
        }
        #endif
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, macCatalyst 18.0, *) {
            if output.isConstantColorSupported {
                output.isConstantColorEnabled = options.contains(.constantColor)
            }
        }
        
        #if os(iOS)
        flashSceneObservers = []
        withValueObservation(
            of: output,
            keyPath: \.isFlashScene,
            cancellables: &flashSceneObservers
        ) { isFlashScene in
            context.coordinator.setFlashScene(isFlashScene)
        }
        #endif
    }
    
    public final class Coordinator: FlashSceneRecommendationDelegate, @unchecked Sendable {
        weak var cameraCoordinator: CameraCoordinator!
        
        func setFlashScene(_ isFlashScene: Bool) {
            Task { @MainActor in
                // The camera may have been released while the observation was in flight.
                cameraCoordinator?.camera?.state.flash.isFlashRecommendedByScene = isFlashScene
            }
        }
    }
}

extension PhotoCaptureService {
    internal func createPhotoSettings(
        output: Output,
        configuration: PhotoCaptureConfiguration,
        context: Context
    ) async throws -> AVCapturePhotoSettings {
        let format = processPhotoFormat(for: output, configuration: configuration)
        
        var photoSettings: AVCapturePhotoSettings!
       
        #if os(iOS)
        if configuration.dataFormat.includesRAW {
            if let rawPixelFormat = output.availableRawPhotoPixelFormatTypes.first(where: {
                options.contains(.appleProRAW) ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }) {
                photoSettings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawPixelFormat,
                    processedFormat: format
                )
            } else {
                logger.warning("[RAW] Current capture device does not support RAW capture. Fallback to deliver a processed image. Only Apple ProRAW supports capturing from fusion camera.")
            }
        }
        #endif
        
        if photoSettings == nil {
            photoSettings = AVCapturePhotoSettings(format: format)
        }
         
        let supportedMaxPhotoDimensions = context.inputDevice.activeFormat.supportedMaxPhotoDimensions
        var dimensions = supportedMaxPhotoDimensions.first(where: {
            Int($0.width) * Int($0.height) > Int(configuration.preferredResolution._minimumPixelCount)
        })
        if dimensions == nil, let maximumSupportedPhotoDimensions = supportedMaxPhotoDimensions.last {
            logger.warning("Current capture device does not support \(configuration.preferredResolution.description). Fall back to the maximum dimensions supported by the device: \(maximumSupportedPhotoDimensions.width)x\(maximumSupportedPhotoDimensions.height)")
            dimensions = maximumSupportedPhotoDimensions
        }
        
        // Leave the default value untouched if the device does not report any dimensions.
        if let dimensions {
            photoSettings.maxPhotoDimensions = dimensions
        }
        
        setPhotoQualityPrioritizationIfSupported(
            configuration.qualityPrioritization,
            for: photoSettings
        )

        #if os(iOS)
        if #available(iOS 18.0, *) {
            if output.isShutterSoundSuppressionSupported {
                photoSettings.isShutterSoundSuppressionEnabled = true
            }
        }
        #endif
        #if os(iOS)
        if configuration.capturesLivePhoto {
            // Requesting a Live Photo when the output is not eligible for it raises an exception.
            if output.isLivePhotoCaptureEnabled && photoSettings.rawPhotoPixelFormatType == 0 {
                photoSettings.livePhotoMovieFileURL = URL.movieFileURL
            } else {
                logger.warning("[Live Photo] Live Photo capture is unavailable for current device or configuration. Fallback to deliver a still photo.")
            }
        }
        photoSettings.isDepthDataDeliveryEnabled = output.isDepthDataDeliveryEnabled
        photoSettings.isPortraitEffectsMatteDeliveryEnabled = output.isPortraitEffectsMatteDeliveryEnabled
        #endif
        
        let flash = await context.coordinator.cameraCoordinator?.camera?.state.flash
        if let flash, output.supportedFlashModes.contains(flash.userSelectedMode) {
            photoSettings.flashMode = flash.userSelectedMode
        }
        
        @available(iOS 18.0, macOS 15.0, tvOS 18.0, macCatalyst 18.0, *)
        func _enableConstantColorIfRequestedAndEligible() {
            guard options.contains(.constantColor) else { return }
            guard output.isConstantColorSupported else {
                logger.error("[Constant Color] Current device doesn't support constant color.")
                return
            }
            guard photoSettings.flashMode != .off else {
                logger.error("[Constant Color] Constant color is unavailable when flash mode is off.")
                return
            }
            
            photoSettings.isConstantColorEnabled = true
            photoSettings.isConstantColorFallbackPhotoDeliveryEnabled = true
        }
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, macCatalyst 18.0, *) {
            _enableConstantColorIfRequestedAndEligible()
        }
        
        #if os(iOS)
        if let previewPhotoPixelFormatType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
            photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
        }
        #endif
        
        return photoSettings
    }
    
    private func setPhotoQualityPrioritizationIfSupported(
        _ prioritization: AVCapturePhotoOutput.QualityPrioritization,
        for photoSettings: AVCapturePhotoSettings
    ) {
        #if os(iOS)
        guard _isSettingPhotoPrioritizationSupported(on: photoSettings) else {
            logger.warning("Setting quality priotitization is not supported when capturing a Bayer RAW photo.")
            return
        }
        #endif
        
        photoSettings.photoQualityPrioritization = prioritization
    }
    
    @available(macOS, unavailable)
    private func _isSettingPhotoPrioritizationSupported(
        on photoSettings: AVCapturePhotoSettings
    ) -> Bool {
        let rawPhotoPixelFormat = photoSettings.rawPhotoPixelFormatType
        
        guard AVCapturePhotoOutput.isBayerRAWPixelFormat(rawPhotoPixelFormat) else {
            return true // processed photo always support setting prioritization.
        }
        
        // Apple ProRAW is a special bayer RAW, and it supports setting prioritization.
        return AVCapturePhotoOutput.isAppleProRAWPixelFormat(rawPhotoPixelFormat)
    }
}

private extension PhotoCaptureService {
    private func processPhotoFormat(
        for output: AVCapturePhotoOutput,
        configuration: PhotoCaptureConfiguration
    ) -> [String : Any]? {
        let availableCodecTypes = output.availablePhotoCodecTypes
        guard !availableCodecTypes.isEmpty else {
            return nil
        }
        
        guard let codec = configuration.dataFormat.codec else {
            return nil
        }
        
        guard availableCodecTypes.contains(codec) else {
            return nil
        }
        
        return [AVVideoCodecKey : codec]
    }
}

protocol FlashSceneRecommendationDelegate {
    func setFlashScene(_ isFlashScene: Bool)
}

// MARK: - Auxiliary

fileprivate extension URL {
    /// A unique output location to write a movie.
    static var movieFileURL: URL {
        URL.temporaryDirectory
            .appending(component: UUID().uuidString)
            .appendingPathExtension(for: .quickTimeMovie)
    }
}
