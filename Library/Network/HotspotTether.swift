import Darwin
import Foundation
import Network
import os

// Hotspot sharing for the packet-tunnel extension (iOS).
//
// iOS gives no packet-level access to the Personal Hotspot interface (bridge100) and
// tethered traffic never enters the VPN utun. What the extension can do is accept TCP
// connections from hotspot clients and feed them into sing-box, so their traffic follows
// sing-box routing (i.e. leaves through the VPN outbound).
//
// Measured on device: SYNs to a listening socket created by the Go core are silently
// dropped (even over loopback when it is bound to the wildcard address), while a
// Network.framework listener in the same process accepts. So:
//   hotspot client --TCP--> NWListener *:port (Swift, "front")
//                    --relay--> sing-box `mixed` inbound 127.0.0.1:internalPort (Go)
//                    --> sing-box routing --> outbound
// Clients set an HTTP or SOCKS5 proxy to <hotspot ip, normally 172.20.10.1>:port.

public struct HotspotSettings: Equatable {
    public var enabled = false
    public var port = 7890
    public var verbose = false

    public static let inboundTag = "hotspot-in"

    public init() {}

    public init(options: [String: NSObject]?) {
        enabled = (options?["hotspotEnabled"] as? NSNumber)?.boolValue ?? false
        if let p = (options?["hotspotPort"] as? NSNumber)?.intValue, (1 ... 65535).contains(p) {
            port = p
        }
        verbose = (options?["hotspotVerbose"] as? NSNumber)?.boolValue ?? false
    }

    /// Loopback port of the VPN extension's sing-box mixed inbound.
    public var internalPort: Int {
        port <= 55000 ? port + 10000 : port - 10000
    }

    /// Loopback port of the in-app sing-box core's mixed inbound (proxy mode, no VPN).
    public var appCorePort: Int {
        internalPort + 3
    }
}

/// Written by the extension to the shared container; shown by the app's Hotspot page.
public struct HotspotStatus: Codable {
    public var updated: Date
    public var listening: Bool
    public var listenerState: String
    public var port: Int
    public var hotspotAddress: String?
    public var activeConnections: Int
    public var totalConnections: Int
    public var rejectedConnections: Int
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var lastSelfTest: String?

    public static var fileURL: URL {
        FilePath.sharedDirectory.appendingPathComponent("hotspot-status.json")
    }

    public static func read() -> HotspotStatus? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HotspotStatus.self, from: data)
    }
}

// MARK: - Logging

public final class HotspotLog {
    public static let shared = HotspotLog()
    private let logger = Logger(category: "Hotspot")
    private let queue = DispatchQueue(label: "hotspot.log")
    private let maxBytes = 2 * 1024 * 1024
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Mirrors lines into the sing-box log (app Log view); set by the provider.
    public var sink: ((String, LogLevel) -> Void)?
    public var verbose = false

    public var fileURL: URL {
        FilePath.cacheDirectory.appendingPathComponent("hotspot.log")
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        log(message(), level: .debug)
    }

    public func log(_ message: String, level: LogLevel = .info) {
        let line = "[hotspot] \(message)"
        switch level {
        case .error: logger.error("\(line, privacy: .public)")
        case .warn: logger.warning("\(line, privacy: .public)")
        default: logger.info("\(line, privacy: .public)")
        }
        sink?(line, level)
        let stamped = "\(formatter.string(from: Date())) [\(level.name)] \(message)\n"
        queue.async { [self] in append(stamped) }
    }

    private func append(_ text: String) {
        let url = fileURL
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }
}

// MARK: - Interfaces

public struct HotspotInterface {
    public var name: String
    public var flags: UInt32
    public var ipv4: [String] = []
    public var netmask4: String?

    public var isUp: Bool {
        flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0
    }

    /// Personal Hotspot is a `bridgeN` interface (bridge100 in practice) with an IPv4 address.
    public var isHotspot: Bool {
        name.hasPrefix("bridge") && isUp && !ipv4.isEmpty
    }

    public var description: String {
        "\(name) up=\(isUp) inet=\(ipv4) mask=\(netmask4 ?? "-")"
    }

    public static func snapshot() -> [HotspotInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var byName: [String: HotspotInterface] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            var item = byName[name] ?? HotspotInterface(name: name, flags: ifa.pointee.ifa_flags)
            item.flags = ifa.pointee.ifa_flags
            if let addr = ifa.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET {
                if let s = numeric(addr) { item.ipv4.append(s) }
                if let mask = ifa.pointee.ifa_netmask { item.netmask4 = numeric(mask) }
            }
            byName[name] = item
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public static func hotspot() -> HotspotInterface? {
        snapshot().first(where: \.isHotspot)
    }

    private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return rc == 0 ? String(cString: host) : nil
    }
}

