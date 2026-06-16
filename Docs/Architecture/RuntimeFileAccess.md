# Runtime Model-File Access

The app is sandboxed and the MLX runtime runs in a **separate, also-sandboxed**
bundled XPC service (`ai.supra.SupraAI.SupraRuntimeService`) so a crash, OOM, or
compromise in model parsing cannot take down the UI or escape the service's
sandbox. That isolation creates a problem: the service must read a 32B model
directory (~18–20 GB across `config.json`, `tokenizer.json`, and many
`*.safetensors` shards) that the **app** selected via `NSOpenPanel`, but the
service has no file-access entitlement of its own.

## Decision: transfer a plain bookmark over XPC

The app hands the service a **plain, non-security-scoped bookmark** of the model
directory inside the existing Codable `LoadModelRequest` (`modelBookmark: Data?`).

Mechanism:
1. The app persists a `.withSecurityScope` bookmark per model (`ModelRecord.bookmarkData`) so it can reopen the folder across launches.
2. At load time the app resolves that bookmark and calls `startAccessingSecurityScopedResource()` — it must be *actively holding access* (`SecurityScopedModelAccess`).
3. While holding access it mints a **plain** bookmark: `url.bookmarkData(options: [])`. A plain bookmark created by a sandboxed process embeds a transferable, kernel-issued sandbox extension carrying the app's current read access.
4. The service resolves that bookmark with `options: []`, calls `startAccessingSecurityScopedResource()`, and reads the directory. The granted scope covers the directory **recursively**, so every shard is readable, and `stopAccessing` is deferred until the entire `loadModelContainer` await returns.

Only ~1 KB of bookmark bytes cross the wire — MLX still `mmap`s the files itself
in-process, exactly as before. The service stays sandboxed and needs **no**
file-access entitlement.

### Why not the obvious variants
- **`.withSecurityScope` bookmark over XPC** — fails. Security-scoped/app-scoped bookmarks are HMAC-bound to the *creating app's* code-signing identity; the differently-signed service gets `NSCocoaErrorDomain 259` and zero access.
- **App Group + shared bookmark** — same bundle-id binding; the shared container lets both processes read the same bytes but only the app can turn them back into access. Adds signing surface for no benefit.
- **Raw FD / `NSFileHandle` / byte streaming** — MLX opens the directory by path itself; there is no API to inject FDs, and streaming ~20 GB over XPC would destroy `mmap` and roughly double memory/IO.

## Fallback: unsandboxed service
If on-device testing shows the plain-bookmark transfer is broken (the
security-scoped bookmark APIs have regressed on recent macOS betas), remove
`com.apple.security.app-sandbox` from `SupraRuntimeService.entitlements`. The raw
`modelPath` flow then works with zero bookmark plumbing (the current code falls
back to `modelPath` when `modelBookmark` is `nil`). Cost: the service that parses
untrusted model files loses filesystem confinement, and Mac App Store is
foreclosed. Treat this as a last resort. Hardened Runtime stays on either way
(notarization needs Hardened Runtime, not the sandbox).

## Must be verified on a real device
This was implemented from Apple documentation + DTS forum guidance and **builds
clean, but the sandbox behavior cannot be exercised in CI**. Before relying on it:
1. Confirm the sandboxed service resolves a plain bookmark and reads a file with **no** file-access entitlement (a ~30-minute spike). If it fails, switch to the fallback.
2. Load a real ~20 GB multi-shard model end-to-end and confirm the recursive scope covers every shard through the full `mmap` load without being reclaimed under memory pressure.
3. After a Developer ID + notarized archive, inspect the embedded service: `codesign -d --entitlements - SupraAI.app/Contents/XPCServices/SupraRuntimeService.xpc` — `com.apple.security.app-sandbox` must still be `true` with no file-access entitlement added.
