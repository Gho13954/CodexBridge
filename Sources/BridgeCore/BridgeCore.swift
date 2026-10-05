import Foundation
import CryptoKit
import Darwin

public let serviceLabel = "io.github.codexbridge"
public let installRoot = "/Library/Application Support/CodexBridge"
public let runtimeRoot = "/var/run/codexbridge"
public let defaultTarget = "codex-cloud-backend.chatgpt.com"

public struct BridgeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@discardableResult public func command(_ path: String, _ arguments: [String], input: Data? = nil) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let output = Pipe()
    task.standardOutput = output
    task.standardError = output
    let stdin = Pipe()
    task.standardInput = stdin
    try task.run()
    if let input = input { try stdin.fileHandleForWriting.write(contentsOf: input) }
    try stdin.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard task.terminationStatus == 0 else { throw BridgeError("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
    return text
}

public struct Proxy: Equatable {
    public let port: Int
    public let ownerPID: Int
    public var url: String { "http://127.0.0.1:\(port)" }
    public init(port: Int, ownerPID: Int) { self.port = port; self.ownerPID = ownerPID }
}

public func parseProxyPort(_ text: String) throws -> Int {
    var values = [String: String]()
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { values[parts[0]] = parts[1] }
    }
    for kind in ["HTTP", "HTTPS", "SOCKS"] {
        guard values[kind + "Enable"] == "1" else { continue }
        guard ["127.0.0.1", "localhost"].contains(values[kind + "Proxy"] ?? "") else { continue }
        if let raw = values[kind + "Port"], let port = Int(raw), (1...65535).contains(port) { return port }
    }
    throw BridgeError("No enabled loopback system proxy; waiting for Clash.")
}

public func parseOwner(_ text: String) throws -> Int {
    var pid = 0
    for line in text.split(separator: "\n") {
        if line.first == "p" { pid = Int(line.dropFirst()) ?? 0 }
        if line.first == "c" && pid > 0 {
            let name = line.dropFirst().lowercased()
            if name.contains("clash") || name.contains("mihomo") { return pid }
        }
    }
    throw BridgeError("System proxy listener is not a Clash/mihomo process.")
}

public func probeSOCKS5(_ port: Int) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeError("Cannot create proxy probe socket.") }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { throw BridgeError("Clash proxy is not reachable.") }
    let greeting: [UInt8] = [5, 1, 0]
    guard greeting.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress!, 3, 0) }) == 3 else { throw BridgeError("SOCKS5 greeting failed.") }
    var reply = [UInt8](repeating: 0, count: 2)
    var received = 0
    while received < 2 {
        let count = reply.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: received), 2 - received, 0) }
        guard count > 0 else { throw BridgeError("SOCKS5 greeting timed out or was rejected.") }
        received += count
    }
    guard reply == [5, 0] else { throw BridgeError("This bridge requires a mixed/SOCKS5 proxy without authentication.") }
}

public func discoverProxy() throws -> Proxy {
    let port = try parseProxyPort(command("/usr/sbin/scutil", ["--proxy"]))
    let pid = try parseOwner(command("/usr/sbin/lsof", ["-nP", "-Fpc", "-iTCP:\(port)", "-sTCP:LISTEN"]))
    try probeSOCKS5(port)
    return Proxy(port: port, ownerPID: pid)
}

public func isPublicIP(_ ip: String) -> Bool {
    var v4 = in_addr()
    if inet_pton(AF_INET, ip, &v4) == 1 {
        let n = UInt32(bigEndian: v4.s_addr)
        let reserved: [(UInt32, Int)] = [
            (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10), (0x7f000000, 8),
            (0xa9fe0000, 16), (0xac100000, 12), (0xc0000000, 24), (0xc0000200, 24),
            (0xc0a80000, 16), (0xc6120000, 15), (0xc6336400, 24), (0xcb007100, 24), (0xe0000000, 3),
        ]
        return !reserved.contains { base, prefix in (n & (UInt32.max << (32 - prefix))) == base }
    }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }
    let bytes = withUnsafeBytes(of: v6) { Array($0) }
    // Only global unicast, excluding documentation addresses. No loopback/link-local/mapped IPv4 routes.
    return bytes[0] & 0xe0 == 0x20 && !(bytes[0...3] == [0x20, 0x01, 0x0d, 0xb8])
}

public func resolve(_ host: String) throws -> Set<String> {
    guard host.range(of: "^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$", options: .regularExpression) != nil else { throw BridgeError("Invalid target hostname.") }
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, "443", &hints, &result)
    guard status == 0, let head = result else { throw BridgeError("DNS lookup failed for \(host).") }
    defer { freeaddrinfo(head) }
    var cursor: UnsafeMutablePointer<addrinfo>? = head
    var ips = Set<String>()
    while let pointer = cursor {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(pointer.pointee.ai_addr, pointer.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            ips.insert(String(cString: buffer))
        }
        cursor = pointer.pointee.ai_next
    }
    guard !ips.isEmpty, ips.allSatisfy(isPublicIP) else { throw BridgeError("DNS returned empty/non-public addresses; refusing routes.") }
    return ips
}

