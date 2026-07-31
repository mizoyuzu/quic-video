import AVFoundation
import CoreMedia
import Foundation

enum CameraCaptureError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case unsupportedPreset
    case configuration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noCamera: return "Back wide-angle camera is unavailable"
        case .cannotAddInput: return "Could not add camera input"
        case .cannotAddOutput: return "Could not add video output"
        case .unsupportedPreset: return "Selected preset is not supported by this camera"
        case .configuration(let status): return "Camera configuration failed: \(status)"
        }
    }
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let preset: StreamPreset
    private let encoder: VideoEncoder
    private let logger: SessionLogger
    private let sessionQueue = DispatchQueue(label: "net.nasno.quic-video.camera")
    private let outputQueue = DispatchQueue(label: "net.nasno.quic-video.capture", qos: .userInteractive)
    private let scaler: PixelBufferScaler
    private var frameID: UInt64 = 0
    private var configured = false

    init(preset: StreamPreset, encoder: VideoEncoder, logger: SessionLogger) throws {
        self.preset = preset
        self.encoder = encoder
        self.logger = logger
        scaler = try PixelBufferScaler(width: preset.width, height: preset.height)
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        try configure()
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.sync {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            configured = true
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraCaptureError.noCamera
        }
        guard preset.isSupported(by: camera) else {
            throw CameraCaptureError.unsupportedPreset
        }
        guard let format = camera.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = max(dimensions.width, dimensions.height)
            let height = min(dimensions.width, dimensions.height)
            return width >= Int32(preset.width) && height >= Int32(preset.height)
                && format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= Double(preset.fps) && $0.maxFrameRate >= Double(preset.fps)
                }
        }) else {
            throw CameraCaptureError.unsupportedPreset
        }

        do {
            try camera.lockForConfiguration()
            camera.activeFormat = format
            camera.activeVideoMinFrameDuration = preset.frameDuration
            camera.activeVideoMaxFrameDuration = preset.frameDuration
            camera.unlockForConfiguration()
        } catch {
            throw error
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraCaptureError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw CameraCaptureError.cannotAddOutput }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            connection.videoOrientation = .landscapeRight
            connection.preferredVideoStabilizationMode = .off
        }
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard configured, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            Task { await logger.record(LogRecord(sessionID: await logger.sessionID ?? "unknown", event: "capture_missing_buffer")) }
            return
        }
        let currentFrameID = frameID
        frameID &+= 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        Task {
            let sessionID = await logger.sessionID ?? "unknown"
            await logger.record(LogRecord(
                sessionID: sessionID,
                event: "capture",
                frameID: currentFrameID,
                mediaPTSUs: UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000),
                codec: nil,
                width: preset.width,
                height: preset.height,
                fps: preset.fps
            ))
        }

        do {
            let outputBuffer = try scaler.scale(imageBuffer)
            encoder.encode(pixelBuffer: outputBuffer, presentationTimeStamp: pts)
        } catch {
            Task {
                let sessionID = await logger.sessionID ?? "unknown"
                await logger.record(LogRecord(
                    sessionID: sessionID,
                    event: "capture_error",
                    frameID: currentFrameID,
                    errorDomain: "CameraCapture",
                    errorMessage: error.localizedDescription
                ))
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Task {
            let sessionID = await logger.sessionID ?? "unknown"
            let attachment = CMGetAttachment(
                sampleBuffer,
                key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                attachmentModeOut: nil
            )
            let reason = attachment.map { String(describing: $0) } ?? "unknown"
            await logger.record(LogRecord(
                sessionID: sessionID,
                event: "capture_drop",
                dropReason: reason,
                attributes: ["source": "AVCaptureVideoDataOutput"]
            ))
        }
    }
}
