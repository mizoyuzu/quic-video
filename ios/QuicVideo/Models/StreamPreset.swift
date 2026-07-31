import AVFoundation
import CoreMedia
import VideoToolbox

enum StreamCodec: String, CaseIterable, Codable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    var mediaFormat: String {
        switch self {
        case .h264: return "avc1"
        case .hevc: return "hvc1"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var hardwareSupported: Bool {
        VTIsHardwareEncodeSupported(codecType)
    }
}

enum StreamPreset: String, CaseIterable, Codable, Identifiable {
    case sd30 = "SD30"
    case sd60 = "SD60"
    case hd30 = "HD30"
    case hd60 = "HD60"
    case fhd30 = "FHD30"
    case fhd60 = "FHD60"

    var id: String { rawValue }

    var title: String {
        "\(rawValue) (\(width)x\(height) / \(fps)fps)"
    }

    var width: Int {
        switch self {
        case .sd30, .sd60: return 854
        case .hd30, .hd60: return 1280
        case .fhd30, .fhd60: return 1920
        }
    }

    var height: Int {
        switch self {
        case .sd30, .sd60: return 480
        case .hd30, .hd60: return 720
        case .fhd30, .fhd60: return 1080
        }
    }

    var fps: Int {
        switch self {
        case .sd30, .hd30, .fhd30: return 30
        case .sd60, .hd60, .fhd60: return 60
        }
    }

    var gopFrames: Int { fps }

    var h264Bitrate: Int {
        switch self {
        case .sd30: return 800_000
        case .sd60: return 1_200_000
        case .hd30: return 2_000_000
        case .hd60: return 4_000_000
        case .fhd30: return 5_000_000
        case .fhd60: return 8_000_000
        }
    }

    var hevcBitrate: Int { h264Bitrate * 6 / 10 }

    func bitrate(for codec: StreamCodec) -> Int {
        codec == .h264 ? h264Bitrate : hevcBitrate
    }

    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    func isSupported(by device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= Int32(width), dimensions.height >= Int32(height) else {
                return false
            }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(fps) && range.maxFrameRate >= Double(fps)
            }
        }
    }
}
