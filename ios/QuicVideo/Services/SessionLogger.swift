import Foundation

struct LogRecord: Codable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let role: String
    let event: String
    let wallTime: String
    let monotonicUs: UInt64
    let frameID: UInt64?
    let mediaPTSUs: UInt64?
    let codec: String?
    let width: Int?
    let height: Int?
    let fps: Int?
    let payloadBytes: Int?
    let queueDepth: Int?
    let dropReason: String?
    let rttUs: UInt64?
    let sendRateBps: UInt64?
    let bytesSent: UInt64?
    let bytesLost: UInt64?
    let packetsLost: UInt64?
    let errorDomain: String?
    let errorCode: Int?
    let errorMessage: String?
    let attributes: [String: String]?

    init(
        sessionID: String,
        event: String,
        frameID: UInt64? = nil,
        mediaPTSUs: UInt64? = nil,
        codec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Int? = nil,
        payloadBytes: Int? = nil,
        queueDepth: Int? = nil,
        dropReason: String? = nil,
        rttUs: UInt64? = nil,
        sendRateBps: UInt64? = nil,
        bytesSent: UInt64? = nil,
        bytesLost: UInt64? = nil,
        packetsLost: UInt64? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        attributes: [String: String]? = nil
    ) {
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.role = "ios_publisher"
        self.event = event
        self.wallTime = ISO8601DateFormatter().string(from: Date())
        self.monotonicUs = MonotonicClock.nowMicroseconds()
        self.frameID = frameID
        self.mediaPTSUs = mediaPTSUs
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.payloadBytes = payloadBytes
        self.queueDepth = queueDepth
        self.dropReason = dropReason
        self.rttUs = rttUs
        self.sendRateBps = sendRateBps
        self.bytesSent = bytesSent
        self.bytesLost = bytesLost
        self.packetsLost = packetsLost
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.attributes = attributes
    }
}

actor SessionLogger {
    private(set) var sessionID: String?
    private(set) var fileURL: URL?
    private var fileHandle: FileHandle?
    private var diagnostic = false

    func start(diagnostic: Bool) throws -> URL {
        let id = UUID().uuidString.lowercased()
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("quic-video/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session-\(id).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
        sessionID = id
        fileURL = url
        self.diagnostic = diagnostic
        try writeRecord(LogRecord(sessionID: id, event: "session_start"))
        return url
    }

    func record(_ record: LogRecord) {
        guard fileHandle != nil else { return }
        if record.frameID != nil && !diagnostic { return }
        try? writeRecord(record)
    }

    func close() {
        if let id = sessionID {
            try? writeRecord(LogRecord(sessionID: id, event: "session_stop"))
        }
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func writeRecord(_ record: LogRecord) throws {
        guard let data = try? JSONEncoder().encode(record) else { return }
        guard let handle = fileHandle else { return }
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}
