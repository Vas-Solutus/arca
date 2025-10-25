import Foundation
import Containerization

/// Wrapper class for VmnetNetwork to enable shared mutable state across actors
///
/// VmnetNetwork is a struct with mutable allocator state. When copied, each copy
/// gets its own independent allocator, causing IP allocation conflicts where
/// multiple VMs receive the same IP address.
///
/// This class wrapper ensures all code (helper VM, all containers) shares the
/// same VmnetNetwork instance with synchronized access to the allocator.
public final class SharedVmnetNetwork: @unchecked Sendable {
    private var network: Containerization.ContainerManager.VmnetNetwork
    private let lock = NSLock()

    public init(subnet: String) throws {
        self.network = try Containerization.ContainerManager.VmnetNetwork(subnet: subnet)
    }

    /// Create a new network interface for the given container ID
    /// Thread-safe: Uses lock to synchronize access to the allocator
    public func createInterface(_ id: String) throws -> (any Containerization.Interface)? {
        lock.lock()
        defer { lock.unlock() }
        return try network.create(id)
    }

    /// Release a network interface for the given container ID
    /// Thread-safe: Uses lock to synchronize access to the allocator
    public func releaseInterface(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try network.release(id)
    }

    /// The IPv4 subnet of this network
    public var subnet: String {
        network.subnet.description
    }

    /// The gateway address of this network
    public var gateway: String {
        network.gateway.description
    }
}
