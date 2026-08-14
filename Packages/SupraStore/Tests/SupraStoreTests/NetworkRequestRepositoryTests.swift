@testable import SupraStore
import XCTest

final class NetworkRequestRepositoryTests: XCTestCase {
    func testACRFP006CleanupRemovesLegacyQueryMetadataWithoutExposingValues() throws {
        let store = try SupraStore.inMemory()
        _ = try store.networkRequests.createRequest(
            domain: "www.courtlistener.com",
            method: "GET",
            endpoint: "/api/rest/v4/search/",
            approved: true,
            requestMetadataJSON: #"{"query":"q=#deadbeef&type=#cafebabe","headers":{"Accept":"application/json"}}"#
        )
        _ = try store.networkRequests.createRequest(
            domain: "www.courtlistener.com",
            method: "GET",
            endpoint: "/malformed",
            approved: true,
            requestMetadataJSON: "legacy-q=#secret-canary"
        )

        XCTAssertEqual(try store.networkRequests.removeStoredQueryMetadata(), 2)

        let records = try store.networkRequests.fetchRecent(limit: 10)
        let structured = try XCTUnwrap(records.first { $0.endpoint.contains("search") })
        XCTAssertFalse(structured.requestMetadataJSON?.contains("query") ?? false)
        XCTAssertTrue(structured.requestMetadataJSON?.contains("Accept") ?? false)
        let malformed = try XCTUnwrap(records.first { $0.endpoint == "/malformed" })
        XCTAssertNil(malformed.requestMetadataJSON)
    }
}
