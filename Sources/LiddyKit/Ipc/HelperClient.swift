import Foundation

/// App-side connection to the root helper.
///
/// The connection is deliberately **persistent**. The helper treats a dropped socket
/// as "the app is gone" and reverts `disablesleep` immediately, so a crash restores
/// normal sleep in the time it takes the kernel to close a file descriptor — not on
/// next launch.
public final class HelperClient {
    private let client: LineSocketClient
    private let heartbeatQueue = DispatchQueue(label: "com.liddy.helper.heartbeat")
    private var heartbeatTimer: DispatchSourceTimer?

    /// Must stay comfortably under the helper's deadman window.
    public static let heartbeatIntervalSecond = 5

    public var onDisconnect: (() -> Void)?

    public init(path: String = LiddyPath.helperSocketPath) {
        self.client = LineSocketClient(path: path)
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: LiddyPath.helperSocketPath)
    }

    /// Read by the health panel. Deliberately a property on the *existing* connection
    /// rather than a fresh probe: the helper reverts `disablesleep` when any connection
    /// to it closes, so a panel that dialled the helper on a timer would end the very
    /// closed-lid session it was reporting on.
    public var isConnected: Bool { client.isConnected }

    /// Captured from the one status round trip made on the live connection, so the
    /// panel can name the helper version without opening anything.
    public private(set) var lastKnownVersion: String?

    public func connect() throws {
        try client.connect()
    }

    public func disconnect() {
        stopHeartbeat()
        client.disconnect()
    }

    @discardableResult
    private func send(_ request: HelperRequest) throws -> HelperResponse {
        if !client.isConnected { try client.connect() }
        return try client.roundTrip(request, expecting: HelperResponse.self)
    }

    /// Turn closed-lid support on or off. Starts/stops the heartbeat as a pair, so
    /// there is no path that enables the toggle without also arming the deadman switch.
    public func setClamshell(isOn: Bool) throws {
        let response = try send(.setClamshell(isOn: isOn))
        if case .failed(let message) = response {
            throw SocketError.cannotConnect(message)
        }
        if isOn {
            startHeartbeat()
            // Reuses the connection just opened — no second dial, so the deadman
            // switch never sees a close.
            lastKnownVersion = try? status().version
        } else {
            stopHeartbeat()
        }
    }

    public func sleepNow(reason: String) throws {
        _ = try send(.sleepNow(reason: reason))
    }

    public func status() throws -> HelperStatus {
        if case .status(let status) = try send(.status) { return status }
        throw SocketError.closed
    }

    private func startHeartbeat() {
        heartbeatQueue.async { [weak self] in
            guard let self, self.heartbeatTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.heartbeatQueue)
            timer.schedule(
                deadline: .now() + .seconds(Self.heartbeatIntervalSecond),
                repeating: .seconds(Self.heartbeatIntervalSecond)
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    _ = try self.send(.heartbeat)
                } catch {
                    // Losing the helper is not fatal to the app, but closed-lid can no
                    // longer be trusted — tell the runtime so it can stand down.
                    self.client.disconnect()
                    self.onDisconnect?()
                }
            }
            self.heartbeatTimer = timer
            timer.resume()
        }
    }

    private func stopHeartbeat() {
        heartbeatQueue.async { [weak self] in
            self?.heartbeatTimer?.cancel()
            self?.heartbeatTimer = nil
        }
    }
}
