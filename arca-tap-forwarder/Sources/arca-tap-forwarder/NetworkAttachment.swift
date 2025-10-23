// NetworkAttachment - Manages a single TAP device and its packet forwarding
// Each attachment represents one network interface (eth0, eth1, etc.)

import Foundation
import Logging

#if os(Linux)
import Musl

// MARK: - Linux Constants

private let IFF_TAP: Int32 = 0x0002
private let IFF_NO_PI: Int32 = 0x1000
private let IFF_UP: Int32 = 0x1
private let IFF_RUNNING: Int32 = 0x40
private let TUNSETIFF: UInt = 0x400454ca
private let SIOCGIFFLAGS: UInt = 0x8913
private let SIOCSIFFLAGS: UInt = 0x8914
private let SIOCSIFADDR: UInt = 0x8916
private let SIOCSIFNETMASK: UInt = 0x891c
private let SIOCGIFHWADDR: UInt = 0x8927
private let AF_VSOCK: Int32 = 40

// MARK: - Linux Structures

struct ifreq {
    var ifr_name: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                   Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var ifr_ifru: ifr_ifru_union = ifr_ifru_union()
}

struct ifr_ifru_union {
    var ifru_addr: sockaddr = sockaddr()
}

struct sockaddr_vm {
    var svm_family: sa_family_t = 0
    var svm_reserved1: UInt16 = 0
    var svm_port: UInt32 = 0
    var svm_cid: UInt32 = 0
    var svm_flags: UInt8 = 0
    var svm_zero: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

// MARK: - NetworkAttachment Actor

/// Manages a single network attachment (TAP device + vsock forwarding)
actor NetworkAttachment {
    let device: String
    let vsockPort: UInt32
    let ipAddress: String
    let gateway: String
    private let netmask: UInt32
    private let logger: Logger

    private var tapFD: Int32?
    private var vsockFD: Int32?
    private var forwardTask: Task<Void, Never>?
    private var isRunning = false

    // Statistics
    private var packetsSent: UInt64 = 0
    private var packetsReceived: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var sendErrors: UInt64 = 0
    private var receiveErrors: UInt64 = 0

    enum NetworkError: Error, CustomStringConvertible {
        case tapCreationFailed(Int32)
        case ioctlFailed(String, Int32)
        case vsockConnectionFailed(Int32)
        case alreadyRunning
        case notRunning

        var description: String {
            switch self {
            case .tapCreationFailed(let errno):
                return "Failed to create TAP device: errno \(errno)"
            case .ioctlFailed(let op, let errno):
                return "ioctl \(op) failed: errno \(errno)"
            case .vsockConnectionFailed(let errno):
                return "vsock connection failed: errno \(errno)"
            case .alreadyRunning:
                return "Network attachment already running"
            case .notRunning:
                return "Network attachment not running"
            }
        }
    }

    init(
        device: String,
        vsockPort: UInt32,
        ipAddress: String,
        gateway: String,
        netmask: UInt32,
        logger: Logger
    ) async throws {
        self.device = device
        self.vsockPort = vsockPort
        self.ipAddress = ipAddress
        self.gateway = gateway
        self.netmask = netmask
        self.logger = logger

        // Create TAP device
        let fd = try Self.createTAPDevice(name: device, logger: logger)
        self.tapFD = fd

        // Configure IP address
        try Self.configureTAPDevice(
            name: device,
            ip: ipAddress,
            gateway: gateway,
            netmask: netmask,
            logger: logger
        )

        // Connect to host via vsock
        let vsockFD = try Self.connectVsock(port: vsockPort, logger: logger)
        self.vsockFD = vsockFD

        logger.info("NetworkAttachment created", metadata: [
            "device": "\(device)",
            "tapFD": "\(fd)",
            "vsockFD": "\(vsockFD)"
        ])
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else {
            logger.warning("Attachment already running", metadata: ["device": "\(device)"])
            return
        }

        guard let tapFD = tapFD, let vsockFD = vsockFD else {
            logger.error("Cannot start - missing file descriptors")
            return
        }

        isRunning = true
        logger.info("Starting packet forwarding", metadata: ["device": "\(device)"])

        // Start bidirectional forwarding
        forwardTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.forwardTAPToVsock(tapFD: tapFD, vsockFD: vsockFD)
                }

                group.addTask {
                    await self.forwardVsockToTAP(vsockFD: vsockFD, tapFD: tapFD)
                }

                // Wait for both to complete (or until cancelled)
                await group.waitForAll()
            }
        }
    }

    func stop() async {
        guard isRunning else { return }

        logger.info("Stopping network attachment", metadata: ["device": "\(device)"])

        isRunning = false
        forwardTask?.cancel()
        forwardTask = nil

        if let fd = tapFD {
            close(fd)
            tapFD = nil
        }

        if let fd = vsockFD {
            close(fd)
            vsockFD = nil
        }

        logger.info("Network attachment stopped", metadata: ["device": "\(device)"])
    }

    // MARK: - Statistics

    func getStats() -> Arca_Tapforwarder_V1_PacketStats {
        var stats = Arca_Tapforwarder_V1_PacketStats()
        stats.packetsSent = packetsSent
        stats.packetsReceived = packetsReceived
        stats.bytesSent = bytesSent
        stats.bytesReceived = bytesReceived
        stats.sendErrors = sendErrors
        stats.receiveErrors = receiveErrors
        return stats
    }

    func getMACAddress() throws -> String {
        guard let tapFD = tapFD else {
            throw NetworkError.notRunning
        }

        let sockfd = socket(AF_INET, Int32(SOCK_DGRAM), 0)
        guard sockfd >= 0 else {
            throw NetworkError.ioctlFailed("socket", errno)
        }
        defer { close(sockfd) }

        var ifr = ifreq()
        let nameBytes = Array(device.utf8)
        withUnsafeMutableBytes(of: &ifr.ifr_name) { ptr in
            let copyLen = min(nameBytes.count, ptr.count - 1)
            for i in 0..<copyLen {
                ptr[i] = nameBytes[i]
            }
        }

        guard ioctl(sockfd, SIOCGIFHWADDR, &ifr) >= 0 else {
            throw NetworkError.ioctlFailed("SIOCGIFHWADDR", errno)
        }

        // Extract MAC address from ifr_hwaddr
        let macBytes = withUnsafeBytes(of: &ifr.ifr_ifru.ifru_addr.sa_data) { ptr in
            Array(ptr.prefix(6))
        }

        return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - TAP Device Creation

    private static func createTAPDevice(name: String, logger: Logger) throws -> Int32 {
        let fd = open("/dev/net/tun", O_RDWR)
        guard fd >= 0 else {
            let err = errno
            logger.error("Failed to open /dev/net/tun", metadata: ["errno": "\(err)"])
            throw NetworkError.tapCreationFailed(err)
        }

        var ifr = ifreq()
        let nameBytes = Array(name.utf8)
        withUnsafeMutableBytes(of: &ifr.ifr_name) { ptr in
            let copyLen = min(nameBytes.count, ptr.count - 1)
            for i in 0..<copyLen {
                ptr[i] = nameBytes[i]
            }
        }

        var flags = Int16(IFF_TAP | IFF_NO_PI)
        memcpy(&ifr.ifr_ifru, &flags, MemoryLayout<Int16>.size)

        guard ioctl(fd, TUNSETIFF, &ifr) >= 0 else {
            let err = errno
            close(fd)
            logger.error("TUNSETIFF failed", metadata: ["errno": "\(err)"])
            throw NetworkError.ioctlFailed("TUNSETIFF", err)
        }

        logger.debug("Created TAP device", metadata: ["name": "\(name)", "fd": "\(fd)"])
        return fd
    }

    private static func configureTAPDevice(
        name: String,
        ip: String,
        gateway: String,
        netmask: UInt32,
        logger: Logger
    ) throws {
        let sockfd = socket(AF_INET, Int32(SOCK_DGRAM), 0)
        guard sockfd >= 0 else {
            throw NetworkError.ioctlFailed("socket", errno)
        }
        defer { close(sockfd) }

        var ifr = ifreq()
        let nameBytes = Array(name.utf8)
        withUnsafeMutableBytes(of: &ifr.ifr_name) { ptr in
            let copyLen = min(nameBytes.count, ptr.count - 1)
            for i in 0..<copyLen {
                ptr[i] = nameBytes[i]
            }
        }

        // Set IP address
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)

        withUnsafeBytes(of: &addr) { addrPtr in
            withUnsafeMutableBytes(of: &ifr.ifr_ifru.ifru_addr) { ifrPtr in
                ifrPtr.copyBytes(from: addrPtr.prefix(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard ioctl(sockfd, SIOCSIFADDR, &ifr) >= 0 else {
            throw NetworkError.ioctlFailed("SIOCSIFADDR", errno)
        }

        // Set netmask
        var netmaskAddr = sockaddr_in()
        netmaskAddr.sin_family = sa_family_t(AF_INET)
        let netmaskStr = Self.cidrToNetmask(netmask)
        inet_pton(AF_INET, netmaskStr, &netmaskAddr.sin_addr)

        withUnsafeBytes(of: &netmaskAddr) { netmaskPtr in
            withUnsafeMutableBytes(of: &ifr.ifr_ifru.ifru_addr) { ifrPtr in
                ifrPtr.copyBytes(from: netmaskPtr.prefix(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard ioctl(sockfd, SIOCSIFNETMASK, &ifr) >= 0 else {
            throw NetworkError.ioctlFailed("SIOCSIFNETMASK", errno)
        }

        // Bring interface up
        guard ioctl(sockfd, SIOCGIFFLAGS, &ifr) >= 0 else {
            throw NetworkError.ioctlFailed("SIOCGIFFLAGS", errno)
        }

        var flags = Int16(IFF_UP | IFF_RUNNING)
        memcpy(&ifr.ifr_ifru, &flags, MemoryLayout<Int16>.size)

        guard ioctl(sockfd, SIOCSIFFLAGS, &ifr) >= 0 else {
            throw NetworkError.ioctlFailed("SIOCSIFFLAGS", errno)
        }

        // Add default route
        let routeResult = system("ip route add default via \(gateway)")
        if routeResult == 0 {
            logger.info("Default route configured", metadata: ["gateway": "\(gateway)"])
        } else {
            logger.warning("Failed to add default route", metadata: ["exitCode": "\(routeResult)"])
        }

        logger.info("TAP device configured", metadata: [
            "name": "\(name)",
            "ip": "\(ip)",
            "gateway": "\(gateway)"
        ])
    }

    private static func cidrToNetmask(_ cidr: UInt32) -> String {
        let mask = (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF
        let a = UInt8((mask >> 24) & 0xFF)
        let b = UInt8((mask >> 16) & 0xFF)
        let c = UInt8((mask >> 8) & 0xFF)
        let d = UInt8(mask & 0xFF)
        return "\(a).\(b).\(c).\(d)"
    }

    // MARK: - vsock Connection

    private static func connectVsock(port: UInt32, logger: Logger) throws -> Int32 {
        let sockfd = socket(AF_VSOCK, Int32(SOCK_STREAM), 0)
        guard sockfd >= 0 else {
            throw NetworkError.ioctlFailed("socket", errno)
        }

        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_cid = 2  // Host CID
        addr.svm_port = port

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard result >= 0 else {
            let err = errno
            close(sockfd)
            logger.error("vsock connect failed", metadata: ["errno": "\(err)", "port": "\(port)"])
            throw NetworkError.vsockConnectionFailed(err)
        }

        logger.debug("Connected to host via vsock", metadata: ["port": "\(port)", "fd": "\(sockfd)"])
        return sockfd
    }

    // MARK: - Packet Forwarding

    private func forwardTAPToVsock(tapFD: Int32, vsockFD: Int32) async {
        let forwarderLogger = Logger(label: "tap-to-vsock-\(device)")
        forwarderLogger.debug("TAP->vsock forwarding started")

        var buffer = [UInt8](repeating: 0, count: 65536)

        while !Task.isCancelled && isRunning {
            let bytesRead = read(tapFD, &buffer, buffer.count)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                forwarderLogger.error("TAP read error", metadata: ["errno": "\(err)"])
                await recordSendError()
                break
            }

            if bytesRead == 0 {
                forwarderLogger.warning("TAP device closed")
                break
            }

            // Write to vsock
            var totalWritten = 0
            while totalWritten < bytesRead {
                let written = write(vsockFD, &buffer[totalWritten], bytesRead - totalWritten)

                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    forwarderLogger.error("vsock write error", metadata: ["errno": "\(err)"])
                    await recordSendError()
                    break
                }

                totalWritten += written
            }

            if totalWritten == bytesRead {
                await recordPacketSent(bytes: UInt64(bytesRead))
            }
        }

        forwarderLogger.info("TAP->vsock forwarding stopped")
    }

    private func forwardVsockToTAP(vsockFD: Int32, tapFD: Int32) async {
        let forwarderLogger = Logger(label: "vsock-to-tap-\(device)")
        forwarderLogger.debug("vsock->TAP forwarding started")

        var buffer = [UInt8](repeating: 0, count: 65536)

        while !Task.isCancelled && isRunning {
            let bytesRead = read(vsockFD, &buffer, buffer.count)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                forwarderLogger.error("vsock read error", metadata: ["errno": "\(err)"])
                await recordReceiveError()
                break
            }

            if bytesRead == 0 {
                forwarderLogger.warning("vsock connection closed")
                break
            }

            // Write to TAP
            var totalWritten = 0
            while totalWritten < bytesRead {
                let written = write(tapFD, &buffer[totalWritten], bytesRead - totalWritten)

                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    forwarderLogger.error("TAP write error", metadata: ["errno": "\(err)"])
                    await recordReceiveError()
                    break
                }

                totalWritten += written
            }

            if totalWritten == bytesRead {
                await recordPacketReceived(bytes: UInt64(bytesRead))
            }
        }

        forwarderLogger.info("vsock->TAP forwarding stopped")
    }

    // MARK: - Statistics Tracking

    private func recordPacketSent(bytes: UInt64) {
        packetsSent += 1
        bytesSent += bytes
    }

    private func recordPacketReceived(bytes: UInt64) {
        packetsReceived += 1
        bytesReceived += bytes
    }

    private func recordSendError() {
        sendErrors += 1
    }

    private func recordReceiveError() {
        receiveErrors += 1
    }
}

#endif
