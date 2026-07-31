import Foundation
import Combine

struct DiscoveredRelay: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let certificateFingerprint: String
}

final class RelayDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var relays: [DiscoveredRelay] = []

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        relays = []
        services = [:]
        browser.searchForServices(ofType: "_quic-video._udp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.values.forEach { $0.stop() }
        services.removeAll()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name).\(service.type).\(service.domain)"
        services[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name).\(service.type).\(service.domain)"
        services.removeValue(forKey: key)
        relays.removeAll { $0.id == key }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        let txt = NetService.dictionary(fromTXTRecord: sender.txtRecordData() ?? Data())
        let fingerprint = txt["fingerprint"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let relay = DiscoveredRelay(
            id: "\(sender.name).\(sender.type).\(sender.domain)",
            name: sender.name,
            host: host,
            port: sender.port,
            certificateFingerprint: fingerprint
        )
        if let index = relays.firstIndex(where: { $0.id == relay.id }) {
            relays[index] = relay
        } else {
            relays.append(relay)
        }
        relays.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let key = "\(sender.name).\(sender.type).\(sender.domain)"
        services.removeValue(forKey: key)
    }
}
