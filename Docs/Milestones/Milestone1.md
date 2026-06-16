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
- SupraRuntimeService now has the Phase 7 service files, a buffered event stream, single-active-generation enforcement, placeholder token streaming, metrics events, cancellation, and recent-event replay.

## Next Engineering Slice

Replace the placeholder generation script inside the service with the first MLX-backed `MLXModelController`, then add model-folder selection and the first persisted global chat flow.
