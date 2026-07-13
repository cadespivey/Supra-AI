#if DEBUG
import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SwiftUI

@MainActor
struct RuntimeXPCIntegrationView: View {
    let scenario: String

    @State private var result = "RUNNING"
    @State private var detail = "Starting signed hosted-XPC checks."
    @State private var completedIterations = 0
    @State private var checks: [String: Bool] = [:]
    @State private var switchValue = false
    @State private var focusedControl: String?
    @State private var nextControlValue = ""
    @State private var focusChain = SupraFocusChain()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runtime XPC integration")
                .font(.title2)

            if scenario == "switch" {
                switchScenario
            } else {
                lifecycleScenario
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480, alignment: .topLeading)
    }

    private var lifecycleScenario: some View {
        VStack(alignment: .leading, spacing: 8) {
            if result == "RUNNING" {
                ProgressView()
                    .accessibilityIdentifier("runtimeXPCIntegration.progress")
            } else {
                Text(result)
                    .accessibilityIdentifier("runtimeXPCIntegration.result")
                    .accessibilityLabel("Runtime lifecycle result")
                    .accessibilityValue(result)
            }
            Text(detail)
                .accessibilityIdentifier("runtimeXPCIntegration.detail")
                .accessibilityLabel("Runtime lifecycle detail")
                .accessibilityValue(detail)
            Text("\(completedIterations)/20")
                .accessibilityIdentifier("runtimeXPCIntegration.iterations")
                .accessibilityLabel("Completed lifecycle iterations")
                .accessibilityValue("\(completedIterations)/20")

            ForEach(RuntimeXPCIntegrationRunner.checkIDs, id: \.self) { checkID in
                Text(checks[checkID] == true ? "PASS" : "PENDING")
                    .accessibilityIdentifier("runtimeXPCIntegration.check.\(checkID)")
                    .accessibilityLabel("Lifecycle check \(checkID)")
                    .accessibilityValue(checks[checkID] == true ? "PASS" : "PENDING")
            }
        }
        .task {
            do {
                let report = try await RuntimeXPCIntegrationRunner().run(iterations: 20) {
                    completedIterations = $0
                }
                checks = report.checks
                completedIterations = report.iterations
                detail = report.detail
                result = report.checks.values.allSatisfy { $0 } ? "PASS" : "FAIL"
            } catch {
                detail = error.localizedDescription
                result = "FAIL"
            }
        }
    }

    private var switchScenario: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusChainSwitch(
                isOn: $switchValue,
                focusChain: focusChain,
                focusOrder: 0,
                accessibilityID: "runtimeXPCIntegration.switch",
                accessibilityLabelText: "Lifecycle integration switch"
            )
            BoxedLeadingTextField(
                placeholder: "Next control",
                text: $nextControlValue,
                focusChain: focusChain,
                focusOrder: 1,
                accessibilityID: "runtimeXPCIntegration.afterSwitch"
            )

            if focusedControl == "runtimeXPCIntegration.afterSwitch" {
                Text("Next control focused")
                    .accessibilityIdentifier("runtimeXPCIntegration.afterSwitchFocused")
            }
            if focusedControl == "runtimeXPCIntegration.switch" {
                Text("Switch focused")
                    .accessibilityIdentifier("runtimeXPCIntegration.switchFocused")
            }
        }
        .onAppear {
            focusChain.onFocusChange = { focusedControl = $0 }
            focusChain.installInitialFocusIfPossible()
        }
    }
}

private struct RuntimeXPCIntegrationReport: Sendable {
    let iterations: Int
    let checks: [String: Bool]
    let detail: String
}

private enum RuntimeXPCIntegrationError: LocalizedError {
    case assertion(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .assertion(message): "Hosted XPC assertion failed: \(message)"
        case let .timeout(message): "Hosted XPC timeout: \(message)"
        }
    }
}

