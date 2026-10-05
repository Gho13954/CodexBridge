import Foundation
import Darwin

public struct ServiceOptions: Codable {
    public var targets: [String]
    public var corePath: String
    public var coreSHA256: String
    public var userHome: String
    public init(targets: [String] = [defaultTarget], corePath: String = installRoot + "/mihomo", coreSHA256: String, userHome: String) {
        self.targets = targets; self.corePath = corePath; self.coreSHA256 = coreSHA256; self.userHome = userHome
    }
}

public func runService(options: ServiceOptions) throws {
    guard geteuid() == 0 else { throw BridgeError("TUN requires root. Use scripts/install.sh to install the LaunchDaemon.") }
    guard !options.targets.isEmpty, options.targets.count <= 8, options.coreSHA256.count == 64 else { throw BridgeError("Invalid service configuration.") }
    guard try fileSHA256(options.corePath) == options.coreSHA256 else { throw BridgeError("Mihomo binary checksum mismatch.") }
    umask(0o077)
    let manager = FileManager.default
    try manager.createDirectory(atPath: runtimeRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let logDirectory = installRoot + "/logs"
    try manager.createDirectory(atPath: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let log = Log(path: logDirectory + "/bridge.log")
    let stop = StopFlag()
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let signals = [SIGTERM, SIGINT].map { value -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
        source.setEventHandler { stop.stop() }
        source.resume(); return source
    }
    defer { signals.forEach { $0.cancel() } }
    let publicStatus = installRoot + "/status.json"
    func status(_ state: String, proxy: Proxy? = nil, extra: [String: Any] = [:]) {
        var value: [String: Any] = ["service": serviceLabel, "state": state, "updated_at": ISO8601DateFormatter().string(from: Date()), "pid": getpid(), "targets": options.targets]
        if let proxy = proxy { value["clash_port"] = proxy.port; value["clash_pid"] = proxy.ownerPID }
        value.merge(extra) { _, new in new }
        do { try writeJSON(value, path: publicStatus, permissions: 0o644) } catch { log.write("status write failed: \(error.localizedDescription)") }
    }
    defer { status("stopped") }
    status("starting")
    log.write("service started; waiting for an existing Clash proxy")
    var lastError = ""
    while !stop.stopped {
        do {
            let proxy = try discoverProxy()
            var ips = Set<String>()
            for target in options.targets { ips.formUnion(try resolve(target)) }
            let controllerPort = try unusedPort()
            let secret = UUID().uuidString + UUID().uuidString
            var coreConfig = try makeCoreConfig(proxy: proxy, targets: options.targets, ips: ips, controllerPort: controllerPort, secret: secret)
            let configPath = runtimeRoot + "/config.json"
            try writeJSON(coreConfig, path: configPath)
            _ = try command(options.corePath, ["-t", "-d", runtimeRoot, "-f", configPath])
            let child = Process()
            child.executableURL = URL(fileURLWithPath: options.corePath)
            child.arguments = ["-d", runtimeRoot, "-f", configPath]
            let pipe = Pipe()
            child.standardOutput = pipe; child.standardError = pipe
            child.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                // Do not log controller credentials even if a dependency echoes them.
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    log.write("core " + String(line).replacingOccurrences(of: secret, with: "<redacted>"))
                }
            }
            try child.run()
            defer {
                if child.isRunning {
                    child.terminate()
                    for _ in 0..<40 { if !child.isRunning { break }; Thread.sleep(forTimeInterval: 0.2) }
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
                child.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                try? manager.removeItem(atPath: configPath)
                log.write("core stopped; its temporary TUN routes have been released")
            }
            let controller = Controller(port: controllerPort, secret: secret)
            var ready = false
            var device = ""
            for _ in 0..<30 {
                if stop.stopped || !child.isRunning { break }
                if let value = try? controller.request(), let tun = value["tun"] as? [String: Any], tun["enable"] as? Bool == true,
                   let name = tun["device"] as? String, name.hasPrefix("utun"), name != "utun",
                   (try? command("/sbin/ifconfig", [name])) != nil { ready = true; device = name; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard ready else { throw BridgeError("Mihomo did not create a working TUN interface.") }
            lastError = ""
            log.write("TUN ready: \(device); forwarding selected domain(s) through Clash port \(proxy.port)")
            var refreshAt = Date()
            while !stop.stopped && child.isRunning {
                let currentProxy = try discoverProxy()
                guard currentProxy == proxy else { throw BridgeError("Clash process/port changed; rebuilding TUN bridge.") }
                let live = try controller.request()
                guard (live["tun"] as? [String: Any])?["enable"] as? Bool == true else { throw BridgeError("TUN disabled unexpectedly.") }
                let connections = try controller.request("/connections")["connections"] as? [[String: Any]] ?? []
                let targetConnections = connections.filter {
                    let metadata = $0["metadata"] as? [String: Any] ?? [:]
                    return metadata["type"] as? String == "Tun" && options.targets.contains(metadata["host"] as? String ?? "")
                }
                let cloud = cloudState(logRoot: options.userHome + "/Library/Logs/com.openai.codex")
                status("active", proxy: proxy, extra: ["tun_device": device, "route_count": ips.count, "cloud_state": cloud, "target_connections": targetConnections.count])
                // Avoid rebuilding a live WebSocket's TUN interface just because DNS changed.
                // Once disconnected, retain old addresses and add freshly resolved addresses.
                if targetConnections.isEmpty && Date().timeIntervalSince(refreshAt) >= 10 {
                    var fresh = Set<String>()
                    for target in options.targets { if let resolved = try? resolve(target) { fresh.formUnion(resolved) } }
                    let added = fresh.subtracting(ips)
                    if !added.isEmpty {
                        guard ips.count + added.count <= 64 else { throw BridgeError("Route limit reached; rebuilding from current DNS.") }
                        ips.formUnion(added)
                        coreConfig = try makeCoreConfig(proxy: proxy, targets: options.targets, ips: ips, controllerPort: controllerPort, secret: secret)
                        _ = try controller.request(method: "PATCH", payload: ["tun": coreConfig["tun"]!])
                        let activeTun = try controller.request()["tun"] as? [String: Any] ?? [:]
                        let expected = (coreConfig["tun"] as! [String: Any])["route-address"] as! [String]
                        guard Set(activeTun["route-address"] as? [String] ?? []) == Set(expected) else { throw BridgeError("Runtime TUN routes did not update.") }
                        try writeJSON(coreConfig, path: configPath)
                        log.write("updated destination routes (\(ips.count) addresses)")
                    }
                    refreshAt = Date()
                }
                stop.sleep(5)
            }
            if !stop.stopped { throw BridgeError("Mihomo exited; restarting after backoff.") }
        } catch {
            let errorText = error.localizedDescription
            if errorText != lastError { log.write(errorText); lastError = errorText }
            status("waiting", extra: ["reason": errorText])
            stop.sleep(5)
        }
    }
    log.write("service stopping")
}
