import Foundation

/// Response for container stats (simplified Docker-compatible format)
public struct ContainerStatsResponse: Codable {
    public let id: String
    public let name: String
    public let read: String  // RFC 3339 timestamp
    public let preread: String  // RFC 3339 timestamp
    public let pidsStats: PidsStats?
    public let cpuStats: CPUStats
    public let precpuStats: CPUStats
    public let memoryStats: MemoryStats
    public let blkioStats: BlkioStats?
    public let networks: [String: NetworkStats]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case read
        case preread
        case pidsStats = "pids_stats"
        case cpuStats = "cpu_stats"
        case precpuStats = "precpu_stats"
        case memoryStats = "memory_stats"
        case blkioStats = "blkio_stats"
        case networks
    }

    public init(
        id: String,
        name: String,
        read: String,
        preread: String,
        pidsStats: PidsStats?,
        cpuStats: CPUStats,
        precpuStats: CPUStats,
        memoryStats: MemoryStats,
        blkioStats: BlkioStats?,
        networks: [String: NetworkStats]?
    ) {
        self.id = id
        self.name = name
        self.read = read
        self.preread = preread
        self.pidsStats = pidsStats
        self.cpuStats = cpuStats
        self.precpuStats = precpuStats
        self.memoryStats = memoryStats
        self.blkioStats = blkioStats
        self.networks = networks
    }
}

/// PID statistics
public struct PidsStats: Codable {
    public let current: UInt64?
    public let limit: UInt64?

    public init(current: UInt64?, limit: UInt64?) {
        self.current = current
        self.limit = limit
    }
}

/// CPU statistics
public struct CPUStats: Codable {
    public let cpuUsage: CPUUsage
    public let systemCpuUsage: UInt64?
    public let onlineCpus: Int?
    public let throttlingData: ThrottlingData?

    enum CodingKeys: String, CodingKey {
        case cpuUsage = "cpu_usage"
        case systemCpuUsage = "system_cpu_usage"
        case onlineCpus = "online_cpus"
        case throttlingData = "throttling_data"
    }

    public init(
        cpuUsage: CPUUsage,
        systemCpuUsage: UInt64?,
        onlineCpus: Int?,
        throttlingData: ThrottlingData?
    ) {
        self.cpuUsage = cpuUsage
        self.systemCpuUsage = systemCpuUsage
        self.onlineCpus = onlineCpus
        self.throttlingData = throttlingData
    }
}

/// CPU usage details
public struct CPUUsage: Codable {
    public let totalUsage: UInt64
    public let usageInKernelmode: UInt64
    public let usageInUsermode: UInt64

    enum CodingKeys: String, CodingKey {
        case totalUsage = "total_usage"
        case usageInKernelmode = "usage_in_kernelmode"
        case usageInUsermode = "usage_in_usermode"
    }

    public init(totalUsage: UInt64, usageInKernelmode: UInt64, usageInUsermode: UInt64) {
        self.totalUsage = totalUsage
        self.usageInKernelmode = usageInKernelmode
        self.usageInUsermode = usageInUsermode
    }
}

/// CPU throttling data
public struct ThrottlingData: Codable {
    public let periods: UInt64
    public let throttledPeriods: UInt64
    public let throttledTime: UInt64

    enum CodingKeys: String, CodingKey {
        case periods
        case throttledPeriods = "throttled_periods"
        case throttledTime = "throttled_time"
    }

    public init(periods: UInt64, throttledPeriods: UInt64, throttledTime: UInt64) {
        self.periods = periods
        self.throttledPeriods = throttledPeriods
        self.throttledTime = throttledTime
    }
}

/// Memory statistics
public struct MemoryStats: Codable {
    public let usage: UInt64
    public let limit: UInt64
    public let stats: MemoryStatsDetails?

    public init(usage: UInt64, limit: UInt64, stats: MemoryStatsDetails?) {
        self.usage = usage
        self.limit = limit
        self.stats = stats
    }
}

/// Memory statistics details
public struct MemoryStatsDetails: Codable {
    public let cache: UInt64?
    public let pgfault: UInt64?
    public let pgmajfault: UInt64?

    public init(cache: UInt64?, pgfault: UInt64?, pgmajfault: UInt64?) {
        self.cache = cache
        self.pgfault = pgfault
        self.pgmajfault = pgmajfault
    }
}

/// Block I/O statistics
public struct BlkioStats: Codable {
    public let ioServiceBytesRecursive: [BlkioStatEntry]?

    enum CodingKeys: String, CodingKey {
        case ioServiceBytesRecursive = "io_service_bytes_recursive"
    }

    public init(ioServiceBytesRecursive: [BlkioStatEntry]?) {
        self.ioServiceBytesRecursive = ioServiceBytesRecursive
    }
}

/// Block I/O stat entry
public struct BlkioStatEntry: Codable {
    public let major: UInt64
    public let minor: UInt64
    public let op: String
    public let value: UInt64

    public init(major: UInt64, minor: UInt64, op: String, value: UInt64) {
        self.major = major
        self.minor = minor
        self.op = op
        self.value = value
    }
}

/// Network statistics
public struct NetworkStats: Codable {
    public let rxBytes: UInt64
    public let rxPackets: UInt64
    public let rxErrors: UInt64
    public let rxDropped: UInt64
    public let txBytes: UInt64
    public let txPackets: UInt64
    public let txErrors: UInt64
    public let txDropped: UInt64

    enum CodingKeys: String, CodingKey {
        case rxBytes = "rx_bytes"
        case rxPackets = "rx_packets"
        case rxErrors = "rx_errors"
        case rxDropped = "rx_dropped"
        case txBytes = "tx_bytes"
        case txPackets = "tx_packets"
        case txErrors = "tx_errors"
        case txDropped = "tx_dropped"
    }

    public init(
        rxBytes: UInt64,
        rxPackets: UInt64,
        rxErrors: UInt64,
        rxDropped: UInt64,
        txBytes: UInt64,
        txPackets: UInt64,
        txErrors: UInt64,
        txDropped: UInt64
    ) {
        self.rxBytes = rxBytes
        self.rxPackets = rxPackets
        self.rxErrors = rxErrors
        self.rxDropped = rxDropped
        self.txBytes = txBytes
        self.txPackets = txPackets
        self.txErrors = txErrors
        self.txDropped = txDropped
    }
}
