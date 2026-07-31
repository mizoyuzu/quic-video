import CoreVideo
import VideoToolbox

enum PixelBufferScalerError: LocalizedError {
    case sessionCreation(OSStatus)
    case poolCreation(OSStatus)
    case allocation(OSStatus)
    case transfer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreation(let status): return "Pixel transfer session creation failed: \(status)"
        case .poolCreation(let status): return "Pixel buffer pool creation failed: \(status)"
        case .allocation(let status): return "Pixel buffer allocation failed: \(status)"
        case .transfer(let status): return "Pixel buffer transfer failed: \(status)"
        }
    }
}

final class PixelBufferScaler {
    private let width: Int
    private let height: Int
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height

        var session: VTPixelTransferSession?
        let sessionStatus = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            throw PixelBufferScalerError.sessionCreation(sessionStatus)
        }
        transfer = session

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var createdPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &createdPool
        )
        guard poolStatus == kCVReturnSuccess, let createdPool else {
            throw PixelBufferScalerError.poolCreation(poolStatus)
        }
        pool = createdPool
        _ = VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_CropSourceToCleanAperture
        )
    }

    func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        if CVPixelBufferGetWidth(source) == width && CVPixelBufferGetHeight(source) == height {
            return source
        }
        guard let pool, let transfer else { throw PixelBufferScalerError.allocation(kCVReturnError) }
        var destination: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard allocationStatus == kCVReturnSuccess, let destination else {
            throw PixelBufferScalerError.allocation(allocationStatus)
        }
        let transferStatus = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
        guard transferStatus == noErr else { throw PixelBufferScalerError.transfer(transferStatus) }
        return destination
    }
}