private struct RuntimeXPCIntegrationRunner {
    static let checkIDs = [
        "statusRoundTrip",
        "nilBookmarkRejected",
        "invalidBookmarkRejected",
        "nilManagedIdentityRejected",
        "staleBookmarkRejected",
        "samePathReplacementRejected",
        "managedRootEscapeRejected",
        "controlledModelLoaded",
        "streamCompletedOnce",
        "cancelExactlyOnce",
        "cancelBeforeTaskInstall",
        "reservationBeforeAdmission",
        "foreignCancelRejected",
        "reusedGenerationID",
        "clientTermination",
        "concurrentLoadUnload",
        "reconnect",
        "resourceBound",
    ]

    private static let markerName = ".supra-xpc-lifecycle-test-model"
    private static let markerData = Data("SUPRA-XPC-LIFECYCLE-V1\n".utf8)
    private static let completionPrompt = "SUPRA-XPC-TEST-COMPLETE"
    private static let holdPrompt = "SUPRA-XPC-TEST-HOLD"
    private static let installRacePrompt = "SUPRA-XPC-TEST-INSTALL-RACE"
    private static let reservationRacePrompt = "SUPRA-XPC-TEST-RESERVATION-RACE"
    private static let staleTerminationPrompt = "SUPRA-XPC-TEST-STALE-TERMINATION"

    func run(
        iterations: Int,
        progress: @MainActor (Int) -> Void
    ) async throws -> RuntimeXPCIntegrationReport {
        let fixture = try makeFixture()
        defer {
            fixture.releaseScopes()
            try? FileManager.default.removeItem(at: fixture.base)
        }

        var checks = Dictionary(uniqueKeysWithValues: Self.checkIDs.map { ($0, true) })
        let resourceProbe = RuntimeClient()
        try await resourceProbe.connect()
        let startingResidentMiB = try await resourceProbe.runtimeStatus().metrics?.peakMemoryMb
        resourceProbe.disconnect()
        try require(startingResidentMiB != nil, "XPC service did not report its resident-memory peak")

        for iteration in 1...iterations {
            let iterationChecks = try await runIteration(fixture: fixture, iteration: iteration)
            for (name, passed) in iterationChecks {
                checks[name] = checks[name, default: true] && passed
            }
            await progress(iteration)
        }

        let endingProbe = RuntimeClient()
        try await endingProbe.connect()
        let endingResidentMiB = try await endingProbe.runtimeStatus().metrics?.peakMemoryMb
        endingProbe.disconnect()
        try require(endingResidentMiB != nil, "XPC service did not report its final resident-memory peak")
        let residentGrowthMiB = max(0, endingResidentMiB! - startingResidentMiB!)
        // The deterministic fixture contains no weights. Repeated connection,
        // cancellation, and stream state must stay comfortably below this bound.
        checks["resourceBound"] = residentGrowthMiB <= 256

        return RuntimeXPCIntegrationReport(
            iterations: iterations,
            checks: checks,
            detail: "\(iterations)/\(iterations) lifecycle iterations; XPC max-RSS growth \(residentGrowthMiB) MiB; public code-signing requirement active."
        )
    }

