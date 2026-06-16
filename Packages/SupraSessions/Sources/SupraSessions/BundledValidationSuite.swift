import Foundation
import SupraDiagnostics

/// Loads validation suites bundled with the SupraSessions package.
public enum BundledValidationSuite {
    public enum LoadError: Error, LocalizedError {
        case missingResource(String)

        public var errorDescription: String? {
            switch self {
            case let .missingResource(name):
                "The bundled validation suite '\(name)' could not be found."
            }
        }
    }

    static let milestone1ResourceName = "milestone1-practical-legal-client-suite-v1"

    /// The fixed Milestone 1 "Practical Legal-Client" suite.
    public static func milestone1() throws -> ValidationSuite {
        try load(resource: milestone1ResourceName)
    }

    static func load(resource: String) throws -> ValidationSuite {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw LoadError.missingResource(resource)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ValidationSuite.self, from: data)
    }
}
