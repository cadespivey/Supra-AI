import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

// Milestone 4 Phase 4b — the billing-draft generation pipeline. The model proposes
// line *content* (which matter, narrative, codes, a duration with cited evidence);
// ALL arithmetic, reconciliation, and LEDES/CSV assembly stay in the deterministic
// SupraCore engine (Phase 4a). The model call is injected so the parse → validate →
// repair → map → reconcile → persist path is fully unit-testable without a model.

public enum BillingDraftError: Error, Equatable, Sendable {
    case noModelAvailable
    case emptyDay
    case unparseable
}

public struct BillingDraftResult: Sendable, Equatable {
    public let draftID: String
    public let version: Int
    public let lineCount: Int
    public let reconciliation: BillingReconciliation
}

@MainActor
public final class BillingDraftService {
    /// Injected model call: takes (systemPrompt, userPrompt), returns raw model text.
    public typealias Generate = @MainActor (_ systemPrompt: String, _ userPrompt: String) async throws -> String

    private let store: SupraStore
    private let generate: Generate

    public init(store: SupraStore, generate: @escaping Generate) {
        self.store = store
        self.generate = generate
    }

    /// Production wiring: loads the routed task model and runs a deterministic,
    /// low-temperature generation through the runtime (mirrors DocumentClassificationService).
    public static func live(
        store: SupraStore,
        modelLibrary: ModelLibrary,
        runtimeClient: any RuntimeClientProtocol,
        role: ModelRole = .drafting
    ) -> BillingDraftService {
        BillingDraftService(store: store) { systemPrompt, userPrompt in
            guard case let .success(modelID) = await modelLibrary.ensureLoadedRoutedModelID(for: role) else {
                throw BillingDraftError.noModelAvailable
            }
            let request = GenerateRequest(
                generationID: GenerationID(),
                modelID: modelID,
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                options: GenerationOptions(
                    preset: .extractive,
                    temperature: 0.0,
                    topP: 1.0,
                    maxOutputTokens: 3000,
                    thinkingBudget: .off
                )
            )
            let raw = try await runtimeClient.collectGeneratedText(request)
            return ReasoningContent.answer(from: raw)
        }
    }

    /// Generates a new billing-draft version for a day, persists it, and returns a
    /// summary. Throws `emptyDay` if there are no notes, `noModelAvailable` /
    /// `unparseable` if generation can't produce usable JSON.
    @discardableResult
    public func generateDraft(
        dayID: String,
        sensitivity: Double,
        timekeeper: BillingTimekeeper,
        invoiceDate: String,
        globalInstructions: String = "",
        increment: Double = 0.1
    ) async throws -> BillingDraftResult {
        let entries = (try? store.scratchPad.entries(dayID: dayID)) ?? []
        guard !entries.isEmpty else { throw BillingDraftError.emptyDay }
        let attachments = (try? store.scratchPad.attachments(dayID: dayID)) ?? []
        let matters = (try? store.matters.fetchMatters()) ?? []
        let profiles = Dictionary(uniqueKeysWithValues: matters.compactMap { matter -> (String, MatterBillingProfileRecord)? in
            guard let profile = try? store.billing.billingProfile(matterID: matter.id) else { return nil }
            return (matter.id, profile)
        })
        let dayDate = (try? store.scratchPad.fetchDay(id: dayID))?.day ?? invoiceDate

        let context = BillingDraftPrompt.Context(
            dayDate: dayDate,
            entries: entries,
            attachments: attachments,
            matters: matters,
            profiles: profiles,
            sensitivity: sensitivity,
            increment: increment,
            globalInstructions: globalInstructions
        )

        let raw = try await generate(BillingDraftPrompt.system(), BillingDraftPrompt.user(context))
        guard let payload = Self.parse(raw) else { throw BillingDraftError.unparseable }

        let inputs = Self.buildInputs(
            payload: payload,
            matters: matters,
            timekeeper: timekeeper,
            dayDate: dayDate,
            increment: increment
        )
        let lines = Self.billingLines(inputs: inputs, matters: matters, timekeeper: timekeeper)
        let reconciliation = BillingReconciliationEngine.reconcile(lines: lines, timekeeper: timekeeper, increment: increment)

        let draft = try store.billing.createDraft(
            dayID: dayID,
            modelID: nil,
            sensitivity: sensitivity,
            reconciliationJSON: Self.encode(reconciliation),
            lineItems: inputs
        )
        return BillingDraftResult(
            draftID: draft.id,
            version: draft.version,
            lineCount: inputs.count,
            reconciliation: reconciliation
        )
    }

