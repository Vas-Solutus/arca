// PortAllocator - Manages vsock port allocation for network attachments
// Ensures unique ports for each container-network connection

import Foundation

/// Thread-safe port allocator for vsock connections
actor PortAllocator {
    private let basePort: UInt32
    private var allocatedPorts: Set<UInt32> = []
    private var nextPort: UInt32

    enum AllocationError: Error, CustomStringConvertible {
        case exhausted

        var description: String {
            switch self {
            case .exhausted: return "Port allocation exhausted"
            }
        }
    }

    init(basePort: UInt32) {
        self.basePort = basePort
        self.nextPort = basePort
    }

    /// Allocate a new port
    func allocate() throws -> UInt32 {
        // Find next available port
        while allocatedPorts.contains(nextPort) {
            nextPort += 1

            // Prevent infinite loop (limit to 10000 ports)
            if nextPort > basePort + 10000 {
                throw AllocationError.exhausted
            }
        }

        let port = nextPort
        allocatedPorts.insert(port)
        nextPort += 1

        return port
    }

    /// Release a port back to the pool
    func release(_ port: UInt32) {
        allocatedPorts.remove(port)
    }

    /// Get number of allocated ports
    func allocatedCount() -> Int {
        return allocatedPorts.count
    }
}
