import Foundation

struct Options {
    var name = Host.current().localizedName ?? "Mac relay"
    var port = 4443
    var fingerprint = ""
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--name":
            options.name = arguments.next() ?? options.name
        case "--port":
            options.port = Int(arguments.next() ?? "4443") ?? 4443
        case "--fingerprint":
            options.fingerprint = arguments.next() ?? ""
        case "--help":
            print("Usage: quic-video-bonjour [--name NAME] [--port PORT] [--fingerprint SHA256]")
            exit(0)
        default:
            fputs("Unknown option: \(argument)\n", stderr)
            exit(2)
        }
    }
    return options
}

let options = parseOptions()
let service = NetService(
    domain: "local.",
    type: "_quic-video._udp.",
    name: options.name,
    port: Int32(options.port)
)
let txt = NetService.data(fromTXTRecord: [
    "fingerprint": Data(options.fingerprint.utf8),
    "version": Data("1".utf8),
])
service.setTXTRecord(txt)
service.includesPeerToPeer = true
service.publish(options: [.listenForConnections])
print("Advertising \(options.name) on _quic-video._udp port \(options.port)")
RunLoop.current.run()
