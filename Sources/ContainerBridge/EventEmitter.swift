import Foundation

/// Protocol for emitting Docker events
/// This allows ContainerBridge to emit events without depending on DockerAPI types
public protocol EventEmitter: Sendable {
    /// Emit a container event
    func emitContainerEvent(
        action: String,
        containerID: String,
        attributes: [String: String]
    ) async

    /// Emit an image event
    func emitImageEvent(
        action: String,
        imageID: String,
        attributes: [String: String]
    ) async

    /// Emit a network event
    func emitNetworkEvent(
        action: String,
        networkID: String,
        attributes: [String: String]
    ) async

    /// Emit a volume event
    func emitVolumeEvent(
        action: String,
        volumeName: String,
        attributes: [String: String]
    ) async
}
