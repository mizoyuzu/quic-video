import CoreMedia
import Foundation
import VideoToolbox

struct EncodedAccessUnit: Sendable {
    let frameID: UInt64
    let payload: Data
    let presentationTimeUs: UInt64
    let isKeyframe: Bool
    let initializationData: Data?
}

private final class EncoderFrameReference {
    let frameID: UInt64

    init(frameID: UInt64) {
        self.frameID = frameID
    }
}

enum VideoEncoderError: LocalizedError {
    case create(OSStatus)
    case property(String, OSStatus)
    case encode(OSStatus)
    case missingImageBuffer
    case missingCodecConfiguration
    case emptyEncodedFrame

    var errorDescription: String? {
        switch self {
        case .create(let status): return "VideoToolbox session creation failed: \(status)"
        case .property(let name, let status): return "VideoToolbox property \(name) failed: \(status)"
        case .encode(let status): return "VideoToolbox encode failed: \(status)"
        case .missingImageBuffer: return "Capture sample has no image buffer"
        case .missingCodecConfiguration: return "VideoToolbox did not provide avcC/hvcC configuration"
        case .emptyEncodedFrame: return "VideoToolbox returned an empty access unit"
        }
    }
}

final class VideoEncoder {
    private let preset: StreamPreset
    private let codec: StreamCodec
    fileprivate let output: (Result<EncodedAccessUnit, Error>) -> Void
    private var session: VTCompressionSession?
    private var firstPTS: CMTime?
    private var nextFrameID: UInt64 = 0
    private var stopped = false

    init(
        preset: StreamPreset,
        codec: StreamCodec,
        output: @escaping (Result<EncodedAccessUnit, Error>) -> Void
    ) throws {
        self.preset = preset
        self.codec = codec
        self.output = output

        var created: VTCompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: preset.width,
            kCVPixelBufferHeightKey as String: preset.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(preset.width),
            height: Int32(preset.height),
            codecType: codec.codecType,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: videoCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw VideoEncoderError.create(status)
        }
        session = created
        try configure(created)
    }

    deinit {
        stop()
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session, !stopped else { return }
        if firstPTS == nil { firstPTS = presentationTimeStamp }

        var frameProperties: [String: Any]?
        if nextFrameID % UInt64(preset.gopFrames) == 0 {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }

        var flags = VTEncodeInfoFlags()
        let frameID = nextFrameID
        let frameReference = Unmanaged.passRetained(EncoderFrameReference(frameID: frameID))
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: preset.frameDuration,
            frameProperties: frameProperties as CFDictionary?,
            sourceFrameRefcon: frameReference.toOpaque(),
            infoFlagsOut: &flags
        )
        if status != noErr {
            frameReference.release()
            output(.failure(VideoEncoderError.encode(status)))
        }
        nextFrameID &+= 1
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func configure(_ session: VTCompressionSession) throws {
        try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, name: "RealTime", session: session)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse, name: "AllowFrameReordering", session: session)
        try set(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: preset.fps),
            name: "ExpectedFrameRate",
            session: session
        )
        try set(
            kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: preset.bitrate(for: codec)),
            name: "AverageBitRate",
            session: session
        )
        try set(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: preset.gopFrames),
            name: "MaxKeyFrameInterval",
            session: session
        )
        try set(
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 1.0),
            name: "MaxKeyFrameIntervalDuration",
            session: session
        )

        let bytesPerSecond = preset.bitrate(for: codec) / 8
        let limits: NSArray = [NSNumber(value: bytesPerSecond * 2), NSNumber(value: 1)]
        try set(kVTCompressionPropertyKey_DataRateLimits, value: limits, name: "DataRateLimits", session: session)

        switch codec {
        case .h264:
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        case .hevc:
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }

        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else { throw VideoEncoderError.encode(status) }
    }

    private func set(
        _ key: CFString,
        value: CFTypeRef,
        name: String,
        session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw VideoEncoderError.property(name, status) }
    }

    fileprivate func consume(sampleBuffer: CMSampleBuffer, frameID: UInt64) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            output(.failure(VideoEncoderError.emptyEncodedFrame))
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else {
            output(.failure(VideoEncoderError.emptyEncodedFrame))
            return
        }

        var payload = Data(count: length)
        let copyStatus = payload.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination.baseAddress!
            )
        }
        guard copyStatus == noErr else {
            output(.failure(VideoEncoderError.emptyEncodedFrame))
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let first = firstPTS ?? pts
        let relative = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, first)))
        let isKeyframe = !isNonSync(sampleBuffer)
        let initData = codecConfiguration(from: CMSampleBufferGetFormatDescription(sampleBuffer))

        let accessUnit = EncodedAccessUnit(
            frameID: frameID,
            payload: payload,
            presentationTimeUs: UInt64(relative * 1_000_000),
            isKeyframe: isKeyframe,
            initializationData: initData
        )
        output(.success(accessUnit))
    }

    private func isNonSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return false
        }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }

    private func codecConfiguration(from formatDescription: CMFormatDescription?) -> Data? {
        guard let formatDescription else { return nil }
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
              let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] else {
            return nil
        }
        let key = codec == .h264 ? "avcC" : "hvcC"
        return atoms[key] as? Data
    }
}

private func videoCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    guard let sourceFrameRefCon else {
        encoder.output(.failure(VideoEncoderError.emptyEncodedFrame))
        return
    }
    let frameReference = Unmanaged<EncoderFrameReference>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
    guard status == noErr else {
        encoder.output(.failure(VideoEncoderError.encode(status)))
        return
    }
    guard let sampleBuffer else {
        encoder.output(.failure(VideoEncoderError.emptyEncodedFrame))
        return
    }
    encoder.consume(sampleBuffer: sampleBuffer, frameID: frameReference.frameID)
}
