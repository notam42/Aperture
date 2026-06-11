//
//  CameraActor.swift
//  Aperture
//
//  Created by Yanan Li on 2025/12/20.
//

import Foundation

/// A singleton actor whose executor is equivalent to a dispatch serial queue.
@globalActor
public final actor CameraActor {
    public static let shared = CameraActor()
    
    private let sessionQueue = DispatchSerialQueue(
        label: "liyanan2004.Aperture.CameraActor",
        qos: .userInitiated
    )
    
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }

    /// The serial dispatch queue backing this actor's executor.
    ///
    /// Use this when an AVFoundation API requires a callback queue that should be serialized with all other camera session work.
    @_spi(Internal)
    nonisolated public static var queue: DispatchSerialQueue {
        shared.sessionQueue
    }
}
