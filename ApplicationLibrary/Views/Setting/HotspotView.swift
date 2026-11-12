#if os(iOS)
    import Library
    import SwiftUI

    struct HotspotView: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @ObservedObject private var proxyMode = AppProxyService.shared
        @State private var isLoading = true
        @State private var alert: AlertState?

        @State private var enabled = false
        @State private var verbose = false
        @State private var port = 7890
        @State private var portText = "7890"
        @State private var status: HotspotStatus?
        @State private var hotspotAddress: String?
        @State private var testing = false
        @State private var testResult: String?

        private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

        var body: some View {
            Group {
                if isLoading {
                    ProgressView().onAppear {
                        Task { await loadSettings() }
                    }
                } else {
                    FormView {
                        FormToggle("Hotspot Sharing", """
                        Shares the sing-box connection with devices connected to this iPhone's Personal Hotspot (or the same Wi-Fi). iOS does not let a VPN app route hotspot traffic transparently, so on the client set an HTTP or SOCKS5 proxy to the address below. Client traffic then follows your profile's routing.
                        """, $enabled) { newValue in
                            await SharedPreferences.hotspotEnabled.set(newValue)
                            await applySettings()
                        }

                        Section {
                            Button {
                                Task {
                                    if proxyMode.isRunning { await proxyMode.stop() } else { await proxyMode.start() }
                                    reloadStatus()
                                }
                            } label: {
                                Label(proxyMode.isRunning ? "Stop Sharing" : "Start Sharing",
                                      systemImage: proxyMode.isRunning ? "stop.fill" : "play.fill")
                            }
                            .foregroundColor(proxyMode.isRunning ? .red : .accentColor)
                            if proxyMode.isRunning {
                                FormTextItem("Upstream", proxyMode.usesVPNCore ? "VPN" : "In-app core (no VPN)")
                            }
                            if let error = proxyMode.lastError {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                        } footer: {
                            Text("The app listens for hotspot clients and passes them to sing-box: to the VPN when it is connected (start the VPN first, with Hotspot Sharing enabled), otherwise to a sing-box core inside the app. Keep the app running in the background; do not force-quit it.")
                        }

                        Section {
                            HStack {
                                Text("Port")
                                TextField("7890", text: $portText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit { Task { await savePort() } }
                            }
                            if Int(portText) != port {
                                Button("Save Port") { Task { await savePort() } }
                            }
                        } footer: {
                            Text("The proxy also uses port \(String(port <= 55000 ? port + 10000 : port - 10000)) on 127.0.0.1 internally.")
                        }

                        Section("Client Proxy Settings") {
                            FormTextItem("Server", hotspotAddress ?? "172.20.10.1")
                            FormTextItem("Port", String(port))
                            FormTextItem("Type", "HTTP or SOCKS5")
                            if hotspotAddress == nil {
                                Text("Personal Hotspot has no connected clients right now; 172.20.10.1 is the usual iPhone hotspot address.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if enabled || proxyMode.isRunning {
                            Section("Status") {
                                if let status, Date().timeIntervalSince(status.updated) < 15 {
                                    FormTextItem("Listener", status.listenerState)
                                    FormTextItem("Connections", "\(status.activeConnections) active / \(status.totalConnections) total")
                                    if status.rejectedConnections > 0 {
                                        FormTextItem("Rejected", String(status.rejectedConnections))
                                    }
                                    FormTextItem("Traffic", "↑ \(format(status.bytesUp))  ↓ \(format(status.bytesDown))")
                                    if let last = status.lastSelfTest {
                                        FormTextItem("Self-test", last)
                                    }
                                } else {
                                    Text("Not running. Start the VPN or Proxy Mode to share it.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        FormToggle("Diagnostics", """
                        Adds listener reachability tests and verbose hotspot logging to the log. Use only for troubleshooting.
                        """, $verbose) { newValue in
                            await SharedPreferences.hotspotVerbose.set(newValue)
                            await applySettings()
                        }
                    }
                }
            }
            .navigationTitle("Hotspot")
            .navigationBarTitleDisplayMode(.inline)
            .alert($alert)
            .onReceive(refresh) { _ in reloadStatus() }
        }

        private func format(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
        }

        private func reloadStatus() {
            status = HotspotStatus.read()
            hotspotAddress = HotspotInterface.hotspot()?.ipv4.first ?? status?.hotspotAddress
        }

        private func savePort() async {
            guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1024 ... 65535).contains(value) else {
                alert = AlertState(errorMessage: String(localized: "Port must be between 1024 and 65535"))
                portText = String(port)
                return
            }
            port = value
            await SharedPreferences.hotspotPort.set(value)
            await applySettings()
        }

        private func applySettings() async {
            if let profile = environments.extensionProfile, profile.status.isConnected {
                do {
                    try await profile.reloadService()
                } catch {
                    alert = AlertState(action: "reload service", error: error)
                }
                // Give the extension a moment to bring its loopback inbound up.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if proxyMode.isRunning {
                await proxyMode.reload()
            }
        }

        @MainActor
        private func loadSettings() async {
            enabled = await SharedPreferences.hotspotEnabled.get()
            verbose = await SharedPreferences.hotspotVerbose.get()
            port = await SharedPreferences.hotspotPort.get()
            portText = String(port)
            reloadStatus()
            isLoading = false
        }
    }
#endif
