import Foundation
import Logging

/// Manages IP address allocation for Docker networks (IPAM)
/// Thread-safe via Swift actor isolation
public actor IPAMAllocator {
    private let logger: Logger

    // Track IP allocations per network
    //  Network ID -> Container ID -> IP Address
    private var allocations: [String: [String: String]] = [:]

    // Track allocated subnets to avoid conflicts
    // Set of subnet strings (e.g., "172.18.0.0/16")
    private var allocatedSubnets: Set<String> = []

    // Next subnet to allocate for custom networks
    // Docker allocates from 172.18.0.0/16 - 172.31.0.0/16
    private var nextSubnetIndex: UInt8 = 18  // Start at 172.18.0.0/16

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Subnet Management

    /// Allocate a new subnet for a custom network
    /// Returns (subnet, gateway) tuple
    public func allocateSubnet() async throws -> (String, String) {
        // Docker allocates custom networks from 172.18.0.0/16 - 172.31.0.0/16
        while nextSubnetIndex <= 31 {
            let subnet = "172.\(nextSubnetIndex).0.0/16"
            let gateway = "172.\(nextSubnetIndex).0.1"

            if !allocatedSubnets.contains(subnet) {
                allocatedSubnets.insert(subnet)
                nextSubnetIndex += 1

                logger.debug("Allocated subnet", metadata: [
                    "subnet": "\(subnet)",
                    "gateway": "\(gateway)"
                ])

                return (subnet, gateway)
            }

            nextSubnetIndex += 1
        }

        throw IPAMError.subnetExhausted
    }

    /// Calculate the default gateway IP for a subnet
    /// Gateway is typically the first usable IP (.1)
    public func calculateGateway(subnet: String) -> String {
        // Parse CIDR notation (e.g., "172.17.0.0/16")
        let components = subnet.split(separator: "/")
        guard components.count == 2,
              let baseIP = components.first else {
            return subnet.replacingOccurrences(of: ".0/", with: ".1/")
                       .replacingOccurrences(of: "/\\d+", with: "", options: .regularExpression)
        }

        // Parse IP octets
        let octets = baseIP.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            // Fallback: replace last .0 with .1
            return subnet.replacingOccurrences(of: ".0/", with: ".1/")
                       .replacingOccurrences(of: "/\\d+", with: "", options: .regularExpression)
        }

        // Gateway is first usable IP (.1 for the last octet)
        let gateway = "\(octets[0]).\(octets[1]).\(octets[2]).1"

        logger.debug("Calculated gateway", metadata: [
            "subnet": "\(subnet)",
            "gateway": "\(gateway)"
        ])

        return gateway
    }

    // MARK: - IP Allocation

    /// Allocate an IP address for a container on a network
    public func allocateIP(
        networkID: String,
        subnet: String,
        preferredIP: String?
    ) async throws -> String {
        logger.debug("Allocating IP", metadata: [
            "network": "\(networkID)",
            "subnet": "\(subnet)",
            "preferred": "\(preferredIP ?? "auto")"
        ])

        // Parse subnet to get base IP and prefix length
        let (baseIP, prefixLength) = try parseSubnet(subnet)

        // If preferred IP is specified, validate and use it
        if let preferred = preferredIP {
            // Validate it's in the subnet
            guard isIPInSubnet(ip: preferred, baseIP: baseIP, prefixLength: prefixLength) else {
                throw IPAMError.ipOutOfRange(preferred, subnet)
            }

            // Validate it's not reserved (network, gateway, broadcast)
            guard !isReservedIP(ip: preferred, baseIP: baseIP, prefixLength: prefixLength) else {
                throw IPAMError.ipReserved(preferred)
            }

            // Check if already allocated
            if let containerAllocations = allocations[networkID],
               containerAllocations.values.contains(preferred) {
                throw IPAMError.ipAlreadyAllocated(preferred)
            }

            return preferred
        }

        // Auto-allocate: find next available IP
        let currentAllocations: [String] = Array(allocations[networkID]?.values ?? [:].values)
        let allocatedIPs = Set(currentAllocations)
        let gateway = calculateGateway(subnet: subnet)

        // Start from .2 (skip .0 network, .1 gateway)
        let startOctet: UInt8 = 2
        let maxHosts = calculateMaxHosts(prefixLength: prefixLength)

        // Parse base IP octets
        let baseOctets = baseIP.split(separator: ".").compactMap { UInt8($0) }
        guard baseOctets.count == 4 else {
            throw IPAMError.invalidSubnet(subnet)
        }

        // For /16 networks, we iterate through the last octet
        // For 172.18.0.0/16, we generate IPs like 172.18.0.2, 172.18.0.3, etc.
        for i in startOctet..<min(startOctet + maxHosts, 254) {
            let ip = "\(baseOctets[0]).\(baseOctets[1]).\(baseOctets[2]).\(i)"

            // Skip if already allocated
            if allocatedIPs.contains(ip) {
                continue
            }

            // Skip reserved IPs
            if ip == gateway || isReservedIP(ip: ip, baseIP: baseIP, prefixLength: prefixLength) {
                continue
            }

            logger.debug("Allocated IP", metadata: [
                "network": "\(networkID)",
                "ip": "\(ip)"
            ])

            return ip
        }

        throw IPAMError.noAvailableIPs(subnet)
    }

    /// Track an allocated IP for a container
    public func trackAllocation(networkID: String, containerID: String, ip: String) {
        if allocations[networkID] == nil {
            allocations[networkID] = [:]
        }
        allocations[networkID]?[containerID] = ip

        logger.debug("Tracked IP allocation", metadata: [
            "network": "\(networkID)",
            "container": "\(containerID)",
            "ip": "\(ip)"
        ])
    }

    /// Release an IP address when a container disconnects
    public func releaseIP(networkID: String, containerID: String) async {
        if let ip = allocations[networkID]?[containerID] {
            allocations[networkID]?.removeValue(forKey: containerID)

            logger.debug("Released IP", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "ip": "\(ip)"
            ])
        }
    }

    /// Get allocated IP for a container on a network
    public func getAllocatedIP(networkID: String, containerID: String) -> String? {
        return allocations[networkID]?[containerID]
    }

    // MARK: - Helper Methods

    /// Parse subnet CIDR notation into base IP and prefix length
    /// Example: "172.17.0.0/16" -> ("172.17.0.0", 16)
    private func parseSubnet(_ subnet: String) throws -> (String, Int) {
        let components = subnet.split(separator: "/")
        guard components.count == 2,
              let baseIP = components.first,
              let prefixLength = Int(components.last!) else {
            throw IPAMError.invalidSubnet(subnet)
        }

        return (String(baseIP), prefixLength)
    }

    /// Check if an IP is within a subnet
    private func isIPInSubnet(ip: String, baseIP: String, prefixLength: Int) -> Bool {
        // Simple check: for /16, first two octets must match
        // For /24, first three octets must match
        let ipOctets = ip.split(separator: ".").compactMap { Int($0) }
        let baseOctets = baseIP.split(separator: ".").compactMap { Int($0) }

        guard ipOctets.count == 4 && baseOctets.count == 4 else {
            return false
        }

        // Check octets based on prefix length
        let octetsToMatch = prefixLength / 8
        for i in 0..<octetsToMatch {
            if ipOctets[i] != baseOctets[i] {
                return false
            }
        }

        return true
    }

    /// Check if an IP is reserved (network address, gateway, broadcast)
    private func isReservedIP(ip: String, baseIP: String, prefixLength: Int) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return true
        }

        // Reserve .0 (network), .1 (gateway), .255 (broadcast for /24 and smaller)
        let lastOctet = octets[3]
        if lastOctet == 0 || lastOctet == 1 || lastOctet == 255 {
            return true
        }

        return false
    }

    /// Calculate maximum number of hosts for a prefix length
    private func calculateMaxHosts(prefixLength: Int) -> UInt8 {
        let hostBits = 32 - prefixLength
        let maxHosts = (1 << hostBits) - 2  // -2 for network and broadcast

        // Cap at 252 to avoid going past .254
        return UInt8(min(maxHosts, 252))
    }
}

// MARK: - Errors

public enum IPAMError: Error, CustomStringConvertible {
    case invalidSubnet(String)
    case subnetExhausted
    case ipOutOfRange(String, String)
    case ipReserved(String)
    case ipAlreadyAllocated(String)
    case noAvailableIPs(String)

    public var description: String {
        switch self {
        case .invalidSubnet(let subnet):
            return "Invalid subnet format: \(subnet)"
        case .subnetExhausted:
            return "No more subnets available for allocation (172.18.0.0/16 - 172.31.0.0/16 exhausted)"
        case .ipOutOfRange(let ip, let subnet):
            return "IP \(ip) is not in subnet \(subnet)"
        case .ipReserved(let ip):
            return "IP \(ip) is reserved (network address, gateway, or broadcast)"
        case .ipAlreadyAllocated(let ip):
            return "IP \(ip) is already allocated to another container"
        case .noAvailableIPs(let subnet):
            return "No available IPs in subnet \(subnet)"
        }
    }
}