public func unusedPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeError("Cannot reserve controller port.") }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw BridgeError("Cannot bind controller port.") }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let checked = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard checked == 0 else { throw BridgeError("Cannot inspect controller port.") }
    return Int(UInt16(bigEndian: address.sin_port))
}

public func makeCoreConfig(proxy: Proxy, targets: [String], ips: Set<String>, controllerPort: Int, secret: String, tun: Bool = true, mixedPort: Int = 0) throws -> [String: Any] {
    guard !ips.isEmpty, ips.allSatisfy(isPublicIP) else { throw BridgeError("Refusing an empty or non-public route set.") }
    return [
        "mixed-port": mixedPort, "allow-lan": false, "bind-address": "127.0.0.1", "mode": "rule", "ipv6": true, "log-level": "info",
        "external-controller": "127.0.0.1:\(controllerPort)", "secret": secret,
        "tun": ["enable": tun, "stack": "gvisor", "auto-route": true, "auto-detect-interface": true,
                "route-address": ips.sorted().map { $0 + ($0.contains(":") ? "/128" : "/32") },
                "inet6-address": ["fdfe:dcba:9877::1/126"], "dns-hijack": [String](), "mtu": 1500],
        "dns": ["enable": false],
        "sniffer": ["enable": true, "parse-pure-ip": true, "force-dns-mapping": true, "override-destination": true,
                    "sniff": ["TLS": ["ports": [443], "override-destination": true]]],
        "proxies": [["name": "Existing-Clash", "type": "socks5", "server": "127.0.0.1", "port": proxy.port, "udp": false]],
        "rules": targets.map { "DOMAIN,\($0),Existing-Clash" } + ["MATCH,DIRECT"],
    ]
}

// Mihomo reads configuration as YAML: JSON's optional \/ escape is not valid YAML.
public func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
public func readJSON(_ path: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw BridgeError("Expected JSON object: \(path)") }
    return object
}
public func writeJSON(_ object: Any, path: String, permissions: Int = 0o600) throws {
    try jsonData(object).write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
}
public func fileSHA256(_ path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
}

private final class ResponseBox {
    let lock = NSLock()
    var data: Data?
    var error: Error?
    var status: Int?
}

public final class Controller {
    private let session: URLSession
    private let port: Int
    private let secret: String
    public init(port: Int, secret: String) {
        self.port = port; self.secret = secret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": false, "HTTPSEnable": false, "SOCKSEnable": false]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    public func request(_ path: String = "/configs", method: String = "GET", payload: Any? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let payload = payload { request.httpBody = try jsonData(payload); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.lock.lock(); box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode; box.error = error; box.lock.unlock()
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 6) == .success else { task.cancel(); throw BridgeError("Controller timeout.") }
        box.lock.lock(); defer { box.lock.unlock() }
        if let error = box.error { throw error }
        guard let status = box.status, (200..<300).contains(status) else { throw BridgeError("Controller request failed (\(box.status ?? 0)).") }
        guard let data = box.data, !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

public final class StopFlag {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func stop() { lock.lock(); value = true; lock.unlock() }
    public func sleep(_ seconds: Int) { for _ in 0..<seconds { if stopped { break }; Thread.sleep(forTimeInterval: 1) } }
}

public final class Log {
    private let path: String
    private let lock = NSLock()
    public init(path: String) { self.path = path }
    public func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: path)[.size]) as? NSNumber, size.intValue > 2_000_000 {
                for index in (1...2).reversed() {
                    let destination = path + ".\(index + 1)"
                    try? manager.removeItem(atPath: destination)
                    try? manager.moveItem(atPath: path + ".\(index)", toPath: destination)
                }
                try? manager.removeItem(atPath: path + ".1")
                try manager.moveItem(atPath: path, toPath: path + ".1")
            }
            if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let stream = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try stream.seekToEnd()
            let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
            try stream.write(contentsOf: Data(line.utf8)); try stream.close()
        } catch { fputs("bridge logging failed\n", stderr) }
    }
}

public func cloudState(logRoot: String) -> String {
    let manager = FileManager.default
    guard let iterator = manager.enumerator(at: URL(fileURLWithPath: logRoot), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return "unknown" }
    let files = iterator.compactMap { $0 as? URL }.filter { $0.path.contains("-t0-") && $0.pathExtension == "log" }.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
    }
    for url in files.prefix(2) {
        guard let stream = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? stream.close() }
        guard let length = try? stream.seekToEnd() else { continue }
        try? stream.seek(toOffset: length > 250_000 ? length - 250_000 : 0)
        let text = String(decoding: (try? stream.readToEnd()) ?? Data(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("app_server_connection.state_changed") && line.contains("hostId=durable") {
            for state in ["connected", "connecting", "disconnected", "error"] {
                if line.contains("next=\(state) ") { return state }
            }
        }
    }
    return "unknown"
}
