import XCTest
@testable import LiddyKit

/// Sensor names copied from this Mac's 45 HID temperature sensors. The whole risk here
/// is picking a sensor that reads like a temperature and is not the one asked for —
/// the first version returned `PMU tcal` at 52°C while the die was at 68°C.
final class TemperatureSelectionTest: XCTestCase {
    func testDieSensorsAreRecognised() {
        XCTAssertTrue(TemperatureReader.isDie("PMU tdie1"))
        XCTAssertTrue(TemperatureReader.isDie("PMU2 tdie10"))
    }

    func testCalibrationBatteryAndSsdAreNotTemperatures() {
        XCTAssertFalse(TemperatureReader.isDie("PMU tcal"))
        XCTAssertFalse(TemperatureReader.isFallback("PMU tcal"), "a calibration reference is not the die")
        XCTAssertFalse(TemperatureReader.isFallback("gas gauge battery"))
        XCTAssertFalse(TemperatureReader.isFallback("NAND CH0 temp"))
    }

    func testFallbackAcceptsDeviceSensorsWhenNoDieExists() {
        XCTAssertTrue(TemperatureReader.isFallback("PMU tdev2"))
        XCTAssertTrue(TemperatureReader.isFallback("SOC MTR Temp Sensor0"))
    }

    func testDisplayRoundsAndIsNilWithoutAReading() {
        XCTAssertEqual(TemperatureReader.display(68.4), "68°")
        XCTAssertNil(TemperatureReader.display(nil))
    }

    /// The reading and the pressure state are different questions; the panel must not
    /// silently substitute one for the other.
    func testThermalReadingFallsBackToThePressureWord() {
        XCTAssertEqual(ThermalReading(level: .fair, celsius: 68).display, "68°")
        XCTAssertEqual(ThermalReading(level: .fair, celsius: nil).display, "Fair")
    }
}

/// `ps` reports %cpu per core, so the raw sum is not a system load until it is divided.
final class SystemCpuTest: XCTestCase {
    private let load = [
        ProcessLoad(pid: 1, name: "a", cpuPercent: 100, memoryPercent: 1),
        ProcessLoad(pid: 2, name: "b", cpuPercent: 100, memoryPercent: 1),
    ]

    func testSumIsDividedByCoreCount() {
        XCTAssertEqual(ProcessLoad.systemCpuPercent(load, coreCount: 10), 20, accuracy: 0.001)
    }

    func testClampedToOneHundred() {
        XCTAssertEqual(ProcessLoad.systemCpuPercent(load, coreCount: 1), 100)
    }

    func testEmptyIsZeroAndZeroCoresCannotDivide() {
        XCTAssertEqual(ProcessLoad.systemCpuPercent([], coreCount: 8), 0)
        XCTAssertEqual(ProcessLoad.systemCpuPercent(load, coreCount: 0), 0)
    }
}
