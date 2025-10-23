// Arca TAP Forwarder
// Forwards Ethernet frames between TAP device and vsock for container networking
// Part of the Arca project - Docker Engine API on Apple's Containerization framework

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

// MARK: - Linux Structures

struct ifreq {
    var ifr_name: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                   Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var ifr_ifru: ifr_ifru_union = ifr_ifru_union()
}

struct ifr_ifru_union {
    var ifru_addr: sockaddr = sockaddr()
}

// MARK: - TAPForwarder

@main
struct TAPForwarder {
    enum TAPError: Error, CustomStringConvertible {
        case missingConfiguration(String)
        case openFailed(Int32)
        case ioctlFailed(String, Int32)
        case socketFailed(Int32)
        case connectFailed(Int32)
        case readFailed(Int32)
        case writeFailed(Int32)

        var description: String {
            switch self {
            case .missingConfiguration(let msg):
                return "Missing configuration: \(msg)"
            case .openFailed(let err):
                return "Failed to open /dev/net/tun: errno \(err)"
            case .ioctlFailed(let op, let err):
                return "ioctl \(op) failed: errno \(err)"
            case .socketFailed(let err):
                return "Socket creation failed: errno \(err)"
            case .connectFailed(let err):
                return "vsock connect failed: errno \(err)"
            case .readFailed(let err):
                return "Read failed: errno \(err)"
            case .writeFailed(let err):
                return "Write failed: errno \(err)"
            }
        }
    }

    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        var logger = Logger(label: "arca-tap-forwarder")
        logger.logLevel = .debug

        logger.info("Arca TAP Forwarder starting...")

        // Read configuration from environment
        guard let portStr = ProcessInfo.processInfo.environment["ARCA_NETWORK_PORT"],
              let vsockPort = UInt32(portStr) else {
            throw TAPError.missingConfiguration("ARCA_NETWORK_PORT not set")
        }

        guard let ipAddress = ProcessInfo.processInfo.environment["ARCA_NETWORK_IP"] else {
            throw TAPError.missingConfiguration("ARCA_NETWORK_IP not set")
        }

        guard let gateway = ProcessInfo.processInfo.environment["ARCA_NETWORK_GATEWAY"] else {
            throw TAPError.missingConfiguration("ARCA_NETWORK_GATEWAY not set")
        }

        logger.info("Configuration", metadata: [
            "vsockPort": "\(vsockPort)",
            "ip": "\(ipAddress)",
            "gateway": "\(gateway)"
        ])

        // Create and configure TAP device
        let tapFD = try createTAPDevice(name: "eth0", logger: logger)
        logger.info("Created TAP device", metadata: ["fd": "\(tapFD)"])

        try configureTAPDevice(name: "eth0", ip: ipAddress, gateway: gateway, logger: logger)
        logger.info("Configured TAP device")

        // Connect to host via vsock (CID 2 = host)
        let vsockFD = try connectVsock(port: vsockPort, logger: logger)
        logger.info("Connected to host via vsock", metadata: ["port": "\(vsockPort)"])

        // Start bidirectional forwarding
        logger.info("Starting packet forwarding...")

