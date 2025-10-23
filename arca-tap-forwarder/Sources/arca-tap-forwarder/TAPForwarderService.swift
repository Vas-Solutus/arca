// Arca TAP Forwarder gRPC Service Implementation
// Manages TAP network devices and packet forwarding on-demand

import Foundation
import Logging
import GRPC
import NIOCore
import NIOPosix

#if os(Linux)
import Musl

/// Main gRPC service for managing TAP network devices
actor TAPForwarderService: Arca_Tapforwarder_V1_TAPForwarderAsyncProvider {
    private let logger: Logger
    private var networks: [String: NetworkAttachment] = [:]
    private let startTime: Date

    init(logger: Logger) {
        self.logger = logger
        self.startTime = Date()
    }

    // MARK: - gRPC Service Methods

    func attachNetwork(
        request: Arca_Tapforwarder_V1_AttachNetworkRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_AttachNetworkResponse {
        logger.info("AttachNetwork RPC called", metadata: [
            "device": "\(request.device)",
            "vsockPort": "\(request.vsockPort)",
            "ip": "\(request.ipAddress)"
        ])

        // Check if device already exists
        guard networks[request.device] == nil else {
            logger.warning("Device already attached", metadata: ["device": "\(request.device)"])
            var response = Arca_Tapforwarder_V1_AttachNetworkResponse()
            response.success = false
            response.error = "Device \(request.device) already exists"
            return response
        }

        do {
            // Create network attachment
            let attachment = try await NetworkAttachment(
                device: request.device,
                vsockPort: request.vsockPort,
                ipAddress: request.ipAddress,
                gateway: request.gateway,
                netmask: request.netmask == 0 ? 24 : request.netmask,
                logger: logger
            )

            // Start packet forwarding
            await attachment.start()

            // Store attachment
            networks[request.device] = attachment

            // Get MAC address
            let macAddress = try await attachment.getMACAddress()

            logger.info("Network attached successfully", metadata: [
                "device": "\(request.device)",
                "mac": "\(macAddress)"
            ])

            var response = Arca_Tapforwarder_V1_AttachNetworkResponse()
            response.success = true
            response.macAddress = macAddress
            return response
        } catch {
            logger.error("Failed to attach network", metadata: [
                "device": "\(request.device)",
                "error": "\(error)"
            ])

            var response = Arca_Tapforwarder_V1_AttachNetworkResponse()
            response.success = false
            response.error = error.localizedDescription
            return response
        }
    }

    func detachNetwork(
        request: Arca_Tapforwarder_V1_DetachNetworkRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_DetachNetworkResponse {
        logger.info("DetachNetwork RPC called", metadata: ["device": "\(request.device)"])

        guard let attachment = networks.removeValue(forKey: request.device) else {
            logger.warning("Device not found", metadata: ["device": "\(request.device)"])
            var response = Arca_Tapforwarder_V1_DetachNetworkResponse()
            response.success = false
            response.error = "Device \(request.device) not found"
            return response
        }

        // Stop forwarding and cleanup
        await attachment.stop()

        logger.info("Network detached successfully", metadata: ["device": "\(request.device)"])

        var response = Arca_Tapforwarder_V1_DetachNetworkResponse()
        response.success = true
        return response
    }

    func listNetworks(
        request: Arca_Tapforwarder_V1_ListNetworksRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_ListNetworksResponse {
        logger.debug("ListNetworks RPC called")

        var response = Arca_Tapforwarder_V1_ListNetworksResponse()

        for (device, attachment) in networks {
            var info = Arca_Tapforwarder_V1_NetworkInfo()
            info.device = device
            info.ipAddress = await attachment.ipAddress
            info.gateway = await attachment.gateway
            info.vsockPort = await attachment.vsockPort
            info.macAddress = (try? await attachment.getMACAddress()) ?? "unknown"
            info.stats = await attachment.getStats()

            response.networks.append(info)
        }

        return response
    }

    func getStatus(
        request: Arca_Tapforwarder_V1_GetStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_GetStatusResponse {
        logger.debug("GetStatus RPC called")

        var response = Arca_Tapforwarder_V1_GetStatusResponse()
        response.version = "1.0.0"
        response.activeNetworks = UInt32(networks.count)
        response.uptimeSeconds = UInt64(Date().timeIntervalSince(startTime))

        // Calculate total stats
        var totalStats = Arca_Tapforwarder_V1_PacketStats()
        for attachment in networks.values {
            let stats = await attachment.getStats()
            totalStats.packetsSent += stats.packetsSent
            totalStats.packetsReceived += stats.packetsReceived
            totalStats.bytesSent += stats.bytesSent
            totalStats.bytesReceived += stats.bytesReceived
            totalStats.sendErrors += stats.sendErrors
            totalStats.receiveErrors += stats.receiveErrors
        }
        response.totalStats = totalStats

        return response
    }
}

#else
// Dummy implementation for macOS (not used)
actor TAPForwarderService: Arca_Tapforwarder_V1_TAPForwarderAsyncProvider {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func attachNetwork(
        request: Arca_Tapforwarder_V1_AttachNetworkRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_AttachNetworkResponse {
        fatalError("TAPForwarder only runs on Linux")
    }

    func detachNetwork(
        request: Arca_Tapforwarder_V1_DetachNetworkRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_DetachNetworkResponse {
        fatalError("TAPForwarder only runs on Linux")
    }

    func listNetworks(
        request: Arca_Tapforwarder_V1_ListNetworksRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_ListNetworksResponse {
        fatalError("TAPForwarder only runs on Linux")
    }

    func getStatus(
        request: Arca_Tapforwarder_V1_GetStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Tapforwarder_V1_GetStatusResponse {
        fatalError("TAPForwarder only runs on Linux")
    }
}
#endif
