import Foundation
import BridgeCore

func usage() {
    print("""
    codexbridge
      doctor                      Check current Clash proxy and scoped destination DNS
      proxy-url                   Print the detected HTTP/mixed proxy URL
      status                      Read the installed service status (no sudo required)
      config <sha256> <user-home>  Generate installation configuration
      run <config.json>           Run the root service under launchd
      test-config <path>          Generate a TUN-disabled local integration-test config
    """)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let action = arguments.first else { usage(); exit(0) }
    switch action {
    case "proxy-url": print(try discoverProxy().url)
    case "doctor":
        let proxy = try discoverProxy()
        let ips = try resolve(defaultTarget)
        print(String(decoding: try jsonData(["proxy": proxy.url, "clash_pid": proxy.ownerPID, "socks5": true, "target": defaultTarget, "target_addresses": ips.sorted()]), as: UTF8.self))
    case "status":
        let path = installRoot + "/status.json"
        guard FileManager.default.fileExists(atPath: path) else { throw BridgeError("Service not installed/running. Run scripts/install.sh first.") }
        print(String(decoding: try jsonData(readJSON(path)), as: UTF8.self))
    case "config":
        guard arguments.count == 3 else { throw BridgeError("Expected core SHA256 and user home.") }
        let value = ServiceOptions(coreSHA256: arguments[1], userHome: arguments[2])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    case "run":
        guard arguments.count == 2 else { throw BridgeError("Expected service config path.") }
        let config = try JSONDecoder().decode(ServiceOptions.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        try runService(options: config)
    case "test-config":
        guard arguments.count == 2 else { throw BridgeError("Expected output path.") }
        let proxy = try discoverProxy()
        let mixed = try unusedPort()
        let ips = try resolve(defaultTarget)
        let config = try makeCoreConfig(proxy: proxy, targets: [defaultTarget], ips: ips, controllerPort: unusedPort(), secret: UUID().uuidString, tun: false, mixedPort: mixed)
        try writeJSON(config, path: arguments[1])
        print("Test mixed port: \(mixed)")
        if let ipv4 = ips.sorted().first(where: { !$0.contains(":") }) { print("Test IPv4 address: \(ipv4)") }
    default: usage(); throw BridgeError("Unknown command: \(action)")
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
