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
directory inside the existing Codable load request (`modelBookmark: Data?`) and
pins the authorized directory's device/inode (`modelDirectoryIdentity`). The same
contract applies to chat and embedding model loads.

Mechanism:
1. The app persists a `.withSecurityScope` bookmark per model (`ModelRecord.bookmarkData`) so it can reopen the folder across launches.
2. At load time the app resolves that bookmark and calls `startAccessingSecurityScopedResource()` — it must be *actively holding access* (`SecurityScopedModelAccess`).
3. While holding access it mints a **plain** bookmark: `url.bookmarkData(options: [])`. A plain bookmark created by a sandboxed process embeds a transferable, kernel-issued sandbox extension carrying the app's current read access.
4. While that authority is active, the app captures the directory's device and inode immediately before and after minting the plain bookmark. The two samples must match; the request carries the pre-mint identity. Managed-root requests never omit it.
5. The service resolves the bookmark with `options: []`, calls `startAccessingSecurityScopedResource()`, canonicalizes the target, and verifies the current device/inode before reading. It rechecks that identity immediately before committing the asynchronously loaded chat or embedding container. The granted scope covers the directory **recursively**, so every shard is readable, and `stopAccessing` is deferred until the entire model-load await returns.

Only ~1 KB of bookmark bytes cross the wire — MLX still `mmap`s the files itself
in-process, exactly as before. The service stays sandboxed and needs **no**
file-access entitlement.

### Why not the obvious variants
- **`.withSecurityScope` bookmark over XPC** — fails. Security-scoped/app-scoped bookmarks are HMAC-bound to the *creating app's* code-signing identity; the differently-signed service gets `NSCocoaErrorDomain 259` and zero access.
- **App Group + shared bookmark** — same bundle-id binding; the shared container lets both processes read the same bytes but only the app can turn them back into access. Adds signing surface for no benefit.
- **Raw FD / `NSFileHandle` / byte streaming** — MLX opens the directory by path itself; there is no API to inject FDs, and streaming ~20 GB over XPC would destroy `mmap` and roughly double memory/IO.

## Fail-closed access policy

There is no raw-path or unsandboxed fallback. A nil, invalid, moved/stale, or
non-activatable bookmark is rejected before MLX sees the directory. The service
canonicalizes both the bookmark target and requested path after symlink
resolution and requires an exact match. App-managed downloads additionally carry
their managed-root path; the canonical target must be a child of that root.
Managed-root requests without a filesystem identity fail closed. Whenever an
identity is present, it is checked even if Foundation reports the bookmark as
non-stale, so deleting and recreating a directory at the same path cannot reuse
an older authorization. The service repeats that check after the loader returns
and before publishing loaded state, so a delete/recreate during an async load also
fails without replacing the previously committed container.

The device/inode pin identifies the directory entry; it is not a hash or immutable
snapshot of every file below it. In-place writes, or replacement of a shard within
the same directory while retaining the directory inode, are outside this check.
Accordingly this control does not claim content integrity against a hostile local
filesystem. Protected real-weight qualification must still exercise the loader's
multi-file behavior, and downloaded-model integrity needs a separate signed-manifest
or content-digest control if that becomes part of the threat model.

Foundation can report an otherwise valid plain transferable bookmark as stale when
the differently signed service resolves it. Staleness is therefore fail-closed at
the authorization boundary: a stale bookmark is rejected if its resolved target
differs from the requested canonical path or no longer exists. A signer-stale
bookmark is accepted only when its sandbox extension activates, the target matches
exactly, it remains a directory, managed-root containment passes, and its current
device/inode matches the identity captured by the app. A stale result without a
matching identity is rejected. This treats the raw stale bit as advisory across
the signing boundary without treating a canonical path alone as object identity.
This exception applies only to the differently signed service resolving the fresh
plain bookmark. If the original app signer resolves its persisted security-scoped
bookmark as stale, the load is rejected and the user must re-add the folder; the
app never refreshes that stale authority in place.

If bookmark transfer regresses on a future macOS release, loading is unavailable
until the user re-selects/re-downloads the model or the signed boundary is fixed.
Do not remove the service sandbox or add broad file entitlements as a workaround.

## Must be verified on a real device
The hosted integration gate exercises bookmark transfer through the embedded,
ad-hoc-signed service with no service file-access entitlement. Release qualification
still must:
1. Run `Scripts/run-hosted-xpc-lifecycle.sh` on the protected macOS runner and retain its signed-boundary evidence.
2. Load a real ~20 GB multi-shard model end-to-end and confirm the recursive scope covers every shard through the full `mmap` load without being reclaimed under memory pressure.
3. After a Developer ID + notarized archive, inspect the embedded service: `codesign -d --entitlements - SupraAI.app/Contents/XPCServices/SupraRuntimeService.xpc` — `com.apple.security.app-sandbox` must still be `true` with no file-access entitlement added.
