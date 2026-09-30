import Foundation

/// Real die temperature, in °C, from the HID temperature sensors.
///
/// `ProcessInfo.thermalState` — what the panel drew before — is not a temperature. It
/// is a *pressure* signal the OS raises when it intends to start throttling, it moves
/// in four steps, and it is sticky: a Mac that finished a build ten minutes ago can sit
/// at `.fair` while the die is at 38°C. That mismatch is the "temperature is not
/// accurate" report, and it is not fixable by relabelling the four states, because the
/// states were never a temperature.
///
/// So both are kept, and they answer different questions. The **state** still drives
/// the governor: it is what macOS says about throttling risk, which is the thing worth
/// ending a run over. The **temperature** is what the panel shows, because it is what a
/// human means by "how hot is my laptop".
///
/// The sensors are read through `IOHIDEventSystemClient`, which needs no root and no
/// entitlement. The symbols are private, so — as with `DisplayBrightness` — they are
/// `dlsym`ed rather than linked, and an absent symbol turns the reading off rather than
/// failing the launch.
///
/// This is a deliberate, narrow reversal of the old `ThermalReader` doc comment, which
/// rejected SMC reads outright. The case it named is real but Intel-specific: a
/// power-starved Intel Mac reads cool while clock-capped, so temperature alone is a bad
/// *decision* input. It is not a bad *display*, and on Apple silicon these sensors are
/// what every system readout uses. The decision input is unchanged.
public enum TemperatureReader {
    private static let iokitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"

    /// Apple's vendor HID page, and the usage that means "temperature sensor".
    fileprivate static let vendorPage = 0xff00
    fileprivate static let temperatureUsage = 0x0005
    /// `kIOHIDEventTypeTemperature`, and the field base it implies (`type << 16`).
    private static let temperatureEventType = 15
    private static var temperatureField: UInt32 { UInt32(temperatureEventType << 16) }

