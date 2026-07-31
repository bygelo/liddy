import Foundation
import Network

/// What the OS says about the link, without asking the network anything.
public struct NetworkPathReading: Codable, Sendable, Equatable {
    public enum Interface: String, Codable, Sendable {
        case wifi, wired, cellular, other, none

        public var display: String {
            switch self {
            case .wifi:     return "Wi-Fi"
            case .wired:    return "Ethernet"
            case .cellular: return "Cellular"
            case .other:    return "Other"
            case .none:     return "No interface"
            }
        }

        public var symbolName: String {
            switch self {
            case .wifi:     return "wifi"
            case .wired:    return "cable.connector"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .other:    return "network"
            case .none:     return "wifi.slash"
            }
        }
    }

    public var isSatisfied: Bool
    public var interface: Interface
    public var isExpensive: Bool
    public var isConstrained: Bool

    public static let unknown = NetworkPathReading(
        isSatisfied: false, interface: .none, isExpensive: false, isConstrained: false)

    public init(isSatisfied: Bool, interface: Interface, isExpensive: Bool, isConstrained: Bool) {
        self.isSatisfied = isSatisfied
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

/// A long-lived `NWPathMonitor`, read synchronously.
///
/// Deliberately not CoreWLAN: reading the Wi-Fi SSID needs Location Services
/// permission on modern macOS, and a keep-awake utility asking for your location to
/// draw a status dot is not a trade worth making. Interface type and reachability
/// answer the question ("is the network up?") with no permission at all.
public final class NetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.liddy.network.path")
    private let lock = NSLock()
    private var current: NetworkPathReading = .unknown
    private var isStarted = false

    public init() {}

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.store(Self.reading(from: path))
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
    }

    public var reading: NetworkPathReading {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func store(_ reading: NetworkPathReading) {
        lock.lock()
        current = reading
        lock.unlock()
    }

    static func reading(from path: NWPath) -> NetworkPathReading {
        let interface: NetworkPathReading.Interface
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wired
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.status == .satisfied {
            interface = .other
        } else {
            interface = .none
        }
        return NetworkPathReading(
            isSatisfied: path.status == .satisfied,
            interface: interface,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