        // Create loggers for each task to avoid data races
        let tapToVsockLogger = Logger(label: "tap-to-vsock")
        let vsockToTAPLogger = Logger(label: "vsock-to-tap")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await forwardTAPToVsock(tapFD: tapFD, vsockFD: vsockFD, logger: tapToVsockLogger)
            }

            group.addTask {
                try await forwardVsockToTAP(vsockFD: vsockFD, tapFD: tapFD, logger: vsockToTAPLogger)
            }

            // Wait for either direction to fail
            try await group.next()

            // Cancel remaining tasks
            group.cancelAll()
        }
    }

    // MARK: - TAP Device Creation

    static func createTAPDevice(name: String, logger: Logger) throws -> Int32 {
        let fd = open("/dev/net/tun", O_RDWR)
        guard fd >= 0 else {
            let err = errno
            logger.error("Failed to open /dev/net/tun", metadata: ["errno": "\(err)"])
            throw TAPError.openFailed(err)
        }

        var ifr = ifreq()

        // Copy interface name into ifr_name
        let nameBytes = Array(name.utf8)
        withUnsafeMutableBytes(of: &ifr.ifr_name) { ptr in
            let copyLen = min(nameBytes.count, ptr.count - 1)
            for i in 0..<copyLen {
                ptr[i] = nameBytes[i]
            }
        }

        // Set TAP mode with no protocol info
        var flags = Int16(IFF_TAP | IFF_NO_PI)
        memcpy(&ifr.ifr_ifru, &flags, MemoryLayout<Int16>.size)

        guard ioctl(fd, TUNSETIFF, &ifr) >= 0 else {
            let err = errno
            close(fd)
            logger.error("TUNSETIFF failed", metadata: ["errno": "\(err)"])
            throw TAPError.ioctlFailed("TUNSETIFF", err)
        }

        return fd
    }

    static func configureTAPDevice(name: String, ip: String, gateway: String, logger: Logger) throws {
        let sockfd = socket(AF_INET, Int32(SOCK_DGRAM), 0)
        guard sockfd >= 0 else {
            throw TAPError.socketFailed(errno)
        }
        defer { close(sockfd) }

        var ifr = ifreq()

        // Copy interface name
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
            throw TAPError.ioctlFailed("SIOCSIFADDR", errno)
        }

        // Set netmask (/24 = 255.255.255.0)
        var netmask = sockaddr_in()
        netmask.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "255.255.255.0", &netmask.sin_addr)

        withUnsafeBytes(of: &netmask) { netmaskPtr in
            withUnsafeMutableBytes(of: &ifr.ifr_ifru.ifru_addr) { ifrPtr in
                ifrPtr.copyBytes(from: netmaskPtr.prefix(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard ioctl(sockfd, SIOCSIFNETMASK, &ifr) >= 0 else {
            throw TAPError.ioctlFailed("SIOCSIFNETMASK", errno)
        }

        // Bring interface up
        guard ioctl(sockfd, SIOCGIFFLAGS, &ifr) >= 0 else {
            throw TAPError.ioctlFailed("SIOCGIFFLAGS", errno)
        }

        var flags = Int16(IFF_UP | IFF_RUNNING)
        memcpy(&ifr.ifr_ifru, &flags, MemoryLayout<Int16>.size)

        guard ioctl(sockfd, SIOCSIFFLAGS, &ifr) >= 0 else {
            throw TAPError.ioctlFailed("SIOCSIFFLAGS", errno)
        }

        logger.info("TAP device configured and up")

        // Add default route
        let routeResult = system("ip route add default via \(gateway)")
        if routeResult == 0 {
            logger.info("Default route configured", metadata: ["gateway": "\(gateway)"])
        } else {
            logger.warning("Failed to add default route", metadata: ["exitCode": "\(routeResult)"])
        }
    }

    // MARK: - vsock Connection

    static func connectVsock(port: UInt32, logger: Logger) throws -> Int32 {
        // Create vsock socket
        let sockfd = socket(AF_VSOCK, Int32(SOCK_STREAM), 0)
        guard sockfd >= 0 else {
            throw TAPError.socketFailed(errno)
        }

        // Connect to host (CID 2)
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
            logger.error("vsock connect failed", metadata: ["errno": "\(err)"])
            throw TAPError.connectFailed(err)
        }

        return sockfd
    }

    // MARK: - Packet Forwarding

    static func forwardTAPToVsock(tapFD: Int32, vsockFD: Int32, logger: Logger) async throws {
        logger.debug("TAP->vsock forwarding started")

        var buffer = [UInt8](repeating: 0, count: 65536)
        var packetCount = 0

        while true {
            let bytesRead = read(tapFD, &buffer, buffer.count)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                logger.error("TAP read error", metadata: ["errno": "\(err)"])
                throw TAPError.readFailed(err)
            }

            if bytesRead == 0 {
                logger.warning("TAP device closed")
                break
            }

            // Write to vsock
            var totalWritten = 0
            while totalWritten < bytesRead {
                let written = write(vsockFD, &buffer[totalWritten], bytesRead - totalWritten)

                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    logger.error("vsock write error", metadata: ["errno": "\(err)"])
                    throw TAPError.writeFailed(err)
                }

                totalWritten += written
            }

            packetCount += 1
            if packetCount % 100 == 0 {
                logger.trace("TAP->vsock packets forwarded", metadata: ["count": "\(packetCount)"])
            }
        }
    }

    static func forwardVsockToTAP(vsockFD: Int32, tapFD: Int32, logger: Logger) async throws {
        logger.debug("vsock->TAP forwarding started")

        var buffer = [UInt8](repeating: 0, count: 65536)
        var packetCount = 0

        while true {
            let bytesRead = read(vsockFD, &buffer, buffer.count)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                logger.error("vsock read error", metadata: ["errno": "\(err)"])
                throw TAPError.readFailed(err)
            }

            if bytesRead == 0 {
                logger.warning("vsock connection closed")
                break
            }

            // Write to TAP
            var totalWritten = 0
            while totalWritten < bytesRead {
                let written = write(tapFD, &buffer[totalWritten], bytesRead - totalWritten)

                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    logger.error("TAP write error", metadata: ["errno": "\(err)"])
                    throw TAPError.writeFailed(err)
                }

                totalWritten += written
            }

            packetCount += 1
            if packetCount % 100 == 0 {
                logger.trace("vsock->TAP packets forwarded", metadata: ["count": "\(packetCount)"])
            }
        }
    }
}

// MARK: - Linux vsock Structures

#if os(Linux)
let AF_VSOCK: Int32 = 40

struct sockaddr_vm {
    var svm_family: sa_family_t = 0
    var svm_reserved1: UInt16 = 0
    var svm_port: UInt32 = 0
    var svm_cid: UInt32 = 0
    var svm_flags: UInt8 = 0
    var svm_zero: (UInt8, UInt8, UInt8) = (0, 0, 0)
}
#endif

#else
@main
struct TAPForwarder {
    static func main() {
        print("arca-tap-forwarder only runs on Linux")
        exit(1)
    }
}
#endif
