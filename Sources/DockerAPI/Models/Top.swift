import Foundation

/// Response from GET /containers/{id}/top
/// Lists processes running inside a container
public struct ContainerTopResponse: Codable, Sendable {
    /// The ps column titles (e.g., ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
    public let Titles: [String]

    /// Each process running in the container, where each process is an array of values corresponding to the titles
    public let Processes: [[String]]

    public init(Titles: [String], Processes: [[String]]) {
        self.Titles = Titles
        self.Processes = Processes
    }
}
