# Runtime XPC security and qualification

## Signed boundary decision (D-09)

The runtime uses only supported Foundation APIs:

- The service applies `NSXPCConnection.setCodeSigningRequirement(_:)` to every accepted
  connection before publishing its exported object, authenticating the app client.
- The app applies the same public API to authenticate the embedded service.
- Release requirements bind the exact app/service identifiers, the Apple generic anchor,
  and Team ID `2DP657YB3K`.
- Debug requirements bind exact identifiers so the hosted integration test can use ad-hoc
  signatures without weakening the Release rule.

No audit-token reflection, dynamic symbol lookup, private Security framework entry point,
or undocumented selector is used. `Scripts/verify-runtime-xpc-boundary.sh` fails if one is
introduced. It checks the source plist and the signed embedded service. A distribution-signed
service must contain exactly `com.apple.security.app-sandbox`; it has no user-file picker or
network entitlement. Xcode UI-test products may contain only the three known ad-hoc test-runner
exceptions in addition to the sandbox entitlement, and never satisfy the distribution branch.

The connection-level placement is deliberate: the equivalent service-listener method
segfaults inside `libxpc` on the macOS 27 beta qualification host. Applying the requirement
to the accepted connection preserves pre-message authentication and keeps the test path on
documented Foundation API.

## Hosted lifecycle gate

`Scripts/run-hosted-xpc-lifecycle.sh` builds an ad-hoc-signed app and embedded service, runs
the exact `SupraAIUITests/RuntimeXPCIntegrationTests` selector, verifies both signatures and
designated identifiers, and leaves the service entitlement surface unchanged.

The test app generates a content-free DEBUG-only lifecycle model directory at runtime. No
weights or user content are committed. Across 20 iterations it proves:

1. status round-trips through the real embedded service;
2. nil, invalid, stale/moved bookmarks, direct root escapes, and in-root symlinks to an
   outside target are rejected;
3. a valid transferable bookmark reaches the controlled load path;
4. stream completion and cancellation are each delivered exactly once in both the live stream
   and the post-terminal event buffer;
5. cancellation keeps the generation slot closed until the model actor and old task quiesce,
   and reports measured monotonic latency instead of a synthetic zero;
6. a rejected busy client's disconnect cannot steal ownership or cancel the accepted client;
7. dropping the owning XPC connection during generation cancels the orphan once;
8. load/unload and generation reservations are atomic, concurrent model mutations serialize,
   and a failed replacement preserves the previously loaded model; and
9. connection invalidation/reconnect reaches the same hosted service state.

The DEBUG lifecycle model tests process/protocol/state ownership and intentionally does not
claim MLX numerical correctness. “Reconnect” here means a new client connection to the same
launchd-managed service; it does not claim an externally forced service-process kill. Release
qualification must separately exercise a real process kill/relaunch, load the protected small
MLX fixture and supported large-model scenario, and use Developer-ID/Team-ID signatures. Weights
and signing credentials remain outside the repo.

## Sanitizer and resource matrix

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/run-runtime-sanitizer.sh thread
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/run-runtime-sanitizer.sh address
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/run-runtime-sanitizer.sh undefined
```

The lifecycle harness reads `RUSAGE_SELF` inside the XPC service through runtime status and
enforces at most 256 MiB XPC maximum-resident-set growth across its 20 content-free iterations.
The controlled stream caps output at eight tokens and every held generation has a five-second
fail-closed deadline. Actual model peak memory depends on the protected fixture and must be
recorded per release candidate.

## Local qualification record — 2026-07-13

Toolchain: Xcode beta `27A5194q`, macOS arm64.

- Exact `SupraAIUITests/RuntimeXPCIntegrationTests` selector: 2/2 passed, including 20/20
  hosted lifecycle iterations and switch binding/Tab/Shift-Tab traversal.
- Runtime interface and client packages: 4/4 each; focused Sessions model-load tests: 5/5;
  focused document setup tests: 5/5.
- Runtime client package under Thread Sanitizer and Address Sanitizer: 4/4 each.
- Source and ad-hoc signed-product boundary/entitlement gates: passed.
- Release app build: succeeded with no warnings in the changed runtime/UI sources. The base
  revision still emits three unique first-party warnings outside this work package, plus MLX
  dependency and Xcode metadata warnings; repository-wide zero-warning closure is tracked by
  the warning-baseline work package.

Hosted app TSan/ASan/UBSan, Developer-ID negative-peer tests, forced process kill/relaunch,
and protected real-weight small/large model profiling remain release-environment qualifications;
they are not represented as passing in this record.

Record unsupported sanitizer/runtime combinations as exclusions; do not relabel an omitted
run as coverage. Any reproducible sanitizer or resource defect becomes its own RED-first
work package.
