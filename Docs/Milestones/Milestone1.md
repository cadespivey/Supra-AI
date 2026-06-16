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

## Known Limitations

- The runtime XPC service is sandboxed with no file-access entitlement, so a model folder selected by the (separately sandboxed) app is not yet readable by the service. Cross-process model access — passing the security-scoped bookmark to the service, or relaxing the service sandbox — is required before a real model loads on device.
- Chat persistence runs on the main actor (one fetch per streamed token); fine for the vertical slice, a candidate for moving off-main later.

## Next Engineering Slice

Run the Milestone 1 validation suite end-to-end: execute the six suite prompts through the loaded model, evaluate them with SupraDiagnostics, and persist/render the validation report. Resolve the sandboxed XPC model-file access so a real model can be loaded first.
