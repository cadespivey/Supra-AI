import Foundation
import SupraCore
import SupraRuntimeInterface

public struct ValidationReport: Codable, Sendable {
    public let generatedAt: Date
    public let appName: String
    public let appVersion: String
    public let runtimeState: String
    public let modelName: String
    public let modelPath: String?
    public let suiteID: String
    public let suiteVersion: Int
    public let suiteName: String
    public let overallStatus: ValidationRunStatus
    public let metrics: RuntimeMetrics?
    public let testResults: [ValidationReportTestResult]
    public let warnings: [String]
    public let errors: [String]
    public let technicalNotes: [String]
    public let nextSteps: [String]

    public init(
        generatedAt: Date = Date(),
        appName: String = "Supra AI",
        appVersion: String,
        runtimeState: String,
        modelName: String,
        modelPath: String?,
        suiteID: String,
        suiteVersion: Int,
        suiteName: String,
        overallStatus: ValidationRunStatus,
        metrics: RuntimeMetrics? = nil,
        testResults: [ValidationReportTestResult],
        warnings: [String] = [],
        errors: [String] = [],
        technicalNotes: [String] = [],
        nextSteps: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.appName = appName
        self.appVersion = appVersion
        self.runtimeState = runtimeState
        self.modelName = modelName
        self.modelPath = modelPath
        self.suiteID = suiteID
        self.suiteVersion = suiteVersion
        self.suiteName = suiteName
        self.overallStatus = overallStatus
        self.metrics = metrics
        self.testResults = testResults
        self.warnings = warnings
        self.errors = errors
        self.technicalNotes = technicalNotes
        self.nextSteps = nextSteps
    }
}

public struct ValidationReportTestResult: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let status: ValidationTestStatus
    public let outputExcerpt: String
    public let warnings: [String]
    public let errors: [String]

    public init(
        id: String,
        name: String,
        status: ValidationTestStatus,
        outputExcerpt: String,
        warnings: [String] = [],
        errors: [String] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.outputExcerpt = outputExcerpt
        self.warnings = warnings
        self.errors = errors
    }
}
