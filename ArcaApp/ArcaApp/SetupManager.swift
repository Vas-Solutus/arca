//
// SetupManager.swift
// Arca
//
// Manages first-time setup and configuration
//

import Foundation
import SwiftUI

@MainActor
class SetupManager: ObservableObject {
    @Published var isSetupComplete: Bool = false
    @Published var isRunningSetup: Bool = false
    @Published var setupStatus: String = ""
    @Published var setupError: String? = nil

    init() {
        checkSetupStatus()

        if !isSetupComplete {
            Task {
                await runSetup()
            }
        }
    }

    private func checkSetupStatus() {
        // Check if ALL required setup files exist
        let arcaDir = NSHomeDirectory() + "/.arca"
        let kernelPath = arcaDir + "/vmlinux"
        let vminitPath = arcaDir + "/vminit"
        let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/com.liquescent.arca.plist"

        isSetupComplete = FileManager.default.fileExists(atPath: kernelPath)
            && FileManager.default.fileExists(atPath: vminitPath)
            && FileManager.default.fileExists(atPath: launchAgentPath)
    }

    func runSetup() async {
        isRunningSetup = true
        setupError = nil

        do {
            // Step 1: Create ~/.arca directory
            setupStatus = "Creating Arca directory..."
            try await createArcaDirectory()

            // Step 2: Extract kernel
            setupStatus = "Extracting Linux kernel..."
            try await extractKernel()

            // Step 3: Extract vminit
            setupStatus = "Extracting container runtime..."
            try await extractVminit()

            // Step 4: Install LaunchAgent
            setupStatus = "Installing daemon service..."
            try await installLaunchAgent()

            // Step 5: Configure shell
            setupStatus = "Configuring shell environment..."
            try await configureShell()

            // Step 6: Start daemon
            setupStatus = "Starting Arca daemon..."
            try await startDaemon()

            setupStatus = "Setup complete!"
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            isSetupComplete = true
            isRunningSetup = false

        } catch {
            setupError = error.localizedDescription
            isRunningSetup = false
        }
    }

    private func createArcaDirectory() async throws {
        let arcaDir = NSHomeDirectory() + "/.arca"

        if !FileManager.default.fileExists(atPath: arcaDir) {
            try FileManager.default.createDirectory(atPath: arcaDir, withIntermediateDirectories: true)
        }
    }

    private func extractKernel() async throws {
        let appBundle = Bundle.main.bundlePath as NSString

        let kernelSource = appBundle.appendingPathComponent("Contents/Resources/vmlinux")
        let kernelDest = NSHomeDirectory() + "/.arca/vmlinux"

        // Remove existing symlink/file if present
        if FileManager.default.fileExists(atPath: kernelDest) {
            try FileManager.default.removeItem(atPath: kernelDest)
        }

        // Create symlink to kernel in app bundle
        try FileManager.default.createSymbolicLink(atPath: kernelDest, withDestinationPath: kernelSource)
    }

    private func extractVminit() async throws {
        let appBundle = Bundle.main.bundlePath as NSString

        let vminitZip = appBundle.appendingPathComponent("Contents/Resources/vminit.zip")
        let vminitDest = NSHomeDirectory() + "/.arca/vminit"

        // Remove existing vminit if present
        if FileManager.default.fileExists(atPath: vminitDest) {
            try FileManager.default.removeItem(atPath: vminitDest)
        }

        // Run blocking operations on background thread
        try await Task.detached {
            // Decrypt and extract vminit.zip directly to temp file (avoid pipe deadlock)
            let tempFile = NSTemporaryDirectory() + "vminit.tar.gz"
            let tempFileURL = URL(fileURLWithPath: tempFile)

            // Create empty temp file
            FileManager.default.createFile(atPath: tempFile, contents: nil)

            let unzipTask = Process()
            unzipTask.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipTask.arguments = ["-q", "-P", "arca-vminit-payload", "-p", vminitZip]

            // Write directly to file instead of pipe to avoid deadlock
            let fileHandle = try FileHandle(forWritingTo: tempFileURL)
            unzipTask.standardOutput = fileHandle

            try unzipTask.run()
            unzipTask.waitUntilExit()

            try fileHandle.close()

            if unzipTask.terminationStatus != 0 {
                throw SetupError.vminitExtractionFailed
            }

            // Extract tar.gz
            let tarTask = Process()
            tarTask.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarTask.arguments = ["xzf", tempFile, "-C", NSHomeDirectory() + "/.arca"]

            try tarTask.run()
            tarTask.waitUntilExit()

            if tarTask.terminationStatus != 0 {
                throw SetupError.vminitExtractionFailed
            }

            // Clean up temp file
            try? FileManager.default.removeItem(atPath: tempFile)
        }.value
    }

