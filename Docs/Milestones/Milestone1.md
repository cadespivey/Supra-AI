# Milestone 1

Initial repository skeleton for the local 32B MLX runtime vertical slice.

## Current Status

- Workspace and Xcode project shell created.
- macOS SwiftUI app source shell created.
- Swift-only XPC runtime service source shell created.
- Local Swift packages created.
- SupraCore domain primitives implemented.
- SupraRuntimeInterface protocol and DTO contracts implemented.
- Validation suite and default system prompt resources added.
- GRDB.swift, MLX Swift, and MLX Swift LM added through Swift Package Manager with exact pins.
- Xcode 27 beta Metal Toolchain installed locally for MLX Metal shader compilation.
- SupraDiagnostics now decodes the Milestone 1 validation suite, evaluates mechanical/rule checks, redacts local paths, and renders Markdown/JSON validation reports.
- SupraStore now has GRDB migrations, records, repositories, debug reset support, and focused package tests for Milestone 1 flows.
- SupraRuntimeInterface now includes a Codable-over-XPC bridge contract for the app/runtime service boundary.
- SupraRuntimeClient now connects through the XPC bridge, exposes async runtime calls, streams generation events, and has fake-service tests.
- The app shell now refreshes live runtime status through the client and exposes it in Diagnostics.
- SupraRuntimeService now has the Phase 7 service files, a buffered event stream, single-active-generation enforcement, MLX-backed model loading/generation, metrics events, cancellation, and recent-event replay.
- Swift Package Manager now pins `swift-tokenizers-mlx` so local MLX model directories can be loaded with tokenizer support.
- SupraSessions package added: `ModelLibrary` (registers local model folders and loads the active model into the runtime) and `GlobalChatController` (persisted send/stream/cancel/fail flow), with focused tests against a stub runtime client and an in-memory store.
- SupraStore gained `ChatRepository.markVariantFailed` so a failed generation records a `failed` message status.
- The app shell now has a Models tab (folder selection via `NSOpenPanel` with a security-scoped bookmark, load-state feedback) and a Global Chats tab (chat selector, streaming transcript, send/stop composer) wired to the shared runtime client and on-disk store.
- Cross-process model-file access implemented: `LoadModelRequest` carries a plain transferable bookmark (`modelBookmark`); the app mints it while holding its own security scope (`SecurityScopedModelAccess`) and the sandboxed service resolves it + holds the scope across the full load. The subsequent security hardening rejects raw paths and invalid/stale bookmarks. Design + on-device verification steps are recorded in `Docs/Architecture/RuntimeFileAccess.md`.
- SupraSessions gained `ValidationRunner` (runs a `ValidationSuite` through the runtime, gathers mechanical signals, evaluates with SupraDiagnostics, persists the run/tests, renders Markdown/JSON), the bundled Milestone 1 suite resource + loader, and a `ValidationRunController` surfaced as a "Run Suite" action on the Models tab. Covered by passing/partial/failed runner tests.
- The bundled `default-system-prompt-v1` is now wired into generation: `DefaultSystemPrompt` loads it and `GlobalChatController`/`ValidationRunController` send it with every chat and validation generation.
- Diagnostics now shows validation history: `ValidationHistoryController` reads persisted runs/tests and `DiagnosticsView` lists each run with expandable per-test results.

## Known Limitations

- The plain-bookmark cross-process access is exercised by the hosted signed-XPC lifecycle gate. A real protected MLX fixture and large-model memory qualification remain release gates; there is no unsandboxed fallback.
- Chat persistence runs on the main actor (one fetch per streamed token); fine for the vertical slice, a candidate for moving off-main later.

## Next Engineering Slice

On device with a real 32B MLX model: verify the model-load path (per `Docs/Architecture/RuntimeFileAccess.md`), run the bundled suite end-to-end, and capture the first real validation report. This is the manual step that closes the Milestone 1 vertical slice.