    fileprivate typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    fileprivate typealias SetMatching = @convention(c) (CFTypeRef?, CFDictionary?) -> Void
    fileprivate typealias CopyServices = @convention(c) (CFTypeRef?) -> Unmanaged<CFArray>?
    fileprivate typealias CopyProperty = @convention(c) (CFTypeRef?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef?, Int32, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventFloat = @convention(c) (CFTypeRef?, UInt32) -> Double

    private static let handle: UnsafeMutableRawPointer? = dlopen(iokitPath, RTLD_LAZY)

    fileprivate static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: type)
    }

    /// One sensor's reading.
    public struct Sensor: Sendable, Equatable {
        public var name: String
        public var celsius: Double
    }

    /// The HID client and its matched services, built once.
    ///
    /// Rebuilding them per read cost 44ms — measured — because
    /// `IOHIDEventSystemClientCopyServices` walks and matches the whole registry on
    /// every call. The sensor *set* does not change while the machine runs; only the
    /// values do.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var client: CFTypeRef?
        var service: [(entry: CFTypeRef, name: String)]?
    }
    private static let cache = Cache()

    private static func services() -> [(entry: CFTypeRef, name: String)] {
        if let known = cache.service { return known }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { cache.service = []; return [] }

        let matching: [String: Int] = [
            "PrimaryUsagePage": vendorPage,
            "PrimaryUsage": temperatureUsage,
        ]
        setMatching(client, matching as CFDictionary)
        let entry = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let named = entry.map { service in
            (entry: service,
             name: (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "sensor")
        }
        // An empty match is not cached: the HID system can answer before its services
        // have registered at login, and "no sensors, forever" is the wrong memo.
        guard !named.isEmpty else { return [] }

        // Keep only the sensors this type ever reports.
        //
        // Every `IOHIDServiceClientCopyEvent` is an IPC round trip to a driver, so the
        // per-read cost is linear in how many are held. This Mac exposes 45, of which 36
        // are die or package sensors; the rest are the SSD, the battery and a calibration
        // reference, all of which `cpuCelsius` discards anyway. Filtering here means the
        // round trips are never made at all.
        let wanted = named.filter { isDie($0.name) || isFallback($0.name) }
        let kept = wanted.isEmpty ? named : wanted

        cache.client = client
        cache.service = kept
        return kept
    }

    /// Every temperature sensor this Mac exposes, named.
    ///
    /// Sensors that read zero are dropped: an unpopulated channel reports 0.0 rather
    /// than failing, and averaging those in is how a warm laptop reports 19°C.
    public static func sensor() -> [Sensor] {
        guard let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: EventFloat.self)
        else { return [] }
        cache.lock.lock()
        defer { cache.lock.unlock() }

        return services().compactMap { service -> Sensor? in
            guard let event = copyEvent(service.entry, Int32(temperatureEventType), 0, 0)?.takeRetainedValue()
            else { return nil }
            let celsius = floatValue(event, temperatureField)
            guard celsius > 0, celsius < 150 else { return nil }
            return Sensor(name: service.name, celsius: celsius)
        }
    }

    /// The number the panel shows: the hottest die sensor.
    ///
    /// Max rather than mean, and die-only. Measured on this Mac, 45 temperature sensors
    /// are exposed and they are not interchangeable:
    ///
    /// | Sensor | Reading | What it is |
    /// |---|---|---|
    /// | `PMU tdie1…14` | 60–68°C | the die itself — this is the answer |
    /// | `PMU tdev*` | 41–64°C | device/package, cooler than the die |
    /// | `PMU tcal` | 51.8°C | a **calibration reference**, not a temperature |
    /// | `NAND CH0 temp` | 47°C | the SSD |
    /// | `gas gauge battery` | 37.8°C | the battery |
    ///
    /// Averaging those together gives a number that barely moves and matches nothing
    /// any other tool reports. The first version of this function matched `tcal` and
    /// confidently returned 52°C while the die was at 68°C — exactly the class of
    /// plausible-but-wrong reading this file exists to avoid.
    /// Last reading and when it was taken. 36 sensors at ~1.1ms of driver IPC each is
    /// ~40ms a call, and that call sat on `makeSnapshot()` — which runs on every
    /// publish, several times a tick. A die temperature does not move meaningfully in
    /// ten seconds, so it is read on a timer rather than on demand.
    private final class Reading: @unchecked Sendable {
        let lock = NSLock()
        var celsius: Double?
        var takenAt = Date.distantPast
    }
    private static let reading = Reading()
    public static let defaultMaxAgeSecond: TimeInterval = 10

    /// How stale a reading may be, adjusted by whoever knows if anyone is watching.
    ///
    /// A static rather than a parameter because `ThermalReader.read()` is called from a
    /// dozen places that have no idea whether the panel is open, and threading a TTL
    /// through all of them to express one fact — "nobody can see this number" — would
    /// be worse than one guarded variable.
    private static let ageLock = NSLock()
    private static var maxAgeSecond: TimeInterval = defaultMaxAgeSecond

    public static func setMaxAge(second: TimeInterval) {
        ageLock.lock(); defer { ageLock.unlock() }
        maxAgeSecond = second
    }

    private static var currentMaxAge: TimeInterval {
        ageLock.lock(); defer { ageLock.unlock() }
        return maxAgeSecond
    }

    /// - Parameter maxAgeSecond: how stale an answer may be. Pass 0 to force a read.
    public static func cpuCelsius(maxAgeSecond: TimeInterval? = nil) -> Double? {
        let maxAgeSecond = maxAgeSecond ?? currentMaxAge
        reading.lock.lock()
        if Date().timeIntervalSince(reading.takenAt) < maxAgeSecond {
            defer { reading.lock.unlock() }
            return reading.celsius
        }
        reading.lock.unlock()

        let fresh = measureCpuCelsius()
        reading.lock.lock()
        reading.celsius = fresh
        reading.takenAt = Date()
        reading.lock.unlock()
        return fresh
    }

    private static func measureCpuCelsius() -> Double? {
        let all = sensor()
        guard !all.isEmpty else { return nil }
        let die = all.filter { isDie($0.name) }
        let pool = die.isEmpty ? all.filter { isFallback($0.name) } : die
        return pool.map(\.celsius).max()
    }

    /// Die sensors. Apple silicon publishes `PMU tdieN` / `PMU2 tdieN` per cluster.
    static func isDie(_ name: String) -> Bool {
        name.lowercased().contains("tdie")
    }

    /// A plausible processor temperature when no die sensor exists. Excludes `tcal`
    /// (calibration), the battery and the SSD by name, because all three read like a
    /// temperature and none of them is the one being asked for.
    static func isFallback(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.contains("tcal") || lowered.contains("gas gauge") || lowered.contains("nand") {
            return false
        }
        for marker in ["tdev", "soc", "gpu", "cpu", "tc0", "tcxc"] where lowered.contains(marker) {
            return true
        }
        return false
    }

    /// "47°" — no decimal. A tenth of a degree on a readout that refreshes every 15
    /// seconds is noise formatted as precision.
    public static func display(_ celsius: Double?) -> String? {
        celsius.map { "\(Int($0.rounded()))°" }
    }
}
