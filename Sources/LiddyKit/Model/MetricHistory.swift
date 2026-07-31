import Foundation

/// One tick's worth of what the menu draws over time.
public struct MetricSample: Codable, Sendable, Equatable {
    public var at: Date
    public var leaseCount: Int
    public var batteryPercent: Int?
    public var thermalRank: Int
    public var isHeld: Bool

    public init(at: Date, leaseCount: Int, batteryPercent: Int?, thermalRank: Int, isHeld: Bool) {
        self.at = at
        self.leaseCount = leaseCount
        self.batteryPercent = batteryPercent
        self.thermalRank = thermalRank
        self.isHeld = isHeld
    }
}

/// A fixed-size ring of recent samples, for the sparkline.
///
/// Bounded on purpose: this exists to draw a 60-pixel-wide chart, not to be a
/// datastore. The activity log on disk is where history that matters lives.
public final class MetricHistory {
    public let capacity: Int
    private var storage: [MetricSample] = []

    /// 180 samples at the runtime's 5s tick — 15 minutes. Deeper than the menu's strip
    /// draws (it asks for the most recent 48, about 4 minutes), so the extra is
    /// headroom for a wider chart rather than something currently shown.
    public init(capacity: Int = 180) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public func append(_ sample: MetricSample) {
        storage.append(sample)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public var sample: [MetricSample] { storage }

    public func recent(limit: Int) -> [MetricSample] {
        guard limit < storage.count else { return storage }
        return Array(storage.suffix(max(0, limit)))
    }

    public func clear() { storage.removeAll(keepingCapacity: true) }
}