// MARK: - Controller

/// Measured on device (iOS, 2026-11-12): inside the packet-tunnel extension, listening sockets
/// bound to the wildcard address are unreachable (Network.framework, BSD and Go alike); only a
/// socket bound to 127.0.0.1 accepts. In the app process wildcard listeners work. Therefore:
///   - the extension only adds a `mixed` inbound on 127.0.0.1:internalPort (`injectInbound`);
///   - the app owns the hotspot-facing listener (`startSharing`) and relays each client to that
///     inbound, or, without a VPN, to an in-app sing-box core on 127.0.0.1:appCorePort.
public final class HotspotTether {
    public static let shared = HotspotTether()

    let queue = DispatchQueue(label: "hotspot.tether")
    private var settings = HotspotSettings()
    private var front: HotspotRelay?
    private var bsdDiag: HotspotBSDListener?
    private var timer: DispatchSourceTimer?
    private var lastHotspot: String?
    private var lastSelfTest: String?
    private var tick = 0

    private init() {}

    /// Adds (replacing any previous one) the loopback `mixed` inbound the hotspot listener
    /// relays into. On failure the original config is returned.
    public static func injectInbound(config: String, port: Int) -> String {
        let log = HotspotLog.shared
        guard var root = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any] else {
            log.log("profile is not plain JSON (comments/JSON5?); hotspot inbound NOT added", level: .error)
            return config
        }
        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        inbounds.removeAll { ($0["tag"] as? String) == HotspotSettings.inboundTag }
        if inbounds.contains(where: { ($0["listen_port"] as? Int) == port }) {
            log.log("profile already has an inbound on port \(port); pick another hotspot port", level: .error)
        }
        inbounds.append([
            "type": "mixed",
            "tag": HotspotSettings.inboundTag,
            "listen": "127.0.0.1",
            "listen_port": port,
        ])
        root["inbounds"] = inbounds
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            log.log("config re-serialisation failed; hotspot inbound NOT added", level: .error)
            return config
        }
        log.log("added hotspot inbound mixed 127.0.0.1:\(port)")
        return string
    }

    /// Starts the hotspot-facing listener (app process only) relaying to the first reachable
    /// of `upstreamPorts` on 127.0.0.1.
    public func startSharing(_ s: HotspotSettings, upstreamPorts: [Int]) {
        HotspotLog.shared.verbose = s.verbose
        queue.async { [self] in
            let restart = front == nil || front?.port != s.port || front?.upstreamPorts != upstreamPorts
            settings = s
            settings.enabled = true
            if restart {
                front?.cancel()
                front = HotspotRelay(port: s.port, upstreamPorts: upstreamPorts, queue: queue)
                front?.onStateChange = { [weak self] in self?.writeStatus() }
                front?.start()
            }
            if s.verbose {
                if bsdDiag == nil {
                    bsdDiag = HotspotBSDListener(port: s.internalPort + 2)
                    bsdDiag?.start()
                }
                HotspotDebugServer.shared.start()
            } else {
                bsdDiag?.stop()
                bsdDiag = nil
            }
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 2, repeating: 5)
                t.setEventHandler { [weak self] in self?.poll() }
                t.resume()
                timer = t
            }
            tick = 0
            HotspotLog.shared.log("sharing: listener *:\(s.port) -> 127.0.0.1:\(upstreamPorts) hotspot=\(HotspotInterface.hotspot()?.description ?? "none")")
        }
    }

    public func stop() {
        queue.sync {
            settings.enabled = false
            timer?.cancel(); timer = nil
            front?.cancel(); front = nil
            bsdDiag?.stop(); bsdDiag = nil
            lastHotspot = nil
            writeStatus()
        }
        HotspotLog.shared.log("sharing stopped")
    }

    // Runs on `queue` every 5 s while sharing.
    private func poll() {
        tick += 1
        let hotspot = HotspotInterface.hotspot()
        let desc = hotspot?.description
        if desc != lastHotspot {
            if let hotspot {
                HotspotLog.shared.log("Personal Hotspot up: \(hotspot.description); clients use proxy \(hotspot.ipv4.first ?? "?"):\(settings.port)")
            } else if lastHotspot != nil {
                HotspotLog.shared.log("Personal Hotspot down")
            }
            lastHotspot = desc
            runSelfTest(matrix: settings.verbose)
        } else if tick == 1 || tick % 60 == 0 {
            runSelfTest(matrix: settings.verbose && tick == 1)
        }
        if let front, front.active > 0 || settings.verbose, tick % 6 == 0 {
            HotspotLog.shared.log("stats: active=\(front.active) total=\(front.total) rejected=\(front.rejected) up=\(front.bytesUp)B down=\(front.bytesDown)B")
        }
        writeStatus()
    }

    /// Full-chain test: HTTP request through the hotspot listener -> sing-box -> outbound.
    /// With `matrix`, also raw TCP connects to every listener on every local address.
    func runSelfTest(matrix: Bool, completion: ((String) -> Void)? = nil) {
        let s = settings
        guard s.enabled else { completion?("not sharing"); return }
        HotspotProbe.http(host: "127.0.0.1", port: s.port) { [weak self] result in
            HotspotLog.shared.log("self-test via 127.0.0.1:\(s.port): \(result)", level: result.hasPrefix("OK") ? .info : .error)
            self?.queue.async {
                self?.lastSelfTest = "\(result) @ \(ISO8601DateFormatter().string(from: Date()))"
                self?.writeStatus()
            }
            guard matrix else { completion?(result); return }
            DispatchQueue.global().async {
                let lines = HotspotProbe.matrix(settings: s)
                for line in lines { HotspotLog.shared.log(line) }
                completion?(([result] + lines).joined(separator: "\n"))
            }
        }
    }

    /// Must run on `queue`.
    private func writeStatus() {
        dispatchPrecondition(condition: .onQueue(queue))
        let status = HotspotStatus(
                updated: Date(),
                listening: front?.isReady ?? false,
                listenerState: settings.enabled ? (front?.stateDescription ?? "stopped") : "disabled",
                port: settings.port,
                hotspotAddress: HotspotInterface.hotspot()?.ipv4.first,
                activeConnections: front?.active ?? 0,
                totalConnections: front?.total ?? 0,
                rejectedConnections: front?.rejected ?? 0,
                bytesUp: front?.bytesUp ?? 0,
                bytesDown: front?.bytesDown ?? 0,
                lastSelfTest: lastSelfTest
            )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) {
            try? data.write(to: HotspotStatus.fileURL, options: .atomic)
        }
    }
}

