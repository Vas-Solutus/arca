import Foundation
import Virtualization
import Logging

/// NetworkHelperVM manages the lifecycle of the helper VM running OVN/OVS
public actor NetworkHelperVM {
    private let logger: Logger
    private var vm: VZVirtualMachine?
    private var crashCount = 0
    private let maxCrashes = 3
    private var isShuttingDown = false

    // VM configuration
    private let vmImagePath: URL
    private let kernelPath: URL
    private let vmCID: UInt32 = 3  // vsock context ID for helper VM

    public enum NetworkHelperVMError: Error, CustomStringConvertible {
        case vmNotRunning
        case vmImageNotFound(String)
        case kernelNotFound(String)
        case vmConfigurationInvalid(String)
        case vmStartFailed(String)
        case tooManyCrashes
        case healthCheckFailed

        public var description: String {
            switch self {
            case .vmNotRunning:
                return "Helper VM is not running"
            case .vmImageNotFound(let path):
                return "Helper VM image not found at: \(path)"
            case .kernelNotFound(let path):
                return "Kernel not found at: \(path)"
            case .vmConfigurationInvalid(let reason):
                return "VM configuration invalid: \(reason)"
            case .vmStartFailed(let reason):
                return "Failed to start helper VM: \(reason)"
            case .tooManyCrashes:
                return "Helper VM crashed too many times (max: 3)"
            case .healthCheckFailed:
                return "Helper VM health check failed"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.network.helpervm")

        // Helper VM image location
        let arcaDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
        self.vmImagePath = arcaDir
            .appendingPathComponent("helpervm")
            .appendingPathComponent("disk.img")

        // Kernel location (shared with containerization)
        self.kernelPath = arcaDir.appendingPathComponent("vmlinux")

        logger?.info("NetworkHelperVM initialized", metadata: [
            "vmImagePath": "\(vmImagePath.path)",
            "kernelPath": "\(kernelPath.path)"
        ])
    }

    /// Start the helper VM
    public func start() async throws {
        logger.info("Starting helper VM...")

        // Check if VM already running
        if vm?.state == .running {
            logger.warning("Helper VM already running")
            return
        }

        // Verify files exist
        guard FileManager.default.fileExists(atPath: vmImagePath.path) else {
            throw NetworkHelperVMError.vmImageNotFound(vmImagePath.path)
        }

        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw NetworkHelperVMError.kernelNotFound(kernelPath.path)
        }

        // Create VM configuration
        let config = try createVMConfiguration()

        // Create and start VM
        let newVM = VZVirtualMachine(configuration: config)
        self.vm = newVM

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            newVM.start { result in
                switch result {
                case .success:
                    Task {
                        await self.onVMStarted()
                    }
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: NetworkHelperVMError.vmStartFailed(error.localizedDescription))
                }
            }
        }

        logger.info("Helper VM started successfully")

        // Start health monitoring
        Task {
            await monitorHealth()
        }
    }

    /// Stop the helper VM
    public func stop() async throws {
        logger.info("Stopping helper VM...")

        isShuttingDown = true

        guard let vm = vm else {
            logger.warning("No VM to stop")
            return
        }

        guard vm.state == .running else {
            logger.warning("VM not running (state: \(vm.state))")
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        self.vm = nil
        logger.info("Helper VM stopped")
    }

    /// Check if helper VM is healthy
    public func isHealthy() async -> Bool {
        guard let vm = vm, vm.state == .running else {
            return false
        }

        // TODO: Add actual health check via gRPC GetHealth call
        // For now, just check if VM is running
        return true
    }

    /// Get the VM's vsock CID for connections
    public func getVMCID() -> UInt32 {
        return vmCID
    }

    // MARK: - Private Methods

    private func createVMConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        // CPU: 1 vCPU
        config.cpuCount = 1

        // Memory: 256MB
        config.memorySize = 256 * 1024 * 1024

        // Bootloader (Linux)
        let bootloader = VZLinuxBootLoader(kernelURL: kernelPath)
        bootloader.commandLine = "console=hvc0 root=/dev/vda rw"
        config.bootLoader = bootloader

        // Disk (helper VM image)
        do {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: vmImagePath,
                readOnly: false
            )
            let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            config.storageDevices = [disk]
        } catch {
            throw NetworkHelperVMError.vmConfigurationInvalid("Failed to create disk attachment: \(error)")
        }

        // Network (vmnet NAT for internet access)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // Console (virtio console)
        let console = VZVirtioConsoleDeviceConfiguration()
        let consolePort = VZVirtioConsolePortConfiguration()
        consolePort.isConsole = true

        // Attach console output handler
        consolePort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: FileHandle.standardOutput
        )

        console.ports[0] = consolePort
        config.consoleDevices = [console]

        // Socket device (vsock for control API)
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketDevice]

        // Validate configuration
        do {
            try config.validate()
        } catch {
            throw NetworkHelperVMError.vmConfigurationInvalid(error.localizedDescription)
        }

        return config
    }

    private func onVMStarted() {
        logger.info("Helper VM started, waiting for services to initialize...")
        crashCount = 0

        // Give the VM time to boot and start services
        Task {
            try? await Task.sleep(for: .seconds(5))
            logger.info("Helper VM should be ready")
        }
    }

    private func monitorHealth() async {
        while !isShuttingDown {
            try? await Task.sleep(for: .seconds(5))

            let healthy = await isHealthy()

            if !healthy && !isShuttingDown {
                logger.error("Helper VM unhealthy, attempting restart...")
                crashCount += 1

                if crashCount > maxCrashes {
                    logger.critical("Helper VM crashed too many times, giving up")
                    return
                }

                do {
                    try await restart()
                } catch {
                    logger.error("Failed to restart helper VM: \(error)")
                }
            }
        }
    }

    private func restart() async throws {
        logger.info("Restarting helper VM...")

        try await stop()
        try await Task.sleep(for: .seconds(2))
        try await start()

        // TODO: Restore network state after restart
        logger.info("Helper VM restarted successfully")
    }
}

/// Console handler for VM output
private class ConsoleHandler {
    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }
}
