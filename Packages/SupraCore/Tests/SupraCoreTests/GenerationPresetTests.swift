import SupraCore
import XCTest

final class GenerationPresetTests: XCTestCase {

    func testEachPresetHasDistinctTemperature() {
        let temps = GenerationPreset.allCases.map { $0.samplingParameters.temperature }
        XCTAssertEqual(Set(temps).count, GenerationPreset.allCases.count, "presets should be distinguishable")
    }

    func testPreciseMatchesHistoricalDefaults() {
        let precise = GenerationPreset.precise.samplingParameters
        XCTAssertEqual(precise.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(precise.topP, 0.8, accuracy: 0.0001)

        // The default GenerationOptions stays behaviour-preserving.
        let defaults = GenerationOptions()
        XCTAssertEqual(defaults.preset, .precise)
        XCTAssertEqual(defaults.temperature, precise.temperature, accuracy: 0.0001)
        XCTAssertEqual(defaults.topP, precise.topP, accuracy: 0.0001)
    }

    func testTemperatureIncreasesFromExtractiveToDrafting() {
        let order: [GenerationPreset] = [.extractive, .precise, .balanced, .drafting]
        let temps = order.map { $0.samplingParameters.temperature }
        XCTAssertEqual(temps, temps.sorted(), "extractive should be coolest, drafting warmest")
    }
}
