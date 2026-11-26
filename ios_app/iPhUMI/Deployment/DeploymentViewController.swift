//
//  DeploymentViewController.swift
//  iPhUMI
//
//  Created by Austin Patel on 1/31/25.
//  Copyright © 2025 Apple. All rights reserved.
//

import UIKit
import AVFoundation
import Compression
import CoreVideo

func cvPixelBufferToData(pixelBuffer: CVPixelBuffer) -> Data? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        return nil
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let dataSize = bytesPerRow * height

    let data = Data(bytesNoCopy: baseAddress, count: dataSize, deallocator: .none)
    return data
}

func cvPixelBufferToJPEGData(pixelBuffer: CVPixelBuffer, resizeScale: Float = 1.0) -> Data? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    var resizedImage = ciImage
    if resizeScale != 1.0 {
        resizedImage = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(resizeScale), y: CGFloat(resizeScale)))
    }
    let context = CIContext()
    guard let cgImage = context.createCGImage(resizedImage, from: resizedImage.extent) else {
        return nil
    }
    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
}

class RgbSocketPacket {
    var rgb: CIImage
    
    init(rgb: CIImage) {
        self.rgb = rgb
    }
    
    func toEncodedString() -> String {
        // Use JPEG (not PNG) so high-resolution frames stay under Socket.IO message size limits.
        return SocketUtil.encodeCIImageToJPEGBase64(rgb, compressionQuality: 0.9)!
    }
}

enum ConnectionType {
    case USB
    case Ethernet
}

class DepthSocketPacket {
    var depth: CVPixelBuffer
    
    init(depth: CVPixelBuffer) {
        self.depth = depth
    }
    
    func toEncodedString() -> String {
        return SocketUtil.encodeDepthPixelBufferToBase64(depth)!
    }
}

class DeploymentViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    @IBOutlet weak var resetButton: UIButton!

    @IBOutlet weak var lidarView: UIView!
    @IBOutlet weak var ultrawideView: UIView!
    @IBOutlet weak var wideView: UIView!
    var lidarImageView: UIImageView!
    
    // Multi-cam session (main + ultrawide) by default. Replaced in viewDidLoad by a plain AVCaptureSession when the
    // "Main only" setting is on, so that multi-cam format limits and hardware cost do not apply.
    var captureSession: AVCaptureSession = AVCaptureMultiCamSession()

    // "Cameras" setting as stored in UserDefaults (deployMainCameraOnly)
    var mainCameraOnlySetting: Bool = false
    // Mode this screen actually runs in: follows the session type chosen in viewDidLoad, so it cannot change while the session is alive
    var mainCameraOnly: Bool {
        return !(captureSession is AVCaptureMultiCamSession)
    }

    // "Capture Source" setting as stored in UserDefaults (deployCaptureSourceARKit)
    var captureSourceARKitSetting: Bool = false
    // Set in viewDidLoad when this screen captures from ARKit instead of the AVFoundation session above
    var arkitStreamer: ARKitStreamer?
    
    // Define inputs
    var lidarCamera: AVCaptureDevice?
    var ultraWideCamera: AVCaptureDevice?
    var wideCamera: AVCaptureDevice?
    
    var lidarPreviewLayer: AVCaptureVideoPreviewLayer?
    var ultrawidePreviewLayer: AVCaptureVideoPreviewLayer?
    var widePreviewLayer: AVCaptureVideoPreviewLayer?
    
    @IBOutlet weak var streamingModeLabel: UILabel!
    
    // Define outputs
    var wideOutput: AVCaptureVideoDataOutput?
    var ultrawideOutput: AVCaptureVideoDataOutput?
    var depthOutput: AVCaptureDepthDataOutput?
    
    // Socket
    let mainSocketClient = SocketClient()
    let ultrawideSocketClient = SocketClient()
    let depthSocketClient = SocketClient()
    var hostIP: String = "192.168.123.18"
    var mainPort: Int = 5555
    var ultrawidePort: Int = 5556
    var depthPort: Int = 5557
    var socketTimer: Timer?
    var previewEnabled: Bool = false
    var depthEnabled: Bool = false
    var ultrawideAutofocusEnabled: Bool = false

    var wideUSBManager: USBManager = USBManager(port: 5555)
    var ultrawideUSBManager: USBManager = USBManager(port: 5556)
    var depthUSBManager: USBManager = USBManager(port: 5557)

    /// Cached so capture/depth delegates (which run on background queues) can read it without touching UI.
    private var cachedConnectionType: ConnectionType = .USB
    
    // High-resolution capture (used for "High" stream resolution mode)
    let highResolutionWidth: Int = 1920
    let highResolutionHeight: Int = 1440

    // Low-resolution capture (used for "Low" stream resolution mode)
    let lowResolutionWidth: Int = 640
    let lowResolutionHeight: Int = 480

    // Current capture resolution, derived from the stream resolution segmented control
    var captureResolutionWidth: Int = 1920
    var captureResolutionHeight: Int = 1440

    // Resize factor applied before streaming (remains 0.5 for both modes)
    let cameraResizeScale: Float = 0.5

    // Current target FPS for RGB cameras
    var cameraFPS: Float64 = 60

    // FPS counter
    @IBOutlet weak var ultrawideFPSCoutner: UILabel!
    @IBOutlet weak var wideFPSCounter: UILabel!
    @IBOutlet weak var depthFPSCounter: UILabel!
    var lastUltrawideTime: CMTime? = nil
    var lastWideTime: CMTime? = nil
    var lastDepthTime: CMTime? = nil

    // Capture failure shown in the main camera's FPS label instead of the FPS / "CAMERA NOT UPDATING" (main thread only)
    var wideCameraErrorText: String? = nil
    
    // Socket status
    @IBOutlet weak var ultrawideSocketStatusLabel: UILabel!
    @IBOutlet weak var wideSocketStatusLabel: UILabel!
    @IBOutlet weak var depthSocketStatusLabel: UILabel!
    
    @IBOutlet weak var depthCameraHeaderLabel: UILabel!
    
    @IBOutlet weak var ultrawideMainLabel: UILabel!
    override func viewDidLoad() {
        // prevent screen from going to sleep
        UIApplication.shared.isIdleTimerDisabled = true

        applySettingsFromDefaults()

        // "Main only": capture just the main camera with a plain session (must be created before the session is configured in viewDidAppear)
        if mainCameraOnlySetting {
            let session = AVCaptureSession()
            session.sessionPreset = .inputPriority // formats are set on the device directly (the multi-cam session always works this way)
            captureSession = session
        }

        // "ARKit": color image and sceneDepth come from an ARSession, as in the recordings; the AVFoundation session is not used
        if captureSourceARKitSetting && ARKitStreamer.isSupported {
            captureSession = AVCaptureSession() // never configured; a plain session makes the ultrawide UI below hide as in "Main only"
            setUpARKitStreamer()
        }

        // Create UIImageView for LiDAR depth data
        if previewEnabled && depthEnabled {
            lidarImageView = UIImageView(frame: lidarView.bounds)
            lidarImageView.contentMode = .scaleAspectFill
            lidarView.addSubview(lidarImageView)
        }
        
        if !depthEnabled {
            depthCameraHeaderLabel.text = ""
            depthSocketStatusLabel.isHidden = true
        } else {
            depthSocketStatusLabel.isHidden = false
        }
        
        // Hide FPS counters initially
        ultrawideFPSCoutner.text = ""
        wideFPSCounter.text = ""
        depthFPSCounter.text = ""
        
        // Hide socket text initially
        ultrawideSocketStatusLabel.text = ""
        wideSocketStatusLabel.text = ""
        depthSocketStatusLabel.text = ""
        
        streamingModeLabel.text = getConnectionType() == .USB ? "USB Streaming" : "Ethernet Streaming"

        if ultrawideAutofocusEnabled {
            ultrawideMainLabel.text = "Ultrawide Camera (Autofocus)"
            ultrawideMainLabel.textColor = .systemRed
        }

        if mainCameraOnly {
            // ultrawide is not captured in this mode: say so and hide its preview / status labels
            ultrawideMainLabel.text = "Ultrawide off (Main only)"
            ultrawideMainLabel.textColor = .secondaryLabel
            ultrawideView.isHidden = true
            ultrawideFPSCoutner.isHidden = true
            ultrawideSocketStatusLabel.isHidden = true
        }
        if arkitStreamer != nil {
            ultrawideMainLabel.text = "Ultrawide off (ARKit)"
        }

        socketTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
           if self.getConnectionType() == .Ethernet {
               self.validateEthernetSocketConnection()
           }

            // Do not validate Ethernet every second: it causes disconnect/reconnect churn
            // when the server is under load (ack can time out), leading to "Invalid session" and rapid connect/disconnect.
            // Connection is established once in viewDidAppear via connectToCurrentSource().

            // update labels if camera feed gets stuck
            let uptime: Double = CACurrentMediaTime()
            if let lastUltrawideTime = self.lastUltrawideTime {
                let delta = uptime - CMTimeGetSeconds(lastUltrawideTime)
                if delta > 1 { // 1 second has past since last frame
                    self.ultrawideFPSCoutner.text = "CAMERA NOT UPDATING"
                }
            }
            
            if let lastWideTime = self.lastWideTime {
                let delta = uptime - CMTimeGetSeconds(lastWideTime)
                if delta > 1 { // 1 second has past since last frame
                    self.wideFPSCounter.text = self.wideCameraErrorText ?? "CAMERA NOT UPDATING"
                }
            }
            
            if let lastDepthTime = self.lastDepthTime {
                let delta = uptime - CMTimeGetSeconds(lastDepthTime)
                if delta > 1 { // 1 second has past since last frame
                    self.depthFPSCounter.text = "CAMERA NOT UPDATING"
                }
            }

            // Update connection status labels for USB mode
            if self.getConnectionType() == .USB {
                DispatchQueue.main.async {
                    self.ultrawideSocketStatusLabel.text = "USB: " + (self.ultrawideUSBManager.isConnected() ? "connected" : "disconnected")
                    self.wideSocketStatusLabel.text = "USB: " + (self.wideUSBManager.isConnected() ? "connected" : "disconnected")
                    if self.depthEnabled {
                        self.depthSocketStatusLabel.text = "USB: " + (self.depthUSBManager.isConnected() ? "connected" : "disconnected")
                    }
                }
            }
        }
        // cachedConnectionType is managed by applySettingsFromDefaults()
    }

    override func viewDidAppear(_ animated: Bool) {
        applySettingsFromDefaults()
        connectToCurrentSource()

        if let arkitStreamer {
            arkitStreamer.start()
            return
        }

        // make capture session failures visible (otherwise the stream just silently has no frames)
        NotificationCenter.default.addObserver(self, selector: #selector(captureSessionRuntimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: captureSession)
        NotificationCenter.default.addObserver(self, selector: #selector(captureSessionWasInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: captureSession)

        configureCaptureSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        socketTimer?.invalidate()
        socketTimer = nil
        disconnectFromAllSources()
        arkitStreamer?.pause()
        NotificationCenter.default.removeObserver(self, name: AVCaptureSession.runtimeErrorNotification, object: captureSession)
        NotificationCenter.default.removeObserver(self, name: AVCaptureSession.wasInterruptedNotification, object: captureSession)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func applySettingsFromDefaults() {
        let defaults = UserDefaults.standard
        
        // Preview enable
        if let deployEnablePreview = defaults.object(forKey: "deployEnablePreview") as? Bool {
            previewEnabled = deployEnablePreview
        } else {
            previewEnabled = true
            defaults.set(previewEnabled, forKey: "deployEnablePreview")
        }
        
        // Depth enable
        if let deployEnableDepth = defaults.object(forKey: "deployEnableDepth") as? Bool {
            depthEnabled = deployEnableDepth
        } else {
            depthEnabled = false
            defaults.set(depthEnabled, forKey: "deployEnableDepth")
        }

        // Ultrawide autofocus
        if let autofocus = defaults.object(forKey: "deployUltrawideAutofocus") as? Bool {
            ultrawideAutofocusEnabled = autofocus
        } else {
            ultrawideAutofocusEnabled = false
            defaults.set(false, forKey: "deployUltrawideAutofocus")
        }

        // Cameras (false: main + ultrawide, true: main only)
        if let deployMainCameraOnly = defaults.object(forKey: "deployMainCameraOnly") as? Bool {
            mainCameraOnlySetting = deployMainCameraOnly
        } else {
            mainCameraOnlySetting = false
            defaults.set(mainCameraOnlySetting, forKey: "deployMainCameraOnly")
        }

        // Capture source (false: camera via AVFoundation, true: ARKit)
        if let deployCaptureSourceARKit = defaults.object(forKey: "deployCaptureSourceARKit") as? Bool {
            captureSourceARKitSetting = deployCaptureSourceARKit
        } else {
            captureSourceARKitSetting = false
            defaults.set(captureSourceARKitSetting, forKey: "deployCaptureSourceARKit")
        }
        
        // Connection type (0: USB, 1: Ethernet)
        if let connectionIndex = defaults.object(forKey: "deployConnectionTypeIndex") as? Int {
            cachedConnectionType = (connectionIndex == 0) ? .USB : .Ethernet
        } else {
            cachedConnectionType = .USB
            defaults.set(0, forKey: "deployConnectionTypeIndex")
        }
        
        // RGB resolution (0: Low, 1: High)
        let resolutionIndex = (defaults.object(forKey: "deployStreamResolutionIndex") as? Int) ?? 0
        if defaults.object(forKey: "deployStreamResolutionIndex") == nil {
            defaults.set(resolutionIndex, forKey: "deployStreamResolutionIndex")
        }
        if resolutionIndex == 0 {
            captureResolutionWidth = lowResolutionWidth
            captureResolutionHeight = lowResolutionHeight
        } else {
            captureResolutionWidth = highResolutionWidth
            captureResolutionHeight = highResolutionHeight
        }
        
        // RGB FPS (0: 30, 1: 60)
        let fpsIndex = (defaults.object(forKey: "deployCameraFPSIndex") as? Int) ?? 1
        if defaults.object(forKey: "deployCameraFPSIndex") == nil {
            defaults.set(fpsIndex, forKey: "deployCameraFPSIndex")
        }
        cameraFPS = (fpsIndex == 0) ? 30 : 60

        // Ethernet host IP
        if let savedHost = defaults.string(forKey: "deployEthernetHostIP"),
           !savedHost.isEmpty {
            hostIP = savedHost
        } else {
            // Ensure a default is always stored.
            defaults.set(hostIP, forKey: "deployEthernetHostIP")
        }

        // Depth preview clipping distance (in meters)
        let defaultClipping: Float = 1.0
        if defaults.object(forKey: "deployDepthPreviewClippingDistance") == nil {
            defaults.set(defaultClipping, forKey: "deployDepthPreviewClippingDistance")
        }
    }

    private func streamingResolutionDescription() -> String {
        let streamedWidth = Int(Double(captureResolutionWidth) * Double(cameraResizeScale))
        let streamedHeight = Int(Double(captureResolutionHeight) * Double(cameraResizeScale))
        return "\(streamedWidth)x\(streamedHeight)"
    }

    private func configureCaptureSession() {
        captureSession.beginConfiguration()

        guard mainCameraOnly || AVCaptureMultiCamSession.isMultiCamSupported else { // "Main only" uses a plain session, so it does not need multi-cam support
            print("Multi-camera capture is not supported on this device.")
            showWideCameraError("MULTI-CAM NOT SUPPORTED")
            return
        }

        // Update resolution/FPS configuration based on persisted settings
        applySettingsFromDefaults()

        // "Main only": the ultrawide is not discovered, so ultraWideCamera stays nil and its input/output/preview setup below is skipped
        var deviceTypes: [AVCaptureDevice.DeviceType] = mainCameraOnly ? [] : [.builtInUltraWideCamera]
        if depthEnabled {
            deviceTypes.append(.builtInLiDARDepthCamera) // includes wide angle as part of depth
        } else {
            deviceTypes.append(.builtInWideAngleCamera)
        }
        // cameraFPS is already set by updateResolutionConfigFromUI() (60 for low res always, 30/60 for high res by depth)
        
        // Get LiDAR (includes wide RGB) and Ultrawide Camera devices
        let deviceDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )

        for device in deviceDiscovery.devices {
            switch device.deviceType {
            case .builtInLiDARDepthCamera:
                lidarCamera = device
                wideCamera = device // wide angle tied into LiDAR device
            case .builtInUltraWideCamera:
                ultraWideCamera = device
            case .builtInWideAngleCamera:
                wideCamera = device
            default:
                break
            }
        }
        
        // add camera input/outputs
        do {
            // Configure Ultra Wide Camera
            if let ultrawideDevice = ultraWideCamera {
                // input (for some reason this has to go before doing the configuration, otherwise the 60fps setting doensn't work and you get 24FPS)
                let ultrawideInput = try AVCaptureDeviceInput(device: ultrawideDevice)
                if captureSession.canAddInput(ultrawideInput) {
                    captureSession.addInput(ultrawideInput)
                }
                
                // set resolution and frame rate
                try ultrawideDevice.lockForConfiguration()
                if let format = ultrawideDevice.formats.first(where: { format in
                    if !format.isMultiCamSupported || format.isVideoHDRSupported { // see comment for wide camera for why we add this check for HDR (for some reason it's related to whether we can change focus modes)
                        return false
                    }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let supportedFrameRates = format.videoSupportedFrameRateRanges
                    
                    return dimensions.width == captureResolutionWidth && dimensions.height == captureResolutionHeight && supportedFrameRates.contains { $0.maxFrameRate >= cameraFPS }
                }) {
                    ultrawideDevice.activeFormat = format
                    let fpsTimescale = CMTimeScale(cameraFPS)
                    ultrawideDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fpsTimescale)
                    ultrawideDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fpsTimescale)

                    if ultrawideAutofocusEnabled {
                        assert(ultrawideDevice.isFocusModeSupported(.continuousAutoFocus))
                        ultrawideDevice.focusMode = .continuousAutoFocus
                    } else {
                        // ARKit locks ultrawide focus; replicate that here
                        assert(ultrawideDevice.isFocusModeSupported(.locked))
                        ultrawideDevice.focusMode = .locked
                        let lensPosition = UserDefaults.standard.object(forKey: "arKitUltrawideLensPosition") as! Float
                        ultrawideDevice.setFocusModeLocked(lensPosition: lensPosition)
                    }
                } else {
                    assert(false)
                }
                ultrawideDevice.unlockForConfiguration()
                
                // preview output
                if previewEnabled {
                    ultrawidePreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                    ultrawidePreviewLayer?.videoGravity = .resizeAspect
                    ultrawidePreviewLayer?.connection?.videoRotationAngle = 0
                    ultrawidePreviewLayer?.frame = ultrawideView.bounds
                    ultrawideView.layer.addSublayer(ultrawidePreviewLayer!)
                }
                
                // delegate output
                ultrawideOutput = AVCaptureVideoDataOutput()
                if captureSession.canAddOutput(ultrawideOutput!) {
                    captureSession.addOutput(ultrawideOutput!)
                    ultrawideOutput!.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ultrawideOutputQueue"))
                }
            }
            
            // Setup main RGB (if using depth then main RGB is tied into LiDAR device
            if let wideDevice = wideCamera {
                // input (for some reason this has to go before doing the configuration, otherwise the 60fps setting doensn't work and you get 24FPS or 30FPS)
                let wideInput = try AVCaptureDeviceInput(device: wideDevice)
                if captureSession.canAddInput(wideInput) {
                    captureSession.addInput(wideInput)
                }
                
                // set resolution and frame rate
                try wideDevice.lockForConfiguration()
                let wideFormat: AVCaptureDevice.Format?
                if mainCameraOnly {
                    // plain session: the format does not need to support multi-cam (this may lower cameraFPS to 30)
                    wideFormat = mainCameraOnlyFormat(for: wideDevice)
                } else {
                    wideFormat = wideDevice.formats.first(where: { format in
                        if !format.isMultiCamSupported || format.isVideoHDRSupported { // for some bizarre reason I found that the formats that support HDR do not have auto focus working... (likely this is just a correlation, but adding condition to skip formats that have HDR enabled me to ensure the auto focus system still works...
                            return false
                        }
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let supportedFrameRates = format.videoSupportedFrameRateRanges
                        
                        let valid = dimensions.width == captureResolutionWidth && dimensions.height == captureResolutionHeight && supportedFrameRates.contains { $0.maxFrameRate >= cameraFPS }
                        return valid
                    })
                }
                if let format = wideFormat {
                    wideDevice.activeFormat = format
                    let fpsTimescale = CMTimeScale(cameraFPS)
                    wideDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fpsTimescale)
                    wideDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fpsTimescale)
                    
                    if depthEnabled {
                        wideDevice.activeDepthDataMinFrameDuration = CMTime(value: 1, timescale: 30) // note you can only get depth at 30fps when streaming due to AV limitation (even though ARKit gives you 60fps depth)
                    }

                    // ARKit uses continuous auto focus for main camera
                    assert(wideDevice.isFocusModeSupported(.continuousAutoFocus))
                    wideDevice.focusMode = .continuousAutoFocus
                } else {
                    // no matching format: the device keeps its current format, so make that visible in the main camera's label
                    showWideCameraError("NO \(captureResolutionWidth)x\(captureResolutionHeight) FORMAT")
                    if !mainCameraOnly {
                        assert(false)
                    }
                }
                wideDevice.unlockForConfiguration()

                // preview output
                if previewEnabled {
                    widePreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                    widePreviewLayer?.videoGravity = .resizeAspect
                    widePreviewLayer?.connection?.videoRotationAngle = 0
                    widePreviewLayer?.frame = wideView.bounds
                    wideView.layer.addSublayer(widePreviewLayer!)
                }
                
                // delegate output
                wideOutput = AVCaptureVideoDataOutput()
                if captureSession.canAddOutput(wideOutput!) {
                    captureSession.addOutput(wideOutput!)
                    wideOutput!.setSampleBufferDelegate(self, queue: DispatchQueue(label: "wideOutputQueue"))
                }
            }
            
            // Configure LiDAR Camera
            if depthEnabled {
                if let lidarDevice = lidarCamera {
                    // add output delegate for depth
                    depthOutput = AVCaptureDepthDataOutput()
                    if captureSession.canAddOutput(depthOutput!) {
                        captureSession.addOutput(depthOutput!)
                        depthOutput!.setDelegate(self, callbackQueue: DispatchQueue(label: "depthOutputQueue"))
                    }
                }
            }
            
            // start running
            captureSession.commitConfiguration()
            captureSession.startRunning()
        } catch {
            print("Error configuring capture session: \(error)")
            showWideCameraError("CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    /// "Main only" mode: pick the main camera's format for a plain AVCaptureSession, i.e. without requiring multi-cam support.
    /// Tries, in order: formats without HDR support at cameraFPS (same preference as the multi-cam path), HDR-capable formats at cameraFPS,
    /// then the same two at 30 fps if 60 fps is not available. Sets cameraFPS to the frame rate that was actually found.
    private func mainCameraOnlyFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var fpsCandidates: [Float64] = [cameraFPS]
        if cameraFPS > 30 {
            fpsCandidates.append(30)
        }
        for fps in fpsCandidates {
            for allowHDR in [false, true] {
                if let format = device.formats.first(where: { format in
                    if format.isVideoHDRSupported && !allowHDR { // see comment for wide camera in configureCaptureSession for why formats with HDR are avoided
                        return false
                    }
                    // only 8-bit 4:2:0 (what the multi-cam formats deliver); without multi-cam the list also has 10-bit formats, which would change the streamed images
                    let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    if pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                        return false
                    }
                    if depthEnabled && format.supportedDepthDataFormats.isEmpty { // depth output needs a format that delivers depth
                        return false
                    }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let supportedFrameRates = format.videoSupportedFrameRateRanges
                    let frameRateSupported = supportedFrameRates.contains { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }

                    return dimensions.width == captureResolutionWidth && dimensions.height == captureResolutionHeight && frameRateSupported
                }) {
                    print("Main only: using format \(format) at \(fps) fps (requested \(cameraFPS) fps)")
                    cameraFPS = fps
                    return format
                }
            }
        }
        return nil
    }

    // MARK: - Capture session failures

    /// Shows a capture failure in the main camera's FPS label and keeps it there (see wideCameraErrorText). Call on the main thread.
    private func showWideCameraError(_ message: String) {
        print("Capture error: \(message)")
        wideCameraErrorText = message
        wideFPSCounter.text = message
    }

    @objc private func captureSessionRuntimeError(_ notification: Notification) {
        // e.g. the session could not start or stopped (can be posted on any thread)
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        print("Capture session runtime error: \(String(describing: error))")
        var message = "SESSION ERROR"
        if let error = error {
            message += " \(error.code): \(error.localizedDescription)"
        }
        DispatchQueue.main.async {
            self.showWideCameraError(message)
        }
    }

    @objc private func captureSessionWasInterrupted(_ notification: Notification) {
        // reason is the raw value of AVCaptureSession.InterruptionReason (e.g. 1: app in background, 3: camera in use by another app, 5: system pressure such as overheating)
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? 0
        print("Capture session interrupted (reason \(reason))")
        DispatchQueue.main.async {
            // not kept: the label goes back to the FPS as soon as frames arrive again
            self.lastWideTime = nil // otherwise the 1-second timer replaces this message with "CAMERA NOT UPDATING"
            self.wideFPSCounter.text = "INTERRUPTED (reason \(reason))"
        }
    }
    
    func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let transform = CGAffineTransform(scaleX: CGFloat(width) / CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
                                          y: CGFloat(height) / CGFloat(CVPixelBufferGetHeight(pixelBuffer)))
        let resizedImage = ciImage.transformed(by: transform)
        return resizedImage
    }
    
    // Delegate method to process captured frames
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == ultrawideOutput {
//            print("Captured from ultrawide camera \(sampleBuffer.outputPresentationTimeStamp) \(sampleBuffer.presentationTimeStamp)")
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let connectionType = getConnectionType()
                if connectionType == .USB {
                    if ultrawideUSBManager.isConnected(), let jpegData = cvPixelBufferToJPEGData(pixelBuffer: imageBuffer, resizeScale: cameraResizeScale) {
                        ultrawideUSBManager.sendData(data: jpegData)
                    }
                } else {
                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let resizedImage: CIImage
                    if cameraResizeScale != 1.0 {
                        resizedImage = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(cameraResizeScale), y: CGFloat(cameraResizeScale)))
                    } else {
                        resizedImage = ciImage
                    }
                    let dataPacket = RgbSocketPacket(rgb: resizedImage)
                    if ultrawideSocketClient.isConnected() {
                        ultrawideSocketClient.sendData(dataPacket.toEncodedString(), channel: "rgb")
                    }
                }

                // Update FPS counter
                var fps = ""
                let curTimestamp = sampleBuffer.presentationTimeStamp
                if let lastUltrawideTime = lastUltrawideTime {
                    fps = String(format: "%.2f", 1.0 / Double(CMTimeGetSeconds(curTimestamp - lastUltrawideTime))) + " FPS"
                }
                lastUltrawideTime = curTimestamp

                let resolutionDescription = streamingResolutionDescription()

                DispatchQueue.main.async {
                    self.ultrawideFPSCoutner.text = resolutionDescription + " @ " + fps
                    switch self.getConnectionType() {
                    case .USB:
                        self.ultrawideSocketStatusLabel.text = "USB: " + (self.ultrawideUSBManager.isConnected() ? "connected" : "disconnected")
                    case .Ethernet:
                        self.ultrawideSocketStatusLabel.text = "Ethernet: " + self.ultrawideSocketClient.getStatus()
                    }
                }
            }
        } else if output == wideOutput {
//            print("Captured from wide camera")
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let connectionType = getConnectionType()
                if connectionType == .USB {
                    if wideUSBManager.isConnected(), let jpegData = cvPixelBufferToJPEGData(pixelBuffer: imageBuffer, resizeScale: cameraResizeScale) {
                        wideUSBManager.sendData(data: jpegData)
                    }
                } else {
                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let resizedImage: CIImage
                    if cameraResizeScale != 1.0 {
                        resizedImage = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(cameraResizeScale), y: CGFloat(cameraResizeScale)))
                    } else {
                        resizedImage = ciImage
                    }
                    let dataPacket = RgbSocketPacket(rgb: resizedImage)
                    if mainSocketClient.isConnected() {
                        mainSocketClient.sendData(dataPacket.toEncodedString(), channel: "rgb")
                    }
                }

                // Update FPS counter
                var fps = ""
                let curTimestamp = sampleBuffer.presentationTimeStamp
                if let lastWideTime = lastWideTime {
                    fps = String(format: "%.2f", 1.0 / Double(CMTimeGetSeconds(curTimestamp - lastWideTime))) + " FPS"
                }
                lastWideTime = curTimestamp

                let resolutionDescription = streamingResolutionDescription()

                DispatchQueue.main.async {
                    self.wideFPSCounter.text = self.wideCameraErrorText ?? (resolutionDescription + " @ " + fps)
                    switch self.getConnectionType() {
                    case .USB:
                        self.wideSocketStatusLabel.text = "USB: " + (self.wideUSBManager.isConnected() ? "connected" : "disconnected")
                    case .Ethernet:
                        self.wideSocketStatusLabel.text = "Ethernet: " + self.mainSocketClient.getStatus()
                    }
                }
            }
        } else {
            assert(false)
        }
    }
    
    // Delegate method to process LiDAR depth data
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
//        print("Captured from LiDAR")
        
        assert(depthEnabled)

        // streaming
        let connectionType = getConnectionType()
        let convertedDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepthData.depthDataMap

        if connectionType == .USB {
            if depthUSBManager.isConnected() {
                if let depthDataBytes = cvPixelBufferToData(pixelBuffer: depthMap) {
                    depthUSBManager.sendData(data: depthDataBytes)
                }
            }
        } else {
            if depthSocketClient.isConnected() {
                let dataPacket = DepthSocketPacket(depth: depthMap)
                depthSocketClient.sendData(dataPacket.toEncodedString(), channel: "depth")
            }
        }

        // fps counter
        var fps = ""
        if let lastDepthTime = lastDepthTime {
            fps = String(format: "%.2f", 1.0 / Double(CMTimeGetSeconds(timestamp - lastDepthTime))) + " FPS"
        }
        lastDepthTime = timestamp

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthResolutionDescription = "\(depthWidth)x\(depthHeight)"

        DispatchQueue.main.async {
            self.depthFPSCounter.text = depthResolutionDescription + " @ " + fps
            switch self.getConnectionType() {
            case .USB:
                self.depthSocketStatusLabel.text = "USB: " + (self.depthUSBManager.isConnected() ? "connected" : "disconnected")
            case .Ethernet:
                self.depthSocketStatusLabel.text = "Ethernet: " + self.depthSocketClient.getStatus()
            }
        }
        
        // visual preview
        if previewEnabled {
            let imageBuffer = depthData.depthDataMap
            let depthImage = self.depthDataToImage(depthData)
            DispatchQueue.main.async {
                self.lidarImageView.image = depthImage
            }
        }
    }
    
    @IBAction func returnHomeButtonPress(_ sender: Any) {
        let defaults = UserDefaults.standard
        defaults.set(nil, forKey: "appMode")
        
        disconnectFromCurrentSource()
        
        self.dismiss(animated: true, completion: nil)
    }
    
    func depthDataToImage(_ depthData: AVDepthData) -> UIImage? {

        var convertedDepthData = depthData
        // depthData.depthDataType is kCVPixelFormatType_DisparityFloat16
        convertedDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        
        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)

        let defaults = UserDefaults.standard
        let defaultClipping: Float = 1.0
        let rawClipping = defaults.object(forKey: "deployDepthPreviewClippingDistance") as! Float
        let buffer = DepthPreviewVideoWriter.convertDepthBufferToOneComponent32Float(
            pixelBuffer: depthMap,
            maxDistanceMeters: rawClipping
        )!
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            return UIImage(cgImage: cgImage)
        }
        
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        return nil
    }
    
    // MARK: - Connection helpers (Ethernet)

    private func connectToEthernet() {
        if mainSocketClient.isConnected() {
            mainSocketClient.validateConnection()
        } else {
            mainSocketClient.connect(hostIP: hostIP, hostPort: mainPort)
        }
        if ultrawideSocketClient.isConnected() {
            ultrawideSocketClient.validateConnection()
        } else {
            ultrawideSocketClient.connect(hostIP: hostIP, hostPort: ultrawidePort)
        }
        if depthEnabled {
            if depthSocketClient.isConnected() {
                depthSocketClient.validateConnection()
            } else {
                depthSocketClient.connect(hostIP: hostIP, hostPort: depthPort)
            }
        }
    }

    private func disconnectFromEthernet() {
        mainSocketClient.disconnect()
        ultrawideSocketClient.disconnect()
        depthSocketClient.disconnect()
    }

    // MARK: - Connection helpers (USB)

    private func connectToUSB() {
        wideUSBManager.connect()
        ultrawideUSBManager.connect()
        if depthEnabled || arkitStreamer != nil { // ARKit sends its frame info (intrinsics, pose, timestamp) on the depth port even without depth
            depthUSBManager.connect()
        }
    }

    // MARK: - ARKit capture

    private func setUpARKitStreamer() {
        let streamWidth = Int(Float(captureResolutionWidth) * cameraResizeScale)
        let streamer = ARKitStreamer(depthEnabled: depthEnabled, streamWidth: streamWidth, targetFPS: cameraFPS)
        streamer.send = { [weak self] jpeg, frameInfo, depthMap, sent in
            guard let self else { return }
            switch self.getConnectionType() {
            case .USB:
                // image first, then the frame info of the same ARFrame, so a reader can pair them by arrival order
                if self.wideUSBManager.isConnected() {
                    self.wideUSBManager.sendData(data: jpeg)
                }
                if self.depthUSBManager.isConnected() {
                    self.depthUSBManager.sendData(data: frameInfo)
                }
            case .Ethernet:
                // same messages as the camera path (no frame info over Ethernet)
                if self.mainSocketClient.isConnected(), let image = CIImage(data: jpeg) {
                    self.mainSocketClient.sendData(RgbSocketPacket(rgb: image).toEncodedString(), channel: "rgb")
                }
                if self.depthEnabled, self.depthSocketClient.isConnected(), let depthMap {
                    self.depthSocketClient.sendData(DepthSocketPacket(depth: depthMap).toEncodedString(), channel: "depth")
                }
            }
            DispatchQueue.main.async {
                self.showARKitFrame(sent)
            }
        }
        streamer.onError = { [weak self] message in
            self?.showWideCameraError(message)
        }
        arkitStreamer = streamer
    }

    /// Updates the FPS / status labels for a frame sent from ARKit. Main thread.
    private func showARKitFrame(_ sent: ARKitStreamer.SentFrame) {
        let time = CMTime(seconds: sent.timestamp, preferredTimescale: 1_000_000_000) // ARKit timestamps use the CACurrentMediaTime clock, as the stall check in the timer expects
        var fps = ""
        if let lastWideTime {
            fps = String(format: "%.2f", 1.0 / CMTimeGetSeconds(time - lastWideTime)) + " FPS"
        }
        lastWideTime = time
        wideCameraErrorText = nil
        let tracking = sent.trackingState == 2 ? "" : (sent.trackingState == 1 ? " LIMITED TRACKING" : " NO TRACKING")
        wideFPSCounter.text = "\(sent.streamWidth)x\(sent.streamHeight) @ \(fps) (ARKit)\(tracking)"
        if depthEnabled {
            if sent.depthWidth > 0 {
                depthFPSCounter.text = "\(sent.depthWidth)x\(sent.depthHeight) @ \(fps) (sceneDepth)"
                lastDepthTime = time
            } else {
                depthFPSCounter.text = "NO SCENE DEPTH YET"
            }
        }
        switch getConnectionType() {
        case .USB:
            wideSocketStatusLabel.text = "USB: " + (wideUSBManager.isConnected() ? "connected" : "disconnected")
            if depthEnabled {
                depthSocketStatusLabel.text = "USB: " + (depthUSBManager.isConnected() ? "connected" : "disconnected")
            }
        case .Ethernet:
            wideSocketStatusLabel.text = "Ethernet: " + mainSocketClient.getStatus()
            if depthEnabled {
                depthSocketStatusLabel.text = "Ethernet: " + depthSocketClient.getStatus()
            }
        }
    }

    private func disconnectFromUSB(completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        group.enter()
        group.enter()
        wideUSBManager.disconnect {
            group.leave()
        }
        ultrawideUSBManager.disconnect {
            group.leave()
        }
        depthUSBManager.disconnect {
            group.leave()
        }
        group.notify(queue: .main) {
            completion?()
        }
    }

    // MARK: - Connection helpers (current source)

    private func connectToCurrentSource() {
        switch getConnectionType() {
        case .USB:
            connectToUSB()
        case .Ethernet:
            connectToEthernet()
        }
    }

    private func disconnectFromCurrentSource(completion: (() -> Void)? = nil) {
        switch getConnectionType() {
        case .USB:
            disconnectFromUSB(completion: completion)
        case .Ethernet:
            disconnectFromEthernet()
            completion?()
        }
    }

    /// Disconnects from both Ethernet and USB. Use when switching sources so only the selected source is connected.
    private func disconnectFromAllSources() {
        disconnectFromEthernet()
        disconnectFromUSB()
    }

    func validateEthernetSocketConnection() {
        guard getConnectionType() == .Ethernet else { return }
        connectToEthernet()
    }

    @IBAction func resetButtonPress(_ sender: Any) {
        disconnectFromCurrentSource()
        self.dismiss(animated: true, completion: nil)
    }

    private func getConnectionType() -> ConnectionType {
        return cachedConnectionType
    }

    @IBAction func settingsButtonPressed(_ sender: Any) {
        let settingsVC = DeploymentSettingsViewController()
        settingsVC.onDismiss = { [weak self] in
            self?.dismiss(animated: true)
        }
        settingsVC.onResetAndReturnHome = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: "appMode")
            self.disconnectFromCurrentSource()
            self.dismiss(animated: true)
        }
        let nav = UINavigationController(rootViewController: settingsVC)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}
