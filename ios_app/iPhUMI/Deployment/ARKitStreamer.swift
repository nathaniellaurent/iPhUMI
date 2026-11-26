//
//  ARKitStreamer.swift
//  iPhUMI
//
//  Deployment capture from an ARSession, so that the streamed color image and depth come from the same pipeline as
//  the recordings: ARKit's main-camera image and sceneDepth (not the AVFoundation LiDAR depth, which differs).
//
//  Per sent ARFrame, back to back:
//    main port (5555): JPEG of the color image, resized to the stream width (same as the camera path)
//    depth port (5557): one "frame info" message, laid out below (all little-endian)
//
//    offset  size  field
//         0     4  magic "ARKD"
//         4     4  u32 version (1)
//         8     4  u32 header size in bytes (132); depth values start here
//        12     8  u64 frame index (counts sent frames from 0)
//        20     8  f64 ARFrame.timestamp (seconds, same clock as CACurrentMediaTime)
//        28     8  u32 x2 width, height of ARKit's full color image (the intrinsics below refer to this size)
//        36     8  u32 x2 depth width, height (0, 0 when depth is off)
//        44    16  f32 x4 fx, fy, cx, cy in pixels of the full color image
//        60    64  f32 x16 camera transform (camera to world), column-major
//       124     4  u32 tracking state: 0 not available, 1 limited, 2 normal
//       128     4  u32 1 if a confidence map follows the depth, else 0
//       132        f32 depth in metres, row by row, no row padding (depth width x height values)
//                  u8 confidence (0 low, 1 medium, 2 high), row by row (depth width x height values), if flagged
//

import ARKit
import CoreImage
import UIKit

final class ARKitStreamer: NSObject, ARSessionDelegate {
    static let headerSize = 132

    let session = ARSession()
    private let depthEnabled: Bool
    private let streamWidth: Int
    private let targetFPS: Double

    /// Called on a background queue with the JPEG and the frame info message of one ARFrame (and its depth map, for
    /// the Ethernet path, which sends depth the way the camera path does).
    var send: ((_ jpeg: Data, _ frameInfo: Data, _ depthMap: CVPixelBuffer?, _ frame: SentFrame) -> Void)?
    /// Called on the main queue for problems worth showing on screen.
    var onError: ((String) -> Void)?

    struct SentFrame {
        let timestamp: TimeInterval
        let streamWidth: Int
        let streamHeight: Int
        let depthWidth: Int
        let depthHeight: Int
        let trackingState: UInt32
    }

    private let encodeQueue = DispatchQueue(label: "arkitEncodeQueue")
    private let ciContext = CIContext()
    private let busyLock = NSLock()
    private var busy = false
    private var framesSeen = 0
    private var sendEvery = 1
    private var frameIndex: UInt64 = 0