// MARK: - Front listener + relay

final class HotspotRelay {
    let port: Int
    let upstreamPorts: [Int]
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var retry = 0
    private(set) var isReady = false
    private(set) var stateDescription = "starting"
    private(set) var active = 0
    private(set) var total = 0
    private(set) var rejected = 0
    private(set) var bytesUp: UInt64 = 0
    private(set) var bytesDown: UInt64 = 0
    private var cancelled = false
    var onStateChange: (() -> Void)?

    init(port: Int, upstreamPorts: [Int], queue: DispatchQueue) {
        self.port = port
        self.upstreamPorts = upstreamPorts
        self.queue = queue
    }

    func start() {
        guard !cancelled else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            l.stateUpdateHandler = { [weak self] state in self?.onState(state) }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            stateDescription = "failed: \(error)"
            HotspotLog.shared.log("front listener on *:\(port) failed to start: \(error)", level: .error)
            scheduleRetry()
        }
    }

    func cancel() {
        cancelled = true
        listener?.cancel()
        listener = nil
    }

    private func onState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isReady = true
            retry = 0
            stateDescription = "listening"
            HotspotLog.shared.log("listener ready on *:\(port) -> 127.0.0.1:\(upstreamPorts)")
        case let .failed(error):
            isReady = false
            stateDescription = "failed: \(error)"
            HotspotLog.shared.log("front listener failed: \(error)", level: .error)
            listener?.cancel()
            listener = nil
            scheduleRetry()
        case let .waiting(error):
            isReady = false
            stateDescription = "waiting: \(error)"
            HotspotLog.shared.log("front listener waiting: \(error)", level: .warn)
        case .cancelled:
            isReady = false
            if cancelled { stateDescription = "stopped" }
        default:
            break
        }
        onStateChange?()
    }

    private func scheduleRetry() {
        guard !cancelled else { return }
        retry += 1
        let delay = min(30.0, Double(retry) * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.cancelled, self.listener == nil else { return }
            self.start()
        }
    }

    private func accept(_ client: NWConnection) {
        let peer = "\(client.endpoint)"
        guard Self.isAllowed(client.endpoint) else {
            rejected += 1
            HotspotLog.shared.log("rejected connection from non-local peer \(peer)", level: .warn)
            client.cancel()
            return
        }
        total += 1
        active += 1
        let id = total
        HotspotLog.shared.debug("conn#\(id) accepted from \(peer)")
        let session = RelaySession(id: id, client: client, upstreamPorts: upstreamPorts, queue: queue) { [weak self] up, down, reason in
            guard let self else { return }
            self.active -= 1
            self.bytesUp += up
            self.bytesDown += down
            HotspotLog.shared.debug("conn#\(id) closed (\(reason)) up=\(up)B down=\(down)B")
            if reason.hasPrefix("no sing-box inbound") {
                HotspotLog.shared.log("conn#\(id) from \(peer): sing-box inbound unreachable: \(reason)", level: .error)
            }
        }
        session.start()
    }

    /// Only loopback / private / link-local peers (hotspot clients are 172.20.10.0/28).
    static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16 ... 31).contains(b[1])) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case let .ipv6(addr):
            if addr.isLoopback || addr.isLinkLocal { return true }
            if let v4 = addr.asIPv4 { return isAllowed(.hostPort(host: .ipv4(v4), port: 0)) }
            let b = [UInt8](addr.rawValue)
            return b.first.map { $0 & 0xFE == 0xFC } ?? false
        default:
            return false
        }
    }
}