    private func runIteration(
        fixture: Fixture,
        iteration: Int
    ) async throws -> [String: Bool] {
        let client = RuntimeClient()
        try await client.connect()

        let initialStatus = try await client.runtimeStatus()
        try require(
            initialStatus.message == "Runtime service available.",
            "status callback did not cross the hosted service"
        )

        let nilBookmark = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.model.path,
                bookmark: nil,
                root: fixture.root.path
            )
        )
        try requireAccessRejected(nilBookmark, name: "nil bookmark")

        let invalidBookmark = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.model.path,
                bookmark: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                root: fixture.root.path
            )
        )
        try requireAccessRejected(invalidBookmark, name: "invalid bookmark")

        let nilManagedIdentity = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.model.path,
                bookmark: fixture.modelBookmark,
                root: fixture.root.path,
                includeCurrentIdentity: false
            )
        )
        try requireAccessRejected(nilManagedIdentity, name: "nil managed identity")

        let staleBookmark = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.staleOriginalPath,
                bookmark: fixture.staleBookmark,
                root: fixture.root.path
            )
        )
        try requireAccessRejected(staleBookmark, name: "stale/moved bookmark")

        let samePathReplacement = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.recreatedModel.path,
                bookmark: fixture.recreatedBookmark,
                root: fixture.root.path,
                identity: fixture.recreatedOriginalIdentity
            )
        )
        try requireAccessRejected(samePathReplacement, name: "same-path model replacement")

        let escaped = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.escape.path,
                bookmark: fixture.escapeBookmark,
                root: fixture.root.path
            )
        )
        try requireAccessRejected(escaped, name: "managed-root escape")

        let symlinkEscaped = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.symlinkEscape.path,
                // The authority resolves to the outside target while the requested
                // lexical path sits under the managed root. Canonical containment
                // must reject this classic prefix/symlink escape.
                bookmark: fixture.escapeBookmark,
                root: fixture.root.path
            )
        )
        try requireAccessRejected(symlinkEscaped, name: "managed-root symlink escape")

        let modelID = ModelID()
        let load = try await client.loadModel(
            request(
                id: modelID,
                path: fixture.model.path,
                bookmark: fixture.modelBookmark,
                root: fixture.root.path
            )
        )
        let loadDetail = [load.error?.message, load.error?.technicalDetails]
            .compactMap { $0 }
            .joined(separator: " — ")
        try require(
            load.status == .loaded,
            "controlled lifecycle model did not load\(loadDetail.isEmpty ? "" : ": \(loadDetail)")"
        )

        let failedReplacement = try await client.loadModel(
            request(
                id: ModelID(),
                path: fixture.model.path,
                bookmark: Data([0xBA, 0xD0]),
                root: fixture.root.path
            )
        )
        try requireAccessRejected(failedReplacement, name: "failed replacement")

        let loadedStatus = try await client.runtimeStatus()
        try require(
            loadedStatus.state == .modelLoaded && loadedStatus.loadedModelID == modelID,
            "loaded status did not preserve the model ID"
        )

        let completionID = GenerationID()
        let completedEvents = try await collect(
            client.generate(
                GenerateRequest(
                    generationID: completionID,
                    modelID: modelID,
                    prompt: Self.completionPrompt,
                    systemPrompt: nil,
                    options: GenerationOptions(maxOutputTokens: 8)
                )
            )
        )
        try require(
            completedEvents.filter { $0.type == .generationCompleted }.count == 1,
            "stream completion was not delivered exactly once"
        )
        try require(
            completedEvents.filter { $0.type == .token }.map(\.tokenText) == ["xpc-boundary-canary"],
            "controlled stream canary was absent or duplicated"
        )
        await Task.yield()
        let bufferedCompletionEvents = try await client.recentEvents(for: completionID, after: 0)
        try require(
            bufferedCompletionEvents.filter { $0.type == .generationCompleted }.count == 1,
            "event buffer recorded a duplicate completion after the stream closed"
        )

        let cancellationID = GenerationID()
        let cancellationTask = try collectInTask(
            client.generate(
                GenerateRequest(
                    generationID: cancellationID,
                    modelID: modelID,
                    prompt: Self.holdPrompt,
                    systemPrompt: nil,
                    options: GenerationOptions(maxOutputTokens: 8)
                )
            )
        )
        try await waitUntil("held generation never started") {
            try await client.runtimeStatus().activeGenerationID == cancellationID
        }
        async let rejectedLoadDuringGeneration = client.loadModel(
            request(
                id: ModelID(),
                path: fixture.model.path,
                bookmark: fixture.modelBookmark,
                root: fixture.root.path
            )
        )
        async let rejectedUnloadDuringGeneration = client.unloadModel()
        let rejectedMutations = try await (
            rejectedLoadDuringGeneration,
            rejectedUnloadDuringGeneration
        )
        try require(
            rejectedMutations.0.status == .failed
                && rejectedMutations.0.error?.category == "generationActive",
            "model load was allowed underneath an active generation"
        )
        try require(
            rejectedMutations.1.status == .failed
                && rejectedMutations.1.error?.category == "generationActive",
            "model unload was allowed underneath an active generation"
        )
        let firstCancel = try await client.cancelGeneration(cancellationID)
        let secondCancel = try await client.cancelGeneration(cancellationID)
        let cancelledEvents = try await cancellationTask.value
        try require(firstCancel.status == .cancelled, "first cancellation was not acknowledged")
        try require(secondCancel.status == .notFound, "duplicate cancellation was not rejected")
        try require(
            (firstCancel.metrics?.cancellationLatencyMs ?? -1) >= 0
                && (firstCancel.metrics?.cancellationLatencyMs ?? .max) < 5_000,
            "cancellation did not report bounded model-quiescence latency"
        )
        try require(
            cancelledEvents.filter { $0.type == .generationCancelled }.count == 1,
            "cancel event was not delivered exactly once"
        )
        await Task.yield()
        let bufferedCancellationEvents = try await client.recentEvents(for: cancellationID, after: 0)
        try require(
            bufferedCancellationEvents.filter { $0.type == .generationCancelled }.count == 1,
            "event buffer recorded a duplicate cancellation after the stream closed"
        )

        if iteration == 1 {
            // Hold the coordinator after the Task is installed and
            // generationStarted is published, but before its gate allows model-
            // actor entry. Cancellation opens that exact gate only after marking
            // the Task cancelled; the following completion is the actor canary.
            let installRaceID = GenerationID()
            let installRaceTask = try collectInTask(
                client.generate(
                    GenerateRequest(
                        generationID: installRaceID,
                        modelID: modelID,
                        prompt: Self.installRacePrompt,
                        systemPrompt: nil,
                        options: GenerationOptions(maxOutputTokens: 8)
                    )
                )
            )
            try await waitUntil("install-race generation never reserved its slot") {
                try await client.runtimeStatus().activeGenerationID == installRaceID
            }
            let installRaceCancel = try await client.cancelGeneration(installRaceID)
            try require(
                installRaceCancel.status == .cancelled,
                "cancel-before-model-entry was not acknowledged"
            )
            _ = try await installRaceTask.value

            let installRaceProbeEvents = try await collect(
                client.generate(
                    GenerateRequest(
                        generationID: GenerationID(),
                        modelID: modelID,
                        prompt: Self.completionPrompt,
                        systemPrompt: nil,
                        options: GenerationOptions(maxOutputTokens: 8)
                    )
                )
            )
            try require(
                installRaceProbeEvents.filter { $0.type == .token }.map(\.tokenText)
                    == ["xpc-boundary-canary"],
                "a task entered the model actor after gated cancellation"
            )

            // A termination attempt can contend after ownership reservation but
            // before coordinator admission. XPC defers a real invalidation callback
            // until its outstanding generate invocation returns, so the DEBUG
            // control invokes the production handler with the exact captured owner.
            // The ordinary disconnect case below still proves real delivery.
            let reservationRaceID = GenerationID()
            let reservationRaceOwner = RuntimeClient()
            try await reservationRaceOwner.connect()
            let reservationRaceTask = try collectInTask(
                reservationRaceOwner.generate(
                    GenerateRequest(
                        generationID: reservationRaceID,
                        modelID: modelID,
                        prompt: Self.reservationRacePrompt,
                        systemPrompt: nil,
                        options: GenerationOptions(maxOutputTokens: 8)
                    )
                )
            )
            try await waitUntil("reservation-before-admission seam was not acknowledged") {
                try await client.runtimeLifecycleDebugStatus().reservationPausedGenerationID
                    == reservationRaceID
            }
            let terminationInvoked = try await client.triggerReservationTerminationProbe(
                reservationRaceID
            )
            try require(
                terminationInvoked,
                "DEBUG control did not invoke termination for the captured owner"
            )
            try await waitUntil("termination handler never entered the paused admission seam") {
                let status = try await client.runtimeLifecycleDebugStatus()
                return status.reservationTerminationHandlerEnteredGenerationID == reservationRaceID
                    && status.reservationAdmissionReleasedGenerationID == reservationRaceID
            }
            try await waitUntil("pre-admission termination never reached the coordinator") {
                let status = try await client.runtimeLifecycleDebugStatus()
                return status.reservationCancellationAttemptedGenerationID == reservationRaceID
                    && status.reservationCancellationStatus == .cancelled
            }
            try await waitUntil("pre-admission termination leaked the generation slot") {
                try await client.runtimeStatus().activeGenerationID == nil
            }
            _ = await reservationRaceTask.result
            reservationRaceOwner.disconnect()
        }

        let terminatedID = GenerationID()
        let terminatingClient = RuntimeClient()
        let terminationTask = try collectInTask(
            terminatingClient.generate(
                GenerateRequest(
                    generationID: terminatedID,
                    modelID: modelID,
                    prompt: Self.holdPrompt,
                    systemPrompt: nil,
                    options: GenerationOptions(maxOutputTokens: 8)
                )
            )
        )
        try await waitUntil("terminating client generation never started") {
            try await client.runtimeStatus().activeGenerationID == terminatedID
        }

        // A rejected second client must never become the recorded owner. If it
        // disconnects, the accepted first client's generation must remain live.
        let busyClient = RuntimeClient()
        try await busyClient.connect()
        let busyID = GenerationID()
        do {
            _ = try await collect(
                busyClient.generate(
                    GenerateRequest(
                        generationID: busyID,
                        modelID: modelID,
                        prompt: Self.holdPrompt,
                        systemPrompt: nil,
                        options: GenerationOptions(maxOutputTokens: 8)
                    )
                )
            )
            throw RuntimeXPCIntegrationError.assertion("second client generation was not rejected as busy")
        } catch let RuntimeClientError.generationRejected(response) {
            try require(
                response.status == .busy && response.generationID == busyID,
                "second client was rejected for a reason other than busy"
            )
        } catch let error as RuntimeXPCIntegrationError {
            throw error
        } catch {
            throw RuntimeXPCIntegrationError.assertion(
                "second client returned unexpected busy error: \(error.localizedDescription)"
            )
        }

        let foreignCancel = try await busyClient.cancelGeneration(terminatedID)
        try require(
            foreignCancel.status == .notFound,
            "a foreign connection cancelled the accepted owner's generation"
        )
        let rejectedGenerationCancel = try await busyClient.cancelGeneration(busyID)
        try require(
            rejectedGenerationCancel.status == .notFound,
            "a busy/rejected generation ID was accepted for cancellation"
        )
        busyClient.disconnect()
        await Task.yield()
        let statusAfterRejectedDisconnect = try await client.runtimeStatus()
        try require(
            statusAfterRejectedDisconnect.activeGenerationID == terminatedID,
            "disconnecting a rejected client cancelled the accepted owner's generation"
        )

        terminatingClient.disconnect()
        try await waitUntil("dropped client did not release the generation slot") {
            try await client.runtimeStatus().activeGenerationID == nil
        }
        _ = await terminationTask.result
        let terminationEvents = try await client.recentEvents(for: terminatedID, after: 0)
        try require(
            terminationEvents.filter { $0.type == .generationCancelled }.count == 1,
            "client termination did not cancel exactly once"
        )

        if iteration == 1 {
            // The old owner's model call completes while its invalidation handler
            // is paused after capturing ownership. Reusing the public ID during
            // that pause proves the handler also needs a private reservation epoch.
            let reusedID = GenerationID()
            let oldOwner = RuntimeClient()
            try await oldOwner.connect()
            let oldOwnerTask = try collectInTask(
                oldOwner.generate(
                    GenerateRequest(
                        generationID: reusedID,
                        modelID: modelID,
                        prompt: Self.staleTerminationPrompt,
                        systemPrompt: nil,
                        options: GenerationOptions(maxOutputTokens: 8)
                    )
                )
            )
            try await waitUntil("old reused-ID owner never started") {
                try await client.runtimeStatus().activeGenerationID == reusedID
            }
            oldOwner.disconnect()
            try await waitUntil("old termination handler never captured its reservation epoch") {
                try await client.runtimeLifecycleDebugStatus().staleTerminationCapturedGenerationID
                    == reusedID
            }
            try await waitUntil("old reused-ID generation did not complete") {
                try await client.runtimeStatus().activeGenerationID == nil
            }
            _ = await oldOwnerTask.result

            let successorTask = try collectInTask(
                client.generate(
                    GenerateRequest(
                        generationID: reusedID,
                        modelID: modelID,
                        prompt: Self.holdPrompt,
                        systemPrompt: nil,
                        options: GenerationOptions(maxOutputTokens: 8)
                    )
                )
            )
            try await waitUntil("reused-ID successor never started") {
                try await client.runtimeStatus().activeGenerationID == reusedID
            }
            try await waitUntil("stale termination handler did not target the admitted successor epoch") {
                let status = try await client.runtimeLifecycleDebugStatus()
                return status.staleSuccessorAdmittedGenerationID == reusedID
                    && status.staleCancellationAttemptedGenerationID == reusedID
                    && status.staleCancellationStatus == .notFound
            }
            let reusedStatus = try await client.runtimeStatus()
            try require(
                reusedStatus.activeGenerationID == reusedID,
                "stale owner termination cancelled the reused-ID successor"
            )
            let successorCancel = try await client.cancelGeneration(reusedID)
            try require(successorCancel.status == .cancelled, "reused-ID successor was not live")
            _ = try await successorTask.value
        }

        async let concurrentLoad = client.loadModel(
            request(
                id: ModelID(),
                path: fixture.model.path,
                bookmark: fixture.modelBookmark,
                root: fixture.root.path
            )
        )
        async let concurrentUnload = client.unloadModel()
        let concurrentResponses = try await (concurrentLoad, concurrentUnload)
        try require(
            concurrentResponses.0.status == .loaded,
            "concurrent load did not complete exactly once"
        )
        try require(
            [.unloaded, .noModelLoaded].contains(concurrentResponses.1.status),
            "concurrent unload returned an invalid state"
        )

        let finalModelID = ModelID()
        let finalLoad = try await client.loadModel(
            request(
                id: finalModelID,
                path: fixture.model.path,
                bookmark: fixture.modelBookmark,
                root: fixture.root.path
            )
        )
        try require(finalLoad.status == .loaded, "post-concurrency load failed")

        try await client.restartRuntimeService()
        let reconnected = try await client.runtimeStatus()
        try require(
            reconnected.loadedModelID == finalModelID,
            "reconnected client did not reach the same hosted service state"
        )

        _ = try await client.unloadModel()

        return [
            "statusRoundTrip": true,
            "nilBookmarkRejected": true,
            "invalidBookmarkRejected": true,
            "nilManagedIdentityRejected": true,
            "staleBookmarkRejected": true,
            "samePathReplacementRejected": true,
            "managedRootEscapeRejected": true,
            "controlledModelLoaded": true,
            "streamCompletedOnce": true,
            "cancelExactlyOnce": true,
            "cancelBeforeTaskInstall": true,
            "reservationBeforeAdmission": true,
            "foreignCancelRejected": true,
            "reusedGenerationID": true,
            "clientTermination": true,
            "concurrentLoadUnload": true,
            "reconnect": true,
            "resourceBound": true,
        ]
    }

    private func request(
        id: ModelID,
        path: String,
        bookmark: Data?,
        root: String?,
        identity: ModelDirectoryIdentity? = nil,
        includeCurrentIdentity: Bool = true
    ) -> LoadModelRequest {
        LoadModelRequest(
            modelID: id,
            modelPath: path,
            displayName: "Generated XPC lifecycle model",
            modelBookmark: bookmark,
            managedRootPath: root,
            modelDirectoryIdentity: identity ?? (includeCurrentIdentity
                ? ModelDirectoryIdentity(url: URL(fileURLWithPath: path, isDirectory: true))
                : nil)
        )
    }

    private func requireAccessRejected(_ response: LoadModelResponse, name: String) throws {
        try require(response.status == .failed, "\(name) unexpectedly loaded")
        try require(response.error?.category == "invalidRequest", "\(name) did not fail as invalidRequest")
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RuntimeXPCIntegrationError.assertion(message) }
    }

    private func waitUntil(
        _ timeoutMessage: String,
        predicate: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await predicate() { return }
            await Task.yield()
        }
        throw RuntimeXPCIntegrationError.timeout(timeoutMessage)
    }

    private func collect(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func collectInTask(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>
    ) throws -> Task<[GenerationEvent], Error> {
        Task { try await collect(stream) }
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraXPCIntegration-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("ManagedModels", isDirectory: true)
        let model = root.appendingPathComponent("controlled-small-model", isDirectory: true)
        let escape = base.appendingPathComponent("outside-managed-root", isDirectory: true)
        let symlinkEscape = root.appendingPathComponent("inside-root-link", isDirectory: true)
        let staleOriginal = root.appendingPathComponent("stale-model", isDirectory: true)
        let staleMoved = root.appendingPathComponent("stale-model-moved", isDirectory: true)
        let recreatedModel = root.appendingPathComponent("recreated-model", isDirectory: true)

        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: escape, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleOriginal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recreatedModel, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkEscape, withDestinationURL: escape)
        try Self.markerData.write(to: model.appendingPathComponent(Self.markerName), options: .atomic)
        try Self.markerData.write(to: escape.appendingPathComponent(Self.markerName), options: .atomic)
        try Self.markerData.write(to: staleOriginal.appendingPathComponent(Self.markerName), options: .atomic)
        try Self.markerData.write(to: recreatedModel.appendingPathComponent(Self.markerName), options: .atomic)

        let modelAccess = try Self.transferableBookmark(for: model)
        let escapeAccess = try Self.transferableBookmark(for: escape)
        let staleAccess = try Self.transferableBookmark(for: staleOriginal)
        let recreatedAccess = try Self.transferableBookmark(for: recreatedModel)
        guard let recreatedOriginalIdentity = ModelDirectoryIdentity(url: recreatedModel) else {
            throw RuntimeXPCIntegrationError.assertion("recreated fixture identity could not be captured")
        }
        try FileManager.default.moveItem(at: staleOriginal, to: staleMoved)
        try FileManager.default.removeItem(at: recreatedModel)
        try FileManager.default.createDirectory(at: recreatedModel, withIntermediateDirectories: true)
        try Self.markerData.write(to: recreatedModel.appendingPathComponent(Self.markerName), options: .atomic)

        return Fixture(
            base: base,
            root: root,
            model: model,
            escape: escape,
            symlinkEscape: symlinkEscape,
            recreatedModel: recreatedModel,
            modelBookmark: modelAccess.bookmark,
            escapeBookmark: escapeAccess.bookmark,
            staleBookmark: staleAccess.bookmark,
            recreatedBookmark: recreatedAccess.bookmark,
            recreatedOriginalIdentity: recreatedOriginalIdentity,
            staleOriginalPath: staleOriginal.path,
            scopedURLs: [
                modelAccess.scopedURL,
                escapeAccess.scopedURL,
                staleAccess.scopedURL,
                recreatedAccess.scopedURL,
            ]
        )
    }

    /// Mint the cross-process bookmark while the app holds its own security scope.
    /// The scoped bookmark remains tied to the app signature; the plain bookmark
    /// carries the active sandbox extension to the differently signed XPC service.
    private static func transferableBookmark(for url: URL) throws -> (bookmark: Data, scopedURL: URL) {
        let persistent = try url.bookmarkData(options: [.withSecurityScope])
        var stale = false
        let scopedURL = try URL(
            resolvingBookmarkData: persistent,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale, scopedURL.startAccessingSecurityScopedResource() else {
            throw RuntimeXPCIntegrationError.assertion("test fixture security scope could not be activated")
        }
        do {
            let bookmark = try scopedURL.bookmarkData(options: [])
            return (bookmark, scopedURL)
        } catch {
            scopedURL.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private struct Fixture {
        let base: URL
        let root: URL
        let model: URL
        let escape: URL
        let symlinkEscape: URL
        let recreatedModel: URL
        let modelBookmark: Data
        let escapeBookmark: Data
        let staleBookmark: Data
        let recreatedBookmark: Data
        let recreatedOriginalIdentity: ModelDirectoryIdentity
        let staleOriginalPath: String
        let scopedURLs: [URL]

        func releaseScopes() {
            for url in scopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
#endif
