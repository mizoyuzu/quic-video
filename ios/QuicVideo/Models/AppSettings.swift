import Foundation
import UIKit

struct AppSettings: Codable, Equatable {
    var host = ""
    var port = 4443
    var certificateFingerprint = ""
    var disableTLSVerification = false
    var preset: StreamPreset = .hd30
    var codec: StreamCodec = .h264
    var diagnosticLogging = false
    var broadcastPath = ""

    var relayURL: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "https://\(host):\(port)"
    }
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "quic-video.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            var settings = AppSettings()
            settings.broadcastPath = DeviceIdentity.shared.broadcastPath
            return settings
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

final class DeviceIdentity {
    static let shared = DeviceIdentity()

    private let defaults = UserDefaults.standard
    private let idKey = "quic-video.device-id"

    private init() {}

    var broadcastPath: String {
        let name = UIDevice.current.name
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^A-Za-z0-9-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeName = name.isEmpty ? "iphone" : name.lowercased()
        let deviceID: String
        if let existing = defaults.string(forKey: idKey) {
            deviceID = existing
        } else {
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            deviceID = String(generated.prefix(8))
            defaults.set(deviceID, forKey: idKey)
        }
        return "quic-video/\(safeName)-\(deviceID)"
    }
}