    private func installLaunchAgent() async throws {
        let appBundle = Bundle.main.bundlePath

        let launchAgentDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let launchAgentPath = launchAgentDir + "/com.liquescent.arca.plist"

        // Check if directory exists and is writable
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: launchAgentDir, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw SetupError.launchAgentDirNotDirectory
            }
            // Check if writable
            if !FileManager.default.isWritableFile(atPath: launchAgentDir) {
                throw SetupError.launchAgentDirNotWritable
            }
        } else {
            // Create LaunchAgents directory
            try FileManager.default.createDirectory(atPath: launchAgentDir, withIntermediateDirectories: true)
        }

        // Generate LaunchAgent plist
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.liquescent.arca</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(appBundle)/Contents/Resources/Arca</string>
                <string>daemon</string>
                <string>start</string>
                <string>--socket-path</string>
                <string>\(NSHomeDirectory())/.arca/arca.sock</string>
                <string>--kernel-path</string>
                <string>\(NSHomeDirectory())/.arca/vmlinux</string>
                <string>--log-level</string>
                <string>info</string>
                <string>--foreground</string>
            </array>

            <key>RunAtLoad</key>
            <false/>

            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>

            <key>StandardOutPath</key>
            <string>\(NSHomeDirectory())/.arca/arca.log</string>

            <key>StandardErrorPath</key>
            <string>\(NSHomeDirectory())/.arca/arca.log</string>

            <key>WorkingDirectory</key>
            <string>\(NSHomeDirectory())</string>

            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
                <key>HOME</key>
                <string>\(NSHomeDirectory())</string>
            </dict>
        </dict>
        </plist>
        """

        try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
    }

    private func configureShell() async throws {
        let shellConfig = detectShellConfig()

        guard let configPath = shellConfig else {
            // No shell config found, skip
            return
        }

        // Check if already configured
        if let contents = try? String(contentsOfFile: configPath, encoding: .utf8),
           contents.contains("# Arca configuration") {
            // Already configured
            return
        }

        // Append Arca configuration
        let config = """

        # Arca configuration
        export PATH="\(Bundle.main.bundlePath)/Contents/Resources:$PATH"
        export DOCKER_HOST="unix://$HOME/.arca/arca.sock"
        """

        let fileHandle = FileHandle(forWritingAtPath: configPath)
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(config.data(using: .utf8) ?? Data())
        fileHandle?.closeFile()
    }

    private func detectShellConfig() -> String? {
        let homeDir = NSHomeDirectory()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        if shell.contains("zsh") {
            return homeDir + "/.zshrc"
        } else if shell.contains("bash") {
            if FileManager.default.fileExists(atPath: homeDir + "/.bash_profile") {
                return homeDir + "/.bash_profile"
            } else {
                return homeDir + "/.bashrc"
            }
        } else if shell.contains("fish") {
            let fishConfig = homeDir + "/.config/fish/config.fish"
            let fishDir = homeDir + "/.config/fish"

            if !FileManager.default.fileExists(atPath: fishDir) {
                try? FileManager.default.createDirectory(atPath: fishDir, withIntermediateDirectories: true)
            }

            return fishConfig
        }

        return nil
    }

    private func startDaemon() async throws {
        try await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["load", "-w", "\(NSHomeDirectory())/Library/LaunchAgents/com.liquescent.arca.plist"]

            try task.run()
            task.waitUntilExit()

            if task.terminationStatus != 0 {
                throw SetupError.daemonStartFailed
            }
        }.value

        // Wait for daemon to start
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    }
}

enum SetupError: LocalizedError {
    case appBundleNotFound
    case vminitExtractionFailed
    case daemonStartFailed
    case launchAgentDirNotDirectory
    case launchAgentDirNotWritable

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound:
            return "Could not locate Arca.app bundle"
        case .vminitExtractionFailed:
            return "Failed to extract container runtime"
        case .daemonStartFailed:
            return "Failed to start Arca daemon"
        case .launchAgentDirNotDirectory:
            return "~/Library/LaunchAgents exists but is not a directory"
        case .launchAgentDirNotWritable:
            return "~/Library/LaunchAgents is not writable. It may be owned by root.\n\nFix with: sudo chown -R $USER:staff ~/Library/LaunchAgents/"
        }
    }
}
