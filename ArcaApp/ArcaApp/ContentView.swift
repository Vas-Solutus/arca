//
// ContentView.swift
// Arca
//
// Main status window showing Arca daemon info
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var setupManager: SetupManager
    @State private var daemonStatus: String = "Checking..."
    @State private var daemonRunning: Bool = false
    @State private var statusCheckTimer: Timer?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                if let appIconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
                   let appIcon = NSImage(contentsOfFile: appIconPath) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 80, height: 80)
                } else {
                    Image(systemName: "cube.box.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)
                }

                Text("Arca")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Docker Engine API for Apple Containerization")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)

            Divider()

            // Status Section
            if setupManager.isSetupComplete {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: daemonRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(daemonRunning ? .green : .red)
                        Text("Daemon Status:")
                            .fontWeight(.semibold)
                        Text(daemonStatus)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("Version:")
                            .fontWeight(.semibold)
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "network")
                            .foregroundColor(.blue)
                        Text("Socket:")
                            .fontWeight(.semibold)
                        Text("~/.arca/arca.sock")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                // Docker CLI Usage
                VStack(alignment: .leading, spacing: 8) {
                    Text("Docker CLI Usage:")
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("export DOCKER_HOST=unix://$HOME/.arca/arca.sock")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)

                            Button(action: copyDockerHost) {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }

                        Text("docker ps")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

                // Control Buttons
                HStack {
                    Button(daemonRunning ? "Stop Daemon" : "Start Daemon") {
                        if daemonRunning {
                            stopDaemon()
                        } else {
                            startDaemon()
                        }
                    }
                    .disabled(setupManager.isRunningSetup)

                    Button("Refresh Status") {
                        checkDaemonStatus()
                    }

                    Button("Re-run Setup") {
                        Task {
                            await setupManager.runSetup()
                            checkDaemonStatus()
                        }
                    }
                    .disabled(setupManager.isRunningSetup)
                }
                .padding(.bottom, 20)

            } else if setupManager.isRunningSetup {
                // Setup or update in progress
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding()

                    Text(setupManager.needsVminitUpdate ? "Updating Arca..." : "Running first-time setup...")
                        .font(.headline)

                    Text(setupManager.setupStatus)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)

            } else if let error = setupManager.setupError {
                // Setup failed
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.red)

                    Text("Setup Failed")
                        .font(.headline)

                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Retry Setup") {
                        Task {
                            await setupManager.runSetup()
                        }
                    }
                }
                .padding(40)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if setupManager.isSetupComplete {
                checkDaemonStatus()
            }
        }
        .onChange(of: setupManager.isSetupComplete) { _, isComplete in
            if isComplete {
                // Setup just completed - check daemon status
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                    checkDaemonStatus()
                }

                // Start periodic status checks (every 5 seconds)
                startStatusCheckTimer()
            }
        }
        .onAppear {
            if setupManager.isSetupComplete {
                startStatusCheckTimer()
            }
        }
        .onDisappear {
            stopStatusCheckTimer()
        }
    }

    private func checkDaemonStatus() {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", "com.liquescent.arca"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse launchctl output - look for PID
                if let pidLine = output.split(separator: "\n").first(where: { $0.contains("PID") }) {
                    // Extract PID value - if it's a number, daemon is running
                    let components = pidLine.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                    if components.count >= 2, let pid = Int(components[1].replacingOccurrences(of: ";", with: "")), pid > 0 {
                        daemonRunning = true
                        daemonStatus = "Running (PID: \(pid))"
                    } else {
                        daemonRunning = false
                        // Check for last exit status
                        if let exitLine = output.split(separator: "\n").first(where: { $0.contains("LastExitStatus") }) {
                            let exitComponents = exitLine.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                            if exitComponents.count >= 2 {
                                let exitCode = exitComponents[1].replacingOccurrences(of: ";", with: "")
                                daemonStatus = "Stopped (exit code: \(exitCode))"
                            } else {
                                daemonStatus = "Stopped"
                            }
                        } else {
                            daemonStatus = "Stopped"
                        }
                    }
                } else {
                    daemonRunning = false
                    daemonStatus = "Stopped"
                }
            }
        } catch {
            // Service not loaded
            daemonStatus = "Not loaded"
            daemonRunning = false
        }
    }

    private func startDaemon() {
        Task {
            do {
                try await Task.detached {
                    let task = Process()
                    task.launchPath = "/bin/launchctl"
                    task.arguments = ["load", "-w", "\(NSHomeDirectory())/Library/LaunchAgents/com.liquescent.arca.plist"]

                    try task.run()
                    task.waitUntilExit()
                }.value

                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                checkDaemonStatus()
            } catch {
                print("Failed to start daemon: \(error)")
            }
        }
    }

    private func stopDaemon() {
        Task {
            do {
                try await Task.detached {
                    let task = Process()
                    task.launchPath = "/bin/launchctl"
                    task.arguments = ["unload", "\(NSHomeDirectory())/Library/LaunchAgents/com.liquescent.arca.plist"]

                    try task.run()
                    task.waitUntilExit()
                }.value

                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                checkDaemonStatus()
            } catch {
                print("Failed to stop daemon: \(error)")
            }
        }
    }

    private func copyDockerHost() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("export DOCKER_HOST=unix://$HOME/.arca/arca.sock", forType: .string)
    }

    private func startStatusCheckTimer() {
        stopStatusCheckTimer() // Stop any existing timer

        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            checkDaemonStatus()
        }
    }

    private func stopStatusCheckTimer() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
    }
}

#Preview {
    ContentView()
        .environmentObject(SetupManager())
        .frame(width: 500, height: 400)
}
