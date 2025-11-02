//===----------------------------------------------------------------------===//
// ReservedVmnetNetwork.swift
// Part of the Arca project - Docker Engine API for Apple Containerization
//
// This file implements a reserved vmnet network for providing NAT networking
// to containers. Based on Apple's ReservedVmnetNetwork implementation.
//===----------------------------------------------------------------------===//

#if os(macOS)

import Foundation
import Logging
import vmnet

/// A reserved vmnet network that provides NAT networking for containers.
/// This creates a persistent vmnet network using Apple's vmnet framework,
/// which provides actual NAT routing and internet access on macOS.
@available(macOS 26, *)
public actor ReservedVmnetNetwork {
    private let logger: Logger
    // `networkRef` isn't used concurrently but needs to be accessed from nonisolated getNetworkRef()
    public nonisolated(unsafe) let networkRef: vmnet_network_ref
    private let subnet: String
    private let gateway: String

    /// Initialize a reserved vmnet network
    /// - Parameters:
    ///   - subnet: The subnet in CIDR format (e.g., "10.88.0.0/24"). Currently ignored - vmnet auto-allocates.
    ///   - logger: Logger for diagnostics
    public init(subnet: String? = nil, logger: Logger) async throws {
        self.logger = logger

        // Create vmnet network configuration in NAT mode
        // VMNET_SHARED_MODE = 1001 (provides NAT routing)
        var configStatus = vmnet_return_t(rawValue: 1000)!  // VMNET_SUCCESS
        guard let mode = vmnet_mode_t(rawValue: 1001),  // VMNET_SHARED_MODE
              let config = vmnet_network_configuration_create(mode, &configStatus) else {
            throw ReservedVmnetNetworkError.configurationCreateFailed
        }
        // Note: CF memory management is automatic in Swift, no manual release needed

        // Disable DHCP - we'll use static IPs
        vmnet_network_configuration_disable_dhcp(config)

        // Create the vmnet network
        var errorCode = vmnet_return_t(rawValue: 1000)!  // VMNET_SUCCESS
        guard let network = vmnet_network_create(config, &errorCode) else {
            throw ReservedVmnetNetworkError.networkCreateFailed(Int32(errorCode.rawValue))
        }

        self.networkRef = network

        // Retrieve the auto-allocated subnet and gateway
        var subnetAddr = in_addr()
        var maskAddr = in_addr()
        vmnet_network_get_ipv4_subnet(network, &subnetAddr, &maskAddr)

        // Convert subnet and mask to readable format
        let subnetValue = UInt32(bigEndian: subnetAddr.s_addr)
        let maskValue = UInt32(bigEndian: maskAddr.s_addr)

        // Calculate gateway as subnet + 1 (Apple's approach)
        let gatewayValue = subnetValue + 1
        let octet1 = UInt8((gatewayValue >> 24) & 0xFF)
        let octet2 = UInt8((gatewayValue >> 16) & 0xFF)
        let octet3 = UInt8((gatewayValue >> 8) & 0xFF)
        let octet4 = UInt8(gatewayValue & 0xFF)
        let allocatedGateway = "\(octet1).\(octet2).\(octet3).\(octet4)"

        // Calculate prefix length from netmask
        let prefixLen = maskValue.nonzeroBitCount

        self.gateway = allocatedGateway
        self.subnet = "\(allocatedGateway)/\(prefixLen)"

        logger.info("Reserved vmnet network created successfully", metadata: [
            "subnet": "\(self.subnet)",
            "gateway": "\(self.gateway)",
            "prefix": "\(prefixLen)"
        ])
    }

    deinit {
        // Note: CF memory management is automatic in Swift for vmnet_network_ref
        // No manual cleanup needed
    }

    /// Get the vmnet network reference for creating network interfaces
    public nonisolated func getNetworkRef() -> vmnet_network_ref {
        return networkRef
    }

    /// Get the gateway IP address
    public nonisolated func getGateway() -> String {
        return gateway
    }

    /// Get the subnet in CIDR format
    public nonisolated func getSubnet() -> String {
        return subnet
    }
}

// MARK: - Helper Functions

/// Calculate gateway address (network address + 1)
private func calculateGateway(network: String) -> String? {
    let octets = network.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4 else { return nil }

    // Add 1 to the last octet for gateway
    var gateway = octets
    if gateway[3] < 255 {
        gateway[3] += 1
    } else {
        return nil  // Can't increment beyond 255
    }

    return gateway.map(String.init).joined(separator: ".")
}

/// Convert prefix length to netmask (e.g., 24 -> "255.255.255.0")
private func prefixLengthToNetmask(_ prefixLen: UInt32) -> String {
    let mask = (0xFFFFFFFF as UInt32) << (32 - prefixLen)
    let octet1 = (mask >> 24) & 0xFF
    let octet2 = (mask >> 16) & 0xFF
    let octet3 = (mask >> 8) & 0xFF
    let octet4 = mask & 0xFF
    return "\(octet1).\(octet2).\(octet3).\(octet4)"
}

/// Convert netmask to prefix length (e.g., "255.255.255.0" -> 24)
private func netmaskToPrefixLength(_ netmask: String) -> UInt32 {
    let octets = netmask.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4 else { return 24 }  // Default to /24 if parsing fails

    let mask = (UInt32(octets[0]) << 24) | (UInt32(octets[1]) << 16) | (UInt32(octets[2]) << 8) | UInt32(octets[3])
    return UInt32(mask.nonzeroBitCount)
}

// MARK: - Errors

public enum ReservedVmnetNetworkError: Error, CustomStringConvertible {
    case configurationCreateFailed
    case invalidSubnet(String)
    case networkCreateFailed(Int32)

    public var description: String {
        switch self {
        case .configurationCreateFailed:
            return "Failed to create vmnet network configuration"
        case .invalidSubnet(let subnet):
            return "Invalid subnet format: \(subnet)"
        case .networkCreateFailed(let code):
            return "Failed to create vmnet network (error code: \(code))"
        }
    }
}

#endif
