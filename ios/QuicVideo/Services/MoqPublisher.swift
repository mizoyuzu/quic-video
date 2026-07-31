import Foundation
import Moq

struct PublisherStats: Sendable {
    let rttUs: UInt64?
    let sendRateBps: UInt64?
    let bytesSent: UInt64?
    let bytesLost: UInt64?
    let packetsLost: UInt64?
    let queueDepth: Int
}

enum MoqPublisherError: LocalizedError {
    case missingRelayURL
    case missingCodecConfiguration
    case notStarted
    case noMediaTrack

    var errorDescription: String? {
        switch self {
        case .missingRelayURL: return "Relay host is not configured"
        case .missingCodecConfiguration: return "The first keyframe did not include codec configuration"
        case .notStarted: return "MoQ publisher is not started"
        case .noMediaTrack: return "MoQ media track is not ready"
        }
    }
}

final class MoqPublisher: @unchecked Sendable {
    private let settings: AppSettings
    private let preset: StreamPreset
    private let codec: StreamCodec
    private let logger: SessionLogger
    private let stateQueue = DispatchQueue(label: "net.nasno.quic-video.publisher.state")
    private let writeQueue = DispatchQueue(label: "net.nasno.quic-video.publisher.write", qos: .userInitiated)
    private let maxPendingFrames: Int

    private var client: Client?
    private var session: Session?
    private var broadcast: BroadcastProducer?
    private var media: MediaProducer?
    private var pendingFrames = 0
    private var discardUntilKeyframe = false
    private var stopped = false

    init(settings: AppSettings, preset: StreamPreset, codec: StreamCodec, logger: SessionLogger) {
        self.settings = settings
        self.preset = preset
        self.codec = codec
        self.logger = logger
        maxPendingFrames = max(2, preset.fps / 2)
    }

    func connect() async throws {
        guard let relayURL = settings.relayURL else {
            throw MoqPublisherError.missingRelayURL
        }

        let client = Client()
        if settings.disableTLSVerification {
            client.setTlsVerify(false)
        } else if !settings.certificateFingerprint.isEmpty {
            client.setTlsFingerprints([settings.certificateFingerprint])
        }
        let session = try await client.connect(to: relayURL)
        let path = settings.broadcastPath.isEmpty ? DeviceIdentity.shared.broadcastPath : settings.broadcastPath
        let broadcast = try session.publisher.createBroadcast(path: path)

        self.client = client
        self.session = session
        self.broadcast = broadcast
        stopped = false

        if let sessionID = await logger.sessionID {
            await logger.record(LogRecord(
                sessionID: sessionID,
                event: "moq_connected",
                attributes: ["url": redactedURL(relayURL), "broadcast": path]
            ))
        }
    }

    func submit(_ accessUnit: EncodedAccessUnit) {
        let accepted = stateQueue.sync { () -> Bool in
            guard !stopped else { return false }
            if pendingFrames >= maxPendingFrames {
                discardUntilKeyframe = true
                return false
            }
            pendingFrames += 1
            return true
        }
        guard accepted else {
            Task {
                if let sessionID = await logger.sessionID {
                    await logger.record(LogRecord(
                        sessionID: sessionID,
                        event: "publish_drop",
                        frameID: accessUnit.frameID,
                        mediaPTSUs: accessUnit.presentationTimeUs,
                        payloadBytes: accessUnit.payload.count,
                        dropReason: "publisher_queue_full",
                        attributes: ["policy": "discard_until_keyframe"]
                    ))
                }
            }
            return
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateQueue.sync {
                    self.pendingFrames = max(0, self.pendingFrames - 1)
                }
            }
            self.write(accessUnit)
        }
    }

    func stats() -> PublisherStats {
        let native = session?.stats()
        let depth = stateQueue.sync { pendingFrames }
        return PublisherStats(
            rttUs: native?.rttUs,
            sendRateBps: native?.sendRateBps,
            bytesSent: native?.bytesSent,
            bytesLost: native?.bytesLost,
            packetsLost: native?.packetsLost,
            queueDepth: depth
        )
    }

    func stop() {
        stateQueue.sync { stopped = true }
        writeQueue.sync {}
        if let media { try? media.finish() }
        if let broadcast { try? broadcast.finish() }
        session?.shutdown()
        session = nil
        broadcast = nil
        media = nil
        client = nil
    }

    private func write(_ accessUnit: EncodedAccessUnit) {
        let shouldDiscard = stateQueue.sync { () -> Bool in
            guard discardUntilKeyframe else { return false }
            if accessUnit.isKeyframe {
                discardUntilKeyframe = false
                return false
            }
            return true
        }
        if shouldDiscard {
            Task {
                if let sessionID = await logger.sessionID {
                    await logger.record(LogRecord(
                        sessionID: sessionID,
                        event: "publish_drop",
                        frameID: accessUnit.frameID,
                        mediaPTSUs: accessUnit.presentationTimeUs,
                        payloadBytes: accessUnit.payload.count,
                        dropReason: "until_keyframe"
                    ))
                }
            }
            return
        }

        do {
            if media == nil {
                guard let initData = accessUnit.initializationData else {
                    throw MoqPublisherError.missingCodecConfiguration
                }
                guard let broadcast else { throw MoqPublisherError.notStarted }
                let hint = VideoHint(
                    coded: Dimensions(width: UInt32(preset.width), height: UInt32(preset.height)),
                    displayAspect: Dimensions(width: 16, height: 9),
                    bitrate: UInt64(preset.bitrate(for: codec)),
                    framerate: Double(preset.fps),
                    optimizeForLatency: true
                )
                media = try broadcast.publishMedia(format: codec.mediaFormat, initData: initData, video: hint)
            }
            guard let media else { throw MoqPublisherError.noMediaTrack }
            try media.writeFrame(accessUnit.payload, timestampUs: accessUnit.presentationTimeUs)
            Task {
                if let sessionID = await logger.sessionID {
                    await logger.record(LogRecord(
                        sessionID: sessionID,
                        event: "moq_write",
                        frameID: accessUnit.frameID,
                        mediaPTSUs: accessUnit.presentationTimeUs,
                        codec: codec.rawValue,
                        width: preset.width,
                        height: preset.height,
                        fps: preset.fps,
                        payloadBytes: accessUnit.payload.count,
                        queueDepth: stateQueue.sync { pendingFrames }
                    ))
                }
            }
        } catch {
            Task {
                if let sessionID = await logger.sessionID {
                    await logger.record(LogRecord(
                        sessionID: sessionID,
                        event: "moq_write_error",
                        frameID: accessUnit.frameID,
                        errorDomain: "MoqPublisher",
                        errorMessage: error.localizedDescription
                    ))
                }
            }
        }
    }

    private func redactedURL(_ url: String) -> String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              let host = components.host else { return "(invalid)" }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
