// Standalone regression runner compatible with macOS Command Line Tools.
struct TestFailure: Error { let message: String }
func checkEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
    guard actual == expected else { throw TestFailure(message: "Expected \(expected), got \(actual)") }
}
func checkTrue(_ value: Bool, _ message: String = "") throws {
    guard value else { throw TestFailure(message: "Expected true: \(message)") }
}
func checkFalse(_ value: Bool, _ message: String = "") throws { try checkTrue(!value, message) }
func checkNil(_ value: Any?) throws { try checkTrue(value == nil, "Expected nil") }
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestFailure(message: "Unexpected nil") }; return value
}
func checkThrows<T>(_ operation: @autoclosure () throws -> T) throws {
    do { _ = try operation() } catch { return }
    throw TestFailure(message: "Expected an error")
}
import Foundation
import BridgeCore

final class BridgeCoreTests {
    func testUsesEnabledActualPortAndIgnoresDisabledProxy() throws {
        let text = "HTTPEnable : 0\nHTTPProxy : 127.0.0.1\nHTTPPort : 7890\nSOCKSEnable : 1\nSOCKSProxy : 127.0.0.1\nSOCKSPort : 53281"
        try checkEqual(try parseProxyPort(text), 53281)
    }
    func testRejectsRemoteProxyAndInvalidPort() throws {
        try checkThrows(try parseProxyPort("HTTPEnable : 1\nHTTPProxy : proxy.example.com\nHTTPPort : 8080"))
        try checkThrows(try parseProxyPort("HTTPEnable : 1\nHTTPProxy : 127.0.0.1\nHTTPPort : 65536"))
        try checkThrows(try parseProxyPort("HTTPEnable : 1\nHTTPProxy : 127.0.0.1\nHTTPPort : 0"))
    }
    func testRequiresClashListenerOwner() throws {
        try checkEqual(try parseOwner("p41\ncOtherServer\np52\ncClashX\n"), 52)
        try checkThrows(try parseOwner("p41\ncOtherServer\n"))
    }
    func testNeverRoutesLocalReservedOrDocumentationAddresses() throws {
        for ip in ["127.0.0.1", "10.2.3.4", "172.31.255.255", "192.168.1.1", "169.254.1.1", "100.64.0.1", "198.18.0.1", "192.0.2.1", "203.0.113.1", "224.0.0.1", "::1", "fe80::1", "fd00::1", "2001:db8::1", "::ffff:127.0.0.1", "garbage"] {
            try checkFalse(isPublicIP(ip), ip)
        }
        for ip in ["1.1.1.1", "185.45.7.185", "172.32.0.1", "2606:4700::1111"] { try checkTrue(isPublicIP(ip), ip) }
    }
    func testScopedRoutesAndClashPortWithoutDNSChangesOrTLSInterception() throws {
        let value = try makeCoreConfig(proxy: Proxy(port: 52345, ownerPID: 55), targets: [defaultTarget], ips: ["1.1.1.1", "2606:4700::1111"], controllerPort: 49199, secret: "test")
        let tun = try unwrap(value["tun"] as? [String: Any])
        try checkEqual(tun["route-address"] as? [String], ["1.1.1.1/32", "2606:4700::1111/128"])
        try checkEqual(tun["dns-hijack"] as? [String], [])
        try checkEqual((value["dns"] as? [String: Any])?["enable"] as? Bool, false)
        try checkEqual((value["proxies"] as? [[String: Any]])?.first?["port"] as? Int, 52345)
        try checkEqual(value["rules"] as? [String], ["DOMAIN,\(defaultTarget),Existing-Clash", "MATCH,DIRECT"])
        try checkNil(value["tls"])
        let serialized = String(decoding: try jsonData(value), as: UTF8.self)
        try checkFalse(serialized.contains("\\/"), "Mihomo YAML rejects escaped JSON slashes")
    }
    func testRejectsBroadOrEmptyRoutes() throws {
        try checkThrows(try makeCoreConfig(proxy: Proxy(port: 1234, ownerPID: 1), targets: [defaultTarget], ips: [], controllerPort: 1235, secret: "test"))
        try checkThrows(try makeCoreConfig(proxy: Proxy(port: 1234, ownerPID: 1), targets: [defaultTarget], ips: ["0.0.0.0"], controllerPort: 1235, secret: "test"))
    }
    func testRuntimeJSONCredentialsArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json").path
        try writeJSON(["secret": "test-only"], path: file)
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        try checkEqual(mode?.intValue, 0o600)
    }
}

let suite = BridgeCoreTests()
let cases: [(String, () throws -> Void)] = [
    ("Discover actual enabled port", suite.testUsesEnabledActualPortAndIgnoresDisabledProxy),
    ("Reject invalid/nonlocal proxies", suite.testRejectsRemoteProxyAndInvalidPort),
    ("Verify Clash listener ownership", suite.testRequiresClashListenerOwner),
    ("Exclude reserved IP addresses", suite.testNeverRoutesLocalReservedOrDocumentationAddresses),
    ("Scope routes and preserve TLS/DNS", suite.testScopedRoutesAndClashPortWithoutDNSChangesOrTLSInterception),
    ("Reject broad or empty routes", suite.testRejectsBroadOrEmptyRoutes),
    ("Protect runtime credentials", suite.testRuntimeJSONCredentialsArePrivate),
]
var failures = 0
for (name, test) in cases {
    do { try test(); print("PASS: \(name)") }
    catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
}
print("\(cases.count - failures)/\(cases.count) tests passed")
exit(failures == 0 ? 0 : 1)
