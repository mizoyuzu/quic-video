import AVFoundation
import Combine
import Foundation
import Network
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status = "停止中"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var wifiAvailable = false
    @Published private(set) var stats = PublisherStats(rttUs: nil, sendRateBps: nil, bytesSent: nil, bytesLost: nil, packetsLost: nil, queueDepth: 0)
    @Published private(set) var previewSession: AVCaptureSession?

    let discovery = RelayDiscovery()

    private let settingsStore = SettingsStore()
    private let logger = SessionLogger()
    private var publisher: MoqPublisher?
    private var encoder: VideoEncoder?
    private var capture: CameraCapture?
    private var statsTask: Task<Void, Never>?
    private var resumeAfterBackground = false
    private var observers: [NSObjectProtocol] = []
    private let networkMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let networkQueue = DispatchQueue(label: "net.nasno.quic-video.network")

    init() {
        settings = settingsStore.load()
        discovery.start()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.wifiAvailable = available }
        }
        networkMonitor.start(queue: networkQueue)
        observers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.handleBackground() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.handleForeground() }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        discovery.stop()
        networkMonitor.cancel()
    }

    var availableCodecs: [StreamCodec] {
        StreamCodec.allCases.filter { $0.hardwareSupported }
    }

    var availablePresets: [StreamPreset] {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return []
        }
        return StreamPreset.allCases.filter { $0.isSupported(by: camera) }
    }

    func select(relay: DiscoveredRelay) {
        settings.host = relay.host
        settings.port = relay.port
        settings.certificateFingerprint = relay.certificateFingerprint
        saveSettings()
    }

    func saveSettings() {
        settingsStore.save(settings)
    }

    func start() {
        guard !isRunning else { return }
        saveSettings()
        errorMessage = nil
        status = "準備中"
        Task { @MainActor [weak self] in
            await self?.startSession()
        }
    }

    func stop() {
        Task { @MainActor [weak self] in
            await self?.stopSession()
        }
    }

    private func startSession() async {
        do {
            guard await requestCameraPermission() else {
                throw AppModelError.cameraPermissionDenied
            }
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  settings.preset.isSupported(by: camera) else {
                throw AppModelError.presetUnavailable
            }
            guard settings.codec.hardwareSupported else {
                throw AppModelError.codecUnavailable
            }
            guard let _ = settings.relayURL else {
                throw AppModelError.relayMissing
            }
            guard wifiAvailable else {
                throw AppModelError.wifiUnavailable
            }

            _ = try await logger.start(diagnostic: settings.diagnosticLogging)
            let publisher = MoqPublisher(settings: settings, preset: settings.preset, codec: settings.codec, logger: logger)
            try await publisher.connect()

            let encoder = try VideoEncoder(preset: settings.preset, codec: settings.codec) { [weak publisher, weak self] result in
                switch result {
                case .success(let accessUnit):
                    publisher?.submit(accessUnit)
                case .failure(let error):
                    Task { @MainActor in
                        await self?.recordError(error)
                    }
                }
            }
            let capture = try CameraCapture(preset: settings.preset, encoder: encoder, logger: logger)

            self.publisher = publisher
            self.encoder = encoder
            self.capture = capture
            previewSession = capture.session
            isRunning = true
            status = "配信中"
            UIApplication.shared.isIdleTimerDisabled = true
            capture.start()
            startStatsLoop(publisher: publisher)
        } catch {
            await recordError(error)
            await cleanupAfterFailure()
        }
    }

    private func stopSession() async {
        guard isRunning || publisher != nil else { return }
        statsTask?.cancel()
        statsTask = nil
        capture?.stop()
        encoder?.stop()
        publisher?.stop()
        capture = nil
        encoder = nil
        publisher = nil
        previewSession = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = "停止中"
        await logger.close()
    }

    private func cleanupAfterFailure() async {
        capture?.stop()
        encoder?.stop()
        publisher?.stop()
        capture = nil
        encoder = nil
        publisher = nil
        previewSession = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        await logger.close()
    }

    private func startStatsLoop(publisher: MoqPublisher) {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self, weak publisher] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let publisher else { continue }
                let next = publisher.stats()
                self.stats = next
                if let sessionID = await self.logger.sessionID {
                    await self.logger.record(LogRecord(
                        sessionID: sessionID,
                        event: "stats",
                        rttUs: next.rttUs,
                        sendRateBps: next.sendRateBps,
                        bytesSent: next.bytesSent,
                        bytesLost: next.bytesLost,
                        packetsLost: next.packetsLost,
                        queueDepth: next.queueDepth
                    ))
                }
            }
        }
    }

    private func recordError(_ error: Error) async {
        errorMessage = error.localizedDescription
        status = "エラー"
        if let sessionID = await logger.sessionID {
            await logger.record(LogRecord(
                sessionID: sessionID,
                event: "error",
                errorDomain: String(describing: type(of: error)),
                errorMessage: error.localizedDescription
            ))
        }
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func handleBackground() async {
        resumeAfterBackground = isRunning
        if resumeAfterBackground { await stopSession() }
    }

    private func handleForeground() async {
        guard resumeAfterBackground else { return }
        resumeAfterBackground = false
        start()
    }
}

enum AppModelError: LocalizedError {
    case cameraPermissionDenied
    case presetUnavailable
    case codecUnavailable
    case relayMissing
    case wifiUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: return "カメラ権限が許可されていません"
        case .presetUnavailable: return "この端末では選択したプリセットを利用できません"
        case .codecUnavailable: return "この端末では選択したcodecのhardware encoderを利用できません"
        case .relayMissing: return "relayの接続先が未設定です"
        case .wifiUnavailable: return "Wi-Fi接続が確認できないため開始できません"
        }
    }
}
