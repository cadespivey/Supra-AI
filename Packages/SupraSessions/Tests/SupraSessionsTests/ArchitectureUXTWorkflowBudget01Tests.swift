import XCTest
@testable import SupraSessions

final class ArchitectureUXTWorkflowBudget01Tests: XCTestCase {
    func testEveryDimensionAdmitsNAndStopsNPlusOneBeforeFurtherEffects() {
        for dimension in WorkflowBudgetDimension.allCases {
            let limit = ModelTaskBudgetUsage(modelCalls: 7, toolCalls: 7, inputTokens: 7, outputTokens: 7, elapsedMilliseconds: 7, retries: 7, repetitions: 7, egressBytes: 7, workingSetBytes: 7)
            var budget = ModelTaskBudget(taskID: "record-713-v7", limits: limit)
            let n = usage(dimension, value: 7)
            XCTAssertEqual(budget.admit(n), .admitted, dimension.rawValue)
            let reason = WorkflowTerminalReason.budgetExceeded(dimension: dimension, limit: 7, attempted: dimension == .workingSetBytes ? 8 : 8)
            XCTAssertEqual(budget.admit(usage(dimension, value: dimension == .workingSetBytes ? 8 : 1)), .stopped(reason), dimension.rawValue)
            XCTAssertEqual(budget.admit(ModelTaskBudgetUsage()), .stopped(reason), dimension.rawValue)
        }
    }

    private func usage(_ dimension: WorkflowBudgetDimension, value: Int) -> ModelTaskBudgetUsage {
        var usage = ModelTaskBudgetUsage()
        switch dimension {
        case .modelCalls: usage.modelCalls = value
        case .toolCalls: usage.toolCalls = value
        case .inputTokens: usage.inputTokens = value
        case .outputTokens: usage.outputTokens = value
        case .elapsedMilliseconds: usage.elapsedMilliseconds = value
        case .retries: usage.retries = value
        case .repetitions: usage.repetitions = value
        case .egressBytes: usage.egressBytes = value
        case .workingSetBytes: usage.workingSetBytes = value
        }
        return usage
    }
}
