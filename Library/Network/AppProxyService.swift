#if os(iOS)
    import AVFoundation
    import Foundation
    import Libbox
    import Network
    import os

    /// Proxy mode: runs the sing-box core inside the app process, without a VPN / Network
    /// Extension (for builds signed by a free Apple developer account, which cannot use the
    /// Network Extension capability). `tun` inbounds are dropped; the hotspot front listener
    /// relays hotspot / LAN clients into a `mixed` inbound, so their traffic follows the
    /// profile's routing. The phone's own traffic is not affected. Silent audio keeps the app
    /// running in the background.
    @MainActor
    public final class AppProxyService: ObservableObject {
        public static let shared = AppProxyService()

        @Published public private(set) var isRunning = false
        @Published public private(set) var lastError: String?

        private var commandServer: LibboxCommandServer?
        private lazy var platform = AppProxyPlatformInterface(self)
        private let keepAlive = BackgroundKeepAlive()

        private init() {}

        @Published public private(set) var usesVPNCore = false
        private var busy = false

        /// Starts hotspot sharing: the app listens on *:port and relays clients to the VPN
        /// extension's loopback inbound when the VPN is running, otherwise to an in-app
        /// sing-box core (proxy mode).
        public func start() async {
            guard !busy else { return }
            busy = true
            defer { busy = false }
            lastError = nil
            do {
                var settings = HotspotSettings()
                settings.enabled = true
                settings.port = await SharedPreferences.hotspotPort.get()
                settings.verbose = await SharedPreferences.hotspotVerbose.get()
                HotspotLog.shared.verbose = settings.verbose
                HotspotLog.shared.sink = { [weak self] message, level in
                    Task { @MainActor in self?.writeMessage(message, level: level) }
                }
                let vpnPort = settings.internalPort
                let vpnCore = await Task.detached {
                    HotspotProbe.rawConnect(host: "127.0.0.1", port: vpnPort, timeout: 0.5) == "OK"
                }.value
                usesVPNCore = vpnCore
                if vpnCore {
                    HotspotLog.shared.log("VPN core inbound 127.0.0.1:\(vpnPort) reachable; relaying hotspot clients to the VPN")
                    stopCore()
                } else {
                    HotspotLog.shared.log("VPN core not running; starting in-app sing-box core (proxy mode)")
                    try await startCore(settings)
                }
                HotspotTether.shared.startSharing(settings, upstreamPorts: [settings.internalPort, settings.appCorePort])
                keepAlive.start()
                isRunning = true
                await SharedPreferences.proxyModeRunning.set(true)
            } catch {
                lastError = error.localizedDescription
                HotspotLog.shared.log("hotspot sharing start failed: \(error.localizedDescription)", level: .error)
                stopCore()
                HotspotTether.shared.stop()
                keepAlive.stop()
                isRunning = false
            }
        }

        private func startCore(_ settings: HotspotSettings) async throws {
            let profileID = await SharedPreferences.selectedProfileID.get()
            guard let profile = try await ProfileManager.get(profileID) else {
                throw NSError(domain: "AppProxyService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No profile selected"])
            }
            var config = try await profile.readAsync()
            config = try Self.stripTun(config, verbose: settings.verbose)
            config = HotspotTether.injectInbound(config: config, port: settings.appCorePort)
            if commandServer == nil {
                var error: NSError?
                let server = LibboxNewCommandServer(platform, platform, &error)
                if let error { throw error }
                guard let server else { throw NSError(domain: "AppProxyService", code: 2, userInfo: [NSLocalizedDescriptionKey: "command server unavailable"]) }
                try server.start()
                commandServer = server
            }
            try commandServer!.startOrReloadService(config, options: LibboxOverrideOptions())
            writeMessage("(proxy-mode) in-app core started", level: .info)
        }

        /// Closes the in-app core and its command server (so a VPN started later can own the
        /// command socket and cache file).
        private func stopCore() {
            guard let server = commandServer else { return }
            do {
                try server.closeService()
            } catch {
                HotspotLog.shared.log("in-app core stop: \(error.localizedDescription)", level: .warn)
            }
            server.close()
            commandServer = nil
        }

        public func stop() async {
            stopCore()
            HotspotTether.shared.stop()
            keepAlive.stop()
            isRunning = false
            usesVPNCore = false
            await SharedPreferences.proxyModeRunning.set(false)
        }

        public func reload() async {
            guard isRunning else { return }
            await start()
        }

        func writeMessage(_ message: String, level: LogLevel = .info) {
            commandServer?.writeMessage(Int32(level.rawValue), message: message)
        }

        /// Removes `tun` inbounds (no packet tunnel in proxy mode) and route settings that
        /// only make sense with one.
        static func stripTun(_ config: String, verbose: Bool) throws -> String {
            guard var root = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any] else {
                throw NSError(domain: "AppProxyService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Proxy mode needs a plain JSON profile (no comments)"])
            }
            if var inbounds = root["inbounds"] as? [[String: Any]] {
                let removed = inbounds.filter { ($0["type"] as? String) == "tun" }.compactMap { $0["tag"] as? String }
                inbounds.removeAll { ($0["type"] as? String) == "tun" }
                root["inbounds"] = inbounds
                if !removed.isEmpty {
                    HotspotLog.shared.log("proxy mode: removed tun inbound(s) \(removed)")
                }
            }
            // Own cache file so a VPN extension started later does not time out on the lock.
            var experimental = root["experimental"] as? [String: Any] ?? [:]
            var cacheFile = experimental["cache_file"] as? [String: Any] ?? [:]
            cacheFile["path"] = "cache-proxy-mode.db"
            experimental["cache_file"] = cacheFile
            root["experimental"] = experimental
            if verbose {
                // Diagnostics: also write the core log to a file readable over USB (/core).
                var log = root["log"] as? [String: Any] ?? [:]
                log["level"] = "debug"
                log["timestamp"] = true
                log["output"] = HotspotDebugServer.coreLogURL.path
                root["log"] = log
            }
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Background keep-alive (silent audio)

    final class BackgroundKeepAlive {
        private var player: AVAudioPlayer?
        private var observer: NSObjectProtocol?

        func start() {
            guard player == nil else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.mixWithOthers])
                try session.setActive(true)
                let p = try AVAudioPlayer(data: Self.silentWAV())
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                p.play()
                player = p
                observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self?.player?.play()
                    HotspotLog.shared.log("keep-alive: audio resumed after interruption")
                }
                HotspotLog.shared.log("keep-alive: silent audio started")
            } catch {
                HotspotLog.shared.log("keep-alive failed: \(error.localizedDescription)", level: .error)
            }
        }

        func stop() {
            player?.stop()
            player = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        /// 1 s of 8 kHz mono 16-bit silence.
        static func silentWAV() -> Data {
            let sampleRate: UInt32 = 8000
            let samples = Int(sampleRate)
            let dataSize = UInt32(samples * 2)
            var d = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
            d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
            d.append(contentsOf: Array("data".utf8)); u32(dataSize)
            d.append(Data(count: Int(dataSize)))
            return d
        }
    }

    // MARK: - Platform interface (no tunnel)

    final class AppProxyPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
        private weak var service: AppProxyService?
        private var nwMonitor: NWPathMonitor?
        private var lastNetworkPath: String?

        init(_ service: AppProxyService) {
            self.service = service
        }

        private func unsupported(_ what: String) -> NSError {
            NSError(domain: "AppProxyPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(what) is not available in proxy mode"])
        }

        func openTun(_: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
            throw unsupported("tun")
        }

        func usePlatformAutoDetectControl() -> Bool { false }
        func autoDetectControl(_: Int32) throws {}

        func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
            throw unsupported("process lookup")
        }

        func writeLog(_ message: String?) {
            guard let message else { return }
            Task { @MainActor [weak service] in service?.writeMessage(message) }
        }

        func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
            guard let listener else { return }
            let monitor = NWPathMonitor()
            nwMonitor = monitor
            let semaphore = DispatchSemaphore(value: 0)
            monitor.pathUpdateHandler = { path in
                self.onUpdate(listener, path)
                semaphore.signal()
                monitor.pathUpdateHandler = { path in self.onUpdate(listener, path) }
            }
            monitor.start(queue: DispatchQueue.global())
            semaphore.wait()
        }

        private func onUpdate(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
            let description = "\(path.status) \(path.availableInterfaces.map { "\($0.name)#\($0.index)" })"
            listener.updateNetworkPath(description)
            if description == lastNetworkPath { return }
            lastNetworkPath = description
            // Hotspot bridge interfaces are never the uplink.
            let routable = Set(HotspotInterface.snapshot().filter { i in
                i.isUp && i.ipv4.contains { !$0.hasPrefix("169.254.") }
            }.map(\.name))
            HotspotLog.shared.log("network path: \(description) routable=\(routable.sorted())")
            guard path.status != .unsatisfied,
                  let iface = path.availableInterfaces.first(where: { !$0.name.hasPrefix("bridge") && routable.contains($0.name) })
                  ?? path.availableInterfaces.first(where: { !$0.name.hasPrefix("bridge") })
            else {
                listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            HotspotLog.shared.log("default interface -> \(iface.name)")
            listener.updateDefaultInterface(iface.name, interfaceIndex: Int32(iface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }

        func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
            nwMonitor?.cancel()
            nwMonitor = nil
            lastNetworkPath = nil
        }

        func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
            guard let nwMonitor else { throw unsupported("interface list before monitor start") }
            let path = nwMonitor.currentPath
            var interfaces: [LibboxNetworkInterface] = []
            if path.status != .unsatisfied {
                for it in path.availableInterfaces {
                    let interface = LibboxNetworkInterface()
                    interface.name = it.name
                    interface.index = Int32(it.index)
                    switch it.type {
                    case .wifi: interface.type = LibboxInterfaceTypeWIFI
                    case .cellular: interface.type = LibboxInterfaceTypeCellular
                    case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
                    default: interface.type = LibboxInterfaceTypeOther
                    }
                    interfaces.append(interface)
                }
            }
            return InterfaceIterator(interfaces)
        }

        final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
            private var iterator: IndexingIterator<[LibboxNetworkInterface]>
            private var nextValue: LibboxNetworkInterface?
            init(_ array: [LibboxNetworkInterface]) { iterator = array.makeIterator() }
            func hasNext() -> Bool { nextValue = iterator.next(); return nextValue != nil }
            func next() -> LibboxNetworkInterface? { nextValue }
        }

        func underNetworkExtension() -> Bool { false }
        func includeAllNetworks() -> Bool { false }
        func clearDNSCache() {}
        func readWIFIState() -> LibboxWIFIState? { nil }
        func readWIFISSID() -> String? { nil }
        func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws { throw unsupported("ssh agent") }

        func serviceStop() throws {
            Task { @MainActor [weak service] in await service?.stop() }
        }

        func serviceReload() throws {
            Task { @MainActor [weak service] in await service?.reload() }
        }

        func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
        func setSystemProxyEnabled(_: Bool) throws {}
        func triggerNativeCrash() throws { throw unsupported("native crash") }
        func writeDebugMessage(_ message: String?) {
            if let message { HotspotLog.shared.debug(message) }
        }

        func send(_: LibboxNotification?) throws {}
        func cancelNotification(_: String?, typeID _: Int32) throws {}
        func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
        func registerMyInterface(_: String?) {}
        func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
        func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
        func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
        func usePlatformShell() -> Bool { false }
        func checkPlatformShell() throws { throw unsupported("shell") }
        func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
            throw unsupported("shell")
        }

        func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
            error?.pointee = unsupported("ssh host key")
            return ""
        }

        func lookupSFTPServer(_ error: NSErrorPointer) -> String {
            error?.pointee = unsupported("sftp")
            return ""
        }

        func tailscaleHostname() -> String { "" }
        func usePlatformBridge() -> Bool { false }
        func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol { throw unsupported("bridge") }
        func usePlatformAutoRedirect() -> Bool { false }
        func createAutoRedirect(_: Data?, handler _: (any LibboxAutoRedirectHandlerProtocol)?) throws -> any LibboxAutoRedirectSessionProtocol {
            throw unsupported("auto redirect")
        }

        func lookupUser(_: String?) throws -> LibboxPlatformUser { throw unsupported("user lookup") }
    }
#endif