private final class RelaySession {
    let id: Int
    let client: NWConnection
    var upstream: NWConnection?
    let queue: DispatchQueue
    let onClose: (UInt64, UInt64, String) -> Void
    private var remainingPorts: [Int]
    private var up: UInt64 = 0
    private var down: UInt64 = 0
    private var eofCount = 0
    private var closed = false
    private var retain: RelaySession?
    private var failures: [String] = []

    init(id: Int, client: NWConnection, upstreamPorts: [Int], queue: DispatchQueue, onClose: @escaping (UInt64, UInt64, String) -> Void) {
        self.id = id
        self.client = client
        remainingPorts = upstreamPorts
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        retain = self
        client.stateUpdateHandler = { [self] state in
            switch state {
            case let .failed(error): close("client failed: \(error)")
            case let .waiting(error): close("client waiting: \(error)")
            default: break
            }
        }
        client.start(queue: queue)
        connectNext()
    }

    /// Tries the upstream ports in order (VPN extension inbound first, then the in-app core).
    private func connectNext() {
        guard !closed else { return }
        guard !remainingPorts.isEmpty else {
            close("no sing-box inbound reachable (\(failures.joined(separator: "; ")))")
            return
        }
        let port = remainingPorts.removeFirst()
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        upstream = conn
        var settled = false
        func fail(_ why: String) {
            guard !settled else { return }
            settled = true
            conn.cancel()
            failures.append("\(port): \(why)")
            connectNext()
        }
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !settled else { return }
                settled = true
                conn.stateUpdateHandler = { [self] state in
                    if case let .failed(error) = state { close("upstream failed: \(error)") }
                }
                pump(from: client, to: conn, isUp: true)
                pump(from: conn, to: client, isUp: false)
            case let .waiting(error): fail("\(error)")
            case let .failed(error): fail("\(error)")
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { fail("timeout") }
    }

    private func pump(from: NWConnection, to: NWConnection, isUp: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            guard !closed else { return }
            if let data, !data.isEmpty {
                if isUp { up += UInt64(data.count) } else { down += UInt64(data.count) }
                to.send(content: data, completion: .contentProcessed { [self] sendError in
                    if let sendError {
                        close("send error: \(sendError)")
                    } else if isComplete {
                        halfClose(to)
                    } else {
                        pump(from: from, to: to, isUp: isUp)
                    }
                })
            } else if isComplete {
                halfClose(to)
            } else if let error {
                close("receive error: \(error)")
            } else {
                pump(from: from, to: to, isUp: isUp)
            }
        }
    }

    private func halfClose(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        eofCount += 1
        if eofCount >= 2 { close("eof") }
    }

    private func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        onClose(up, down, reason)
        retain = nil
    }
}

// MARK: - Diagnostics

/// Plain BSD listening socket (diagnostic): answers "BSD-OK" and closes.
final class HotspotBSDListener {
    let port: Int
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(port: Int) { self.port = port }

