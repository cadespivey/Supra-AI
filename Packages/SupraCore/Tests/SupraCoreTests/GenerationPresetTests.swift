import SupraCore
import XCTest

final class GenerationPresetTests: XCTestCase {

    func testEachPresetHasDistinctTemperature() {
        let temps = GenerationPreset.allCases.map { $0.samplingParameters.temperature }
        XCTAssertGreaterThan(Set(temps).count, 3, "presets should remain meaningfully distinguishable")
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
        let order: [GenerationPreset] = [.extractive, .precise, .drafting, .balanced]
        let temps = order.map { $0.samplingParameters.temperature }
        XCTAssertEqual(temps, temps.sorted(), "extractive should be coolest and drafting should remain warmer than precise")
    }

    func testLegalResearchPresetUsesConservativeResearchDefaults() {
        let options = GenerationPreset.legalResearch.defaultOptions
        XCTAssertEqual(options.temperature, 0.15, accuracy: 0.0001)
        XCTAssertEqual(options.topP, 0.85, accuracy: 0.0001)
        XCTAssertEqual(options.topK, 20)
        XCTAssertEqual(options.maxContextTokens, 65_536)
        XCTAssertEqual(options.maxOutputTokens, 6000)
        XCTAssertEqual(options.thinkingBudget, .high)
    }

    func testUserSelectableDefaultsExcludeRouteSpecificLegalPresets() {
        XCTAssertEqual(GenerationPreset.userSelectableDefaults, [.balanced, .precise, .drafting, .extractive])
        XCTAssertFalse(GenerationPreset.userSelectableDefaults.contains(.legalResearch))
        XCTAssertFalse(GenerationPreset.userSelectableDefaults.contains(.legalVerify))
    }

    func testOptionsDecodeOldPersistedJSON() throws {
        let data = #"{"preset":"precise","temperature":0.33,"topP":0.8,"maxOutputTokens":2048}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(GenerationOptions.self, from: data)
        XCTAssertEqual(options.temperature, 0.33, accuracy: 0.0001)
        XCTAssertEqual(options.maxContextTokens, 32_768)
        XCTAssertEqual(options.thinkingBudget, .off)
    }

    func testExplicitNilTopKSurvivesCodableRoundTrip() throws {
        // A drafting preset whose default topK is 40, but the user cleared it.
        var options = GenerationPreset.drafting.defaultOptions
        XCTAssertEqual(options.topK, 40)
        options.topK = nil

        let encoded = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(GenerationOptions.self, from: encoded)
        XCTAssertNil(decoded.topK, "an explicitly cleared topK must not be reset to the preset default on round-trip")
        XCTAssertEqual(decoded, options)
    }

    func testTopKRoundTripsForExplicitValue() throws {
        var options = GenerationPreset.precise.defaultOptions
        options.topK = 17
        let decoded = try JSONDecoder().decode(GenerationOptions.self, from: try JSONEncoder().encode(options))
        XCTAssertEqual(decoded.topK, 17)
    }
}
