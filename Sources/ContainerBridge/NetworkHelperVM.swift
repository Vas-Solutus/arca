import Foundation
import Virtualization
import Logging

/// NetworkHelperVM manages the lifecycle of the helper VM running OVN/OVS
public final class NetworkHelperVM: @unchecked Sendable {
    private let logger: Logger
    private nonisolated(unsafe) var vm: VZVirtualMachine?
    private nonisolated(unsafe) var crashCount = 0
    private let maxCrashes = 3
    private nonisolated(unsafe) var isShuttingDown = false

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
        logger.debug("Checking for VM image at: \(vmImagePath.path)")
        guard FileManager.default.fileExists(atPath: vmImagePath.path) else {
            logger.error("VM image not found at: \(vmImagePath.path)")
            throw NetworkHelperVMError.vmImageNotFound(vmImagePath.path)
        }
        logger.debug("VM image found")

        logger.debug("Checking for kernel at: \(kernelPath.path)")
        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            logger.error("Kernel not found at: \(kernelPath.path)")
            throw NetworkHelperVMError.kernelNotFound(kernelPath.path)
        }
        logger.debug("Kernel found")

        // Create VM configuration
        logger.debug("Creating VM configuration...")
        let config: VZVirtualMachineConfiguration
        do {
            config = try createVMConfiguration()
            logger.debug("VM configuration created successfully")
        } catch {
            logger.error("Failed to create VM configuration: \(error)")
            throw error
        }

        // Create and start VM
        logger.debug("Creating VZVirtualMachine instance...")
        let newVM = VZVirtualMachine(configuration: config)
        self.vm = newVM

        // Add state observation
        logger.debug("VM initial state: \(newVM.state)")

        logger.debug("VZVirtualMachine instance created, starting VM...")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                logger.debug("Calling VZVirtualMachine.start()...")
                newVM.start { result in
                    self.logger.debug("VM start callback invoked")
                    switch result {
                    case .success:
                        self.logger.debug("VM start callback: success, state=\(newVM.state)")
                        Task {
                            await self.onVMStarted()
                        }
                        continuation.resume()
                    case .failure(let error):
                        self.logger.error("VM start callback: failed - \(error.localizedDescription)")
                        continuation.resume(throwing: NetworkHelperVMError.vmStartFailed(error.localizedDescription))
                    }
                }
                self.logger.debug("VZVirtualMachine.start() called, waiting for callback...")
            }
        } catch {
            logger.error("VM start failed with error: \(error)")
            throw error
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
        logger.debug("Creating VZVirtualMachineConfiguration...")
        let config = VZVirtualMachineConfiguration()

        // CPU: 1 vCPU
        logger.debug("Setting CPU count to 1")
        config.cpuCount = 1

        // Memory: 256MB
        logger.debug("Setting memory size to 256MB")
        config.memorySize = 256 * 1024 * 1024

        // Bootloader (Linux)
        logger.debug("Creating Linux bootloader with kernel: \(kernelPath.path)")
        let bootloader = VZLinuxBootLoader(kernelURL: kernelPath)
        bootloader.commandLine = "console=hvc0 root=/dev/vda rootfstype=ext4 rw init=/sbin/init"
        config.bootLoader = bootloader
        logger.debug("Bootloader configured")

        // Disk (helper VM image)
        logger.debug("Creating disk attachment for: \(vmImagePath.path)")
        do {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: vmImagePath,
                readOnly: false
            )
            let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            config.storageDevices = [disk]
            logger.debug("Disk attachment created successfully")
        } catch {
            logger.error("Failed to create disk attachment: \(error)")
            throw NetworkHelperVMError.vmConfigurationInvalid("Failed to create disk attachment: \(error)")
        }

        // Network (vmnet NAT for internet access)
        logger.debug("Creating NAT network device")
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]
        logger.debug("Network device configured")

        // Serial port for console output
        logger.debug("Creating serial port device")
        let consolePort = VZVirtioConsolePortConfiguration()
        consolePort.isConsole = true

        // Attach console output handler - write to a log file
        let consoleLogPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("helpervm-console.log")

        // Create or truncate console log file
        FileManager.default.createFile(atPath: consoleLogPath.path, contents: nil)
        let consoleLogHandle = try! FileHandle(forWritingTo: consoleLogPath)

        consolePort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: consoleLogHandle
        )

        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = consolePort
        config.consoleDevices = [console]
        logger.debug("Serial console device configured (output to \(consoleLogPath.path))")

        // Socket device (vsock for control API)
        logger.debug("Creating vsock device")
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketDevice]
        logger.debug("Socket device configured")

        // Validate configuration
        logger.debug("Validating VM configuration...")
        do {
            try config.validate()
            logger.debug("VM configuration validated successfully")
        } catch {
            logger.error("VM configuration validation failed: \(error)")
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