    // MARK: - Parsing + validation + repair

    static func parse(_ raw: String) -> BillingDraftPayload? {
        guard let json = DocumentClassificationService.extractJSONObject(from: raw) else { return nil }
        return try? JSONDecoder().decode(BillingDraftPayload.self, from: Data(json.utf8))
    }

    /// Validates + repairs the model's raw line DTOs into persistable inputs:
    /// resolves the matter (by id or name) against the day's matters or drops it,
    /// rounds hours to the increment, defaults the work date and confidence, and
    /// stamps the timekeeper + rate. Deterministic; never trusts model arithmetic.
    static func buildInputs(
        payload: BillingDraftPayload,
        matters: [MatterRecord],
        timekeeper: BillingTimekeeper,
        dayDate: String,
        increment: Double
    ) -> [BillingLineItemInput] {
        payload.lineItems.compactMap { dto in
            let narrative = dto.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !narrative.isEmpty else { return nil }
            let matter = resolveMatter(dto.matterID, in: matters)
            let hours = roundToIncrement(max(0, dto.hours ?? 0), increment)
            let confidence = BillingConfidence(rawValue: (dto.confidence ?? "medium").lowercased()) ?? .medium
            return BillingLineItemInput(
                clientID: matter?.clientID,
                matterID: matter?.id,
                narrative: narrative,
                hours: hours,
                workDate: normalizedDate(dto.workDate) ?? dayDate,
                utbmsTaskCode: trimmedOrNil(dto.taskCode),
                utbmsActivityCode: trimmedOrNil(dto.activityCode),
                timekeeperID: timekeeper.id,
                rate: timekeeper.defaultRate,
                confidence: confidence,
                evidenceJSON: trimmedOrNil(dto.evidence),
                codeNote: trimmedOrNil(dto.codeNote),
                sourceEntryIDs: dto.sourceEntryIDs ?? [],
                userEdited: false
            )
        }
    }

    static func billingLines(inputs: [BillingLineItemInput], matters: [MatterRecord], timekeeper: BillingTimekeeper) -> [BillingLine] {
        inputs.map { input in
            let matter = input.matterID.flatMap { id in matters.first { $0.id == id } }
            return BillingLine(
                clientID: matter?.clientID,
                lawFirmMatterID: matter?.internalMatterID,
                clientMatterID: matter?.clientMatterID,
                clientDisplay: matter?.clientNames ?? matter?.name,
                matterDisplay: matter?.name,
                narrative: input.narrative,
                hours: input.hours,
                workDate: input.workDate,
                taskCode: input.utbmsTaskCode,
                activityCode: input.utbmsActivityCode,
                rate: input.rate,
                confidence: input.confidence
            )
        }
    }

    // MARK: - Helpers

    static func resolveMatter(_ value: String?, in matters: [MatterRecord]) -> MatterRecord? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let byID = matters.first(where: { $0.id == value }) { return byID }
        return matters.first { $0.name.compare(value, options: .caseInsensitive) == .orderedSame }
    }

    static func roundToIncrement(_ value: Double, _ increment: Double) -> Double {
        guard increment > 0 else { return value }
        return ((value / increment).rounded() * increment * 100).rounded() / 100
    }

    /// Accepts `yyyy-MM-dd`; returns nil for anything else so the caller defaults it.
    static func normalizedDate(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.count == 10 else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return value
    }

    static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func encode(_ reconciliation: BillingReconciliation) -> String? {
        guard let data = try? JSONEncoder().encode(reconciliation) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The JSON shape the model is asked to return.
struct BillingDraftPayload: Codable {
    var lineItems: [LineDTO]

    struct LineDTO: Codable {
        var matterID: String?
        var narrative: String
        var hours: Double?
        var workDate: String?
        var taskCode: String?
        var activityCode: String?
        var confidence: String?
        var evidence: String?
        var codeNote: String?
        var sourceEntryIDs: [String]?
    }
}