    init(depthEnabled: Bool, streamWidth: Int, targetFPS: Double) {
        self.depthEnabled = depthEnabled
        self.streamWidth = streamWidth
        self.targetFPS = targetFPS
        super.init()
        session.delegate = self
        session.delegateQueue = DispatchQueue(label: "arkitSessionQueue")
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func start() {
        // Same configuration as the recording screen as far as the images go: default video format, autofocus on,
        // and .sceneDepth (not .smoothedSceneDepth).
        let configuration = ARWorldTrackingConfiguration()
        if depthEnabled {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            } else {
                reportError("ARKIT: NO SCENE DEPTH ON THIS PHONE")
            }
        }
        let formatFPS = Double(configuration.videoFormat.framesPerSecond)
        sendEvery = max(1, Int((formatFPS / targetFPS).rounded()))
        framesSeen = 0
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        framesSeen += 1
        if (framesSeen - 1) % sendEvery != 0 {
            return
        }
        // Drop this frame if the previous one is still being encoded: holding on to ARFrames stalls ARKit.
        busyLock.lock()
        if busy {
            busyLock.unlock()
            return
        }
        busy = true
        busyLock.unlock()

        let image = frame.capturedImage
        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)
        let depthMap = depthEnabled ? frame.sceneDepth?.depthMap : nil
        let confidenceMap = depthEnabled ? frame.sceneDepth?.confidenceMap : nil
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let trackingState: UInt32
        switch frame.camera.trackingState {
        case .notAvailable: trackingState = 0
        case .limited: trackingState = 1
        case .normal: trackingState = 2
        }

        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.busyLock.lock()
                self.busy = false
                self.busyLock.unlock()
            }
            let scale = CGFloat(self.streamWidth) / CGFloat(imageWidth)
            guard let jpeg = self.jpegData(image, scale: scale) else { return }
            let frameInfo = self.frameInfoMessage(
                timestamp: timestamp, imageWidth: imageWidth, imageHeight: imageHeight,
                intrinsics: intrinsics, transform: transform, trackingState: trackingState,
                depthMap: depthMap, confidenceMap: confidenceMap)
            let sent = SentFrame(
                timestamp: timestamp,
                streamWidth: self.streamWidth,
                streamHeight: Int((CGFloat(imageHeight) * scale).rounded()),
                depthWidth: depthMap.map { CVPixelBufferGetWidth($0) } ?? 0,
                depthHeight: depthMap.map { CVPixelBufferGetHeight($0) } ?? 0,
                trackingState: trackingState)
            self.frameIndex += 1
            self.send?(jpeg, frameInfo, depthMap, sent)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        reportError("ARKIT ERROR: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        reportError("ARKIT INTERRUPTED")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // tracking restarts from scratch so poses after an interruption are not mixed with poses before it
        session.run(session.configuration ?? ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Encoding

    private func reportError(_ message: String) {
        DispatchQueue.main.async { self.onError?(message) }
    }

    private func jpegData(_ pixelBuffer: CVPixelBuffer, scale: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if scale != 1.0 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }

    private func frameInfoMessage(timestamp: TimeInterval, imageWidth: Int, imageHeight: Int,
                                  intrinsics: simd_float3x3, transform: simd_float4x4, trackingState: UInt32,
                                  depthMap: CVPixelBuffer?, confidenceMap: CVPixelBuffer?) -> Data {
        let depthWidth = depthMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let depthHeight = depthMap.map { CVPixelBufferGetHeight($0) } ?? 0
        let hasConfidence = depthMap != nil && confidenceMap != nil
            && CVPixelBufferGetWidth(confidenceMap!) == depthWidth && CVPixelBufferGetHeight(confidenceMap!) == depthHeight

        var data = Data(capacity: ARKitStreamer.headerSize + depthWidth * depthHeight * 5)
        data.append(contentsOf: Array("ARKD".utf8))
        appendLE(&data, UInt32(1))
        appendLE(&data, UInt32(ARKitStreamer.headerSize))
        appendLE(&data, frameIndex)
        appendLE(&data, timestamp.bitPattern)
        appendLE(&data, UInt32(imageWidth))
        appendLE(&data, UInt32(imageHeight))
        appendLE(&data, UInt32(depthWidth))
        appendLE(&data, UInt32(depthHeight))
        // simd matrices are column-major: columns.2 holds cx, cy
        for value in [intrinsics.columns.0.x, intrinsics.columns.1.y, intrinsics.columns.2.x, intrinsics.columns.2.y] {
            appendLE(&data, value.bitPattern)
        }
        for column in [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3] {
            for value in [column.x, column.y, column.z, column.w] {
                appendLE(&data, value.bitPattern)
            }
        }
        appendLE(&data, trackingState)
        appendLE(&data, UInt32(hasConfidence ? 1 : 0))
        assert(data.count == ARKitStreamer.headerSize)

        if let depthMap {
            appendRows(&data, depthMap, bytesPerPixel: 4)
        }
        if hasConfidence, let confidenceMap {
            appendRows(&data, confidenceMap, bytesPerPixel: 1)
        }
        return data
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// Copies the pixel rows without the padding CoreVideo may add at the end of each row.
    private func appendRows(_ data: inout Data, _ pixelBuffer: CVPixelBuffer, bytesPerPixel: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            data.append(base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * bytesPerPixel)
        }
    }
}