    func start() {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(s, 16) == 0 else {
            HotspotLog.shared.log("diag BSD listener *:\(port) bind/listen failed errno=\(errno)", level: .warn)
            close(s)
            return
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: DispatchQueue.global())
        src.setEventHandler {
            let c = accept(s, nil, nil)
            guard c >= 0 else { return }
            let msg = "BSD-OK\n"
            _ = msg.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
        src.setCancelHandler { close(s) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }
}

enum HotspotProbe {
    /// HTTP GET through an HTTP proxy at host:port.
    static func http(host: String, port: Int, completion: @escaping (String) -> Void) {
        let started = Date()
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let q = DispatchQueue(label: "hotspot.probe")
        var done = false
        func finish(_ text: String) {
            q.async {
                guard !done else { return }
                done = true
                conn.cancel()
                completion("\(text) [\(Int(Date().timeIntervalSince(started) * 1000))ms]")
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = "GET http://www.gstatic.com/generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err { finish("FAIL send: \(err)") }
                })
                conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, err in
                    if let data, !data.isEmpty {
                        let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? "?"
                        finish(line.contains(" 204") || line.contains(" 200") ? "OK \(line)" : "FAIL unexpected response: \(line)")
                    } else {
                        finish("FAIL no response (\(err.map { "\($0)" } ?? "closed"))")
                    }
                }
            case let .failed(e): finish("FAIL connect: \(e)")
            case let .waiting(e): finish("FAIL waiting: \(e)")
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + 12) { finish("FAIL timeout") }
    }

    /// Raw TCP connects to each listener on each local IPv4 address.
    static func matrix(settings s: HotspotSettings) -> [String] {
        let ifs = HotspotInterface.snapshot().filter { $0.isUp && !$0.ipv4.isEmpty }
        var hosts: [(String, String)] = [("lo", "127.0.0.1")]
        for i in ifs where !i.name.hasPrefix("lo") {
            for a in i.ipv4 { hosts.append((i.name, a)) }
        }
        let ports: [(String, Int)] = [
            ("listener(NW,*)", s.port),
            ("vpn-core(127.0.0.1)", s.internalPort),
            ("app-core(127.0.0.1)", s.appCorePort),
            ("bsd(*)", s.internalPort + 2),
        ]
        var lines = ["matrix: hosts=\(hosts.map { "\($0.0)=\($0.1)" })"]
        for (pname, port) in ports {
            let results = hosts.map { "\($0.0):\(rawConnect(host: $0.1, port: port))" }
            lines.append("matrix \(pname) :\(port) -> \(results.joined(separator: " "))")
        }
        return lines
    }

    static func rawConnect(host: String, port: Int, timeout: Double = 2) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket-err" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return "OK" }
        guard errno == EINPROGRESS else { return "E\(errno)" }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        if poll(&pfd, 1, Int32(timeout * 1000)) == 0 { return "TIMEOUT" }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0 ? "OK" : (err == ECONNREFUSED ? "REFUSED" : "E\(err)")
    }
}

/// Loopback-only HTTP endpoint for reading logs over USB (verbose mode only):
/// `pymobiledevice3 usbmux forward 8899 8899; curl 127.0.0.1:8899/log`
final class HotspotDebugServer {
    static let shared = HotspotDebugServer()
    static let port: UInt16 = 8899
    static var coreLogURL: URL {
        FilePath.cacheDirectory.appendingPathComponent("singbox-core.log")
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hotspot.debugserver")

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params) else { return }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { state in
                if case let .failed(e) = state { HotspotLog.shared.log("debug server failed: \(e)", level: .warn) }
            }
            l.start(queue: queue)
            listener = l
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            func reply(_ body: Data) {
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
            switch path {
            case "/log":
                reply(Self.tail(HotspotLog.shared.fileURL))
            case "/core":
                reply(Self.tail(Self.coreLogURL))
            case "/status":
                reply((try? Data(contentsOf: HotspotStatus.fileURL)) ?? Data("none\n".utf8))
            case "/ifaces":
                reply(Data(HotspotInterface.snapshot().map(\.description).joined(separator: "\n").utf8))
            case "/test":
                HotspotTether.shared.queue.async {
                    HotspotTether.shared.runSelfTest(matrix: true) { result in reply(Data((result + "\n").utf8)) }
                }
            default:
                reply(Data("endpoints: /log /core /status /ifaces /test\n".utf8))
            }
        }
    }

    private static func tail(_ url: URL, bytes: Int = 300_000) -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return Data("(missing: \(url.path))\n".utf8)
        }
        return data.count > bytes ? data.suffix(bytes) : data
    }
}
