# Background Auto-Updater (Sparkle) Implementation Plan

**Goal:** Replace the "open the DMG in a browser, drag to Applications" flow with (a) a persistent in-app "update available" indicator and (b) a real background download + install that prompts the user to relaunch when ready.

**Architecture:** Adopt the [Sparkle 2](https://sparkle-project.org) framework (the macOS standard) instead of hand-rolling a privileged installer. Supra AI is **sandboxed + hardened-runtime + notarized**, so a custom updater that writes into `/Applications` is not viable (the sandbox forbids it and Apple won't notarize a privileged self-installer). Sparkle 2 supports sandboxed apps via its bundled XPC services (`Downloader.xpc`, `Installer.xpc`) and an EdDSA-signed appcast. We keep the existing GitHub Releases as the asset host, add a generated `appcast.xml`, and wire Sparkle's `SPUStandardUpdaterController` behind our existing `UpdateController` surface so the SwiftUI stays declarative.

**Tech Stack:** Swift 6, SwiftUI, Sparkle 2 (SwiftPM `sparkle-project/Sparkle`), EdDSA (ed25519) appcast signing, GitHub Releases, the existing `Scripts/release.sh` notarize pipeline.

---

## Current State (verified)

- `Packages/SupraSessions/Sources/SupraSessions/UpdateChecker.swift` — `ReleaseUpdateChecker` (pure version compare) + `UpdateController` (`@MainActor ObservableObject`, opt-in GitHub `/releases/latest` poll). Today `available` just yields a `downloadURL`.
- `Apps/SupraAI/SupraAI/SettingsView.swift:97-117` — the only update UI: a "Download" button that calls `NSWorkspace.shared.open(downloadURL)` (the clunky browser→DMG→drag flow to replace).
- `Apps/SupraAI/SupraAI/AppEnvironment.swift:62,134` — `UpdateController` is constructed and `checkOnLaunchIfEnabled()` is called.
- `Apps/SupraAI/SupraAI/MainShellView.swift` — top-level shell; the persistent indicator goes here.
- App is **sandboxed**: `Apps/SupraAI/SupraAI/SupraAI.entitlements` has `com.apple.security.app-sandbox = true`, `network.client`, app-scope bookmarks, user-selected r/w.
- Release: `Scripts/release.sh` archives → notarizes app → builds+notarizes DMG → zips app → `gh release upload` (DMG + zip). Team `2DP657YB3K`, notary profile `supra-notary`.
- **No Sparkle dependency yet.**

## Design Decisions & Tradeoffs

1. **Sparkle vs. hand-rolled.** Hand-rolling background install into `/Applications` from a sandboxed app is effectively impossible without a privileged helper + user auth prompt (and is hostile to notarization). Sparkle 2 solves exactly this with audited, notarization-friendly XPC services. **Decision: Sparkle 2.**
2. **Appcast hosting.** Sparkle needs an `appcast.xml` feed. We host it as a release asset / GitHub Pages file and point `SUFeedURL` at the raw URL. The existing GitHub-API `/releases/latest` poll in `UpdateController` is kept ONLY as a lightweight "is something newer?" signal for the persistent badge; Sparkle owns the actual download/install. (Alternative: drop our poll entirely and read Sparkle's `SPUUpdater.canCheckForUpdates`/session state. We keep both: our poll drives the always-visible badge without needing Sparkle to be mid-session.)
3. **Sandbox XPC.** Must add Sparkle's XPC services to the app bundle and the temporary-exception entitlements Sparkle documents (`com.apple.security.temporary-exception.mach-lookup.global-name` for `…-spks` / `…-spki`). These are notarization-compatible (Sparkle ships notarized services).
4. **Signing the appcast.** Sparkle verifies updates with an EdDSA key that is independent of Apple code signing. Generate the key once (`generate_keys`), store the public key in `Info.plist` (`SUPublicEDKey`), keep the private key OUT of the repo (Keychain). `release.sh` signs each archive with `sign_update`.
5. **Keep `UpdateController` as the SwiftUI seam.** We do NOT expose Sparkle types to views. `UpdateController` gains a thin bridge to an injected `UpdaterProviding` protocol so unit tests stay Sparkle-free and views keep binding to `@Published` state.

## Risks / Open Questions

- **R1 (signing key custody):** the EdDSA private key must live in the release operator's Keychain, never the repo. If lost, all future updates must re-key (users on the old key won't auto-update). Mitigation: document key backup in `Scripts/`.
- **R2 (sandbox entitlement drift):** Sparkle's required temporary-exception entitlements occasionally change between major versions; pin Sparkle to an exact tag and re-test the sandbox install on every Sparkle bump.
- **R3 (appcast hosting availability):** if the feed URL 404s, auto-update silently stops. Mitigation: health-check the feed URL in `release.sh` after upload.
- **Q1:** Host appcast on GitHub Pages, or as a `releases/latest` asset with a stable `download/latest/appcast.xml` URL? (Pages is simpler to keep at a stable URL.) **Assume GitHub Pages `gh-pages` branch → `https://cadespivey.github.io/Supra-AI/appcast.xml`.**
- **Q2:** Delta updates (Sparkle supports binary deltas) — defer (YAGNI) until app size is a complaint.

---

### Task 1: Add Sparkle SwiftPM dependency to the app target

**Objective:** Make the Sparkle framework available to the `SupraAI` app target, pinned to an exact version.

**Files:**
- Modify: `Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj` (add `XCRemoteSwiftPackageReference` for `https://github.com/sparkle-project/Sparkle`, exact `2.6.4`; add `Sparkle` to the `SupraAI` target's `Frameworks` build phase + `packageProductDependencies`).
- Modify: `SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved` (Xcode regenerates on resolve).

**Step 1: Add the package in Xcode (scripted via xcodebuild is unreliable for pbxproj; do it in the IDE or with a careful pbxproj edit).**
- File → Add Package Dependencies → `https://github.com/sparkle-project/Sparkle` → Exact `2.6.4` → add `Sparkle` to target `SupraAI`.

**Step 2: Verify resolution**

Run: `xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI -showBuildSettings >/dev/null && grep -i sparkle SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved`
Expected: a `sparkle` entry pinned at `2.6.4`.

**Step 3: Commit**

```bash
git add Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build: add Sparkle 2.6.4 dependency to the app target"
```

---

### Task 2: Generate the EdDSA signing key (one-time, operator machine)

**Objective:** Create the update-signing keypair; record the public key for `Info.plist`.

**Step 1: Generate keys**

Run: `./build/DerivedData/SourcePackages/checkouts/Sparkle/bin/generate_keys` (path after first resolve; or download the Sparkle release tools).
Expected: prints a public key like `SUPublicEDKey` value; stores the private key in the login Keychain.

**Step 2: Capture the public key** into `Scripts/sparkle-public-key.txt` (public only — safe to commit) for reference.

**Step 3: Commit (public key only)**

```bash
git add Scripts/sparkle-public-key.txt
git commit -m "build: record Sparkle EdDSA public key (private key stays in Keychain)"
```

---

### Task 3: Add Sparkle Info.plist keys + sandbox entitlements

**Objective:** Configure the feed URL, public key, and the sandbox XPC entitlements Sparkle requires.

**Files:**
- Modify: `Apps/SupraAI/SupraAI/Info.plist` (or `GENERATE_INFOPLIST_FILE` INFOPLIST_KEY_* build settings in `project.pbxproj`). Add:
  - `SUFeedURL` = `https://cadespivey.github.io/Supra-AI/appcast.xml`
  - `SUPublicEDKey` = `<public key from Task 2>`
  - `SUEnableInstallerLauncherService` = `YES` (sandboxed installs)
  - `SUEnableAutomaticChecks` = `NO` (we drive checks ourselves / via our toggle)
- Modify: `Apps/SupraAI/SupraAI/SupraAI.entitlements` — add the Sparkle sandbox temporary-exceptions:
  ```xml
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array>
      <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
      <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
  </array>
  ```

**Step 1: Apply the plist + entitlement edits.**

**Step 2: Verify the app still builds (Debug)**

Run: `xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -1`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Apps/SupraAI/SupraAI/Info.plist Apps/SupraAI/SupraAI/SupraAI.entitlements Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj
git commit -m "build: Sparkle Info.plist feed/key + sandbox XPC entitlements"
```

---

### Task 4: Define an `UpdaterProviding` seam in SupraSessions (Sparkle-free, testable)

**Objective:** Let `UpdateController` drive a background install without importing Sparkle into the testable package.

**Files:**
- Create: `Packages/SupraSessions/Sources/SupraSessions/Updater/UpdaterProviding.swift`
- Test: `Packages/SupraSessions/Tests/SupraSessionsTests/UpdaterProvidingTests.swift`

**Step 1: Write the protocol + a stub-driven state machine**

```swift
import Foundation

/// The lifecycle the UI renders, independent of Sparkle.
public enum UpdateInstallPhase: Equatable, Sendable {
    case idle
    case checking
    case available(version: String)
    case downloading(fraction: Double)
    case readyToInstall(version: String)   // downloaded; needs relaunch
    case failed(message: String)
}

/// Abstraction over the concrete updater (Sparkle in the app; a stub in tests).
@MainActor
public protocol UpdaterProviding: AnyObject {
    var phase: UpdateInstallPhase { get }
    var onPhaseChange: ((UpdateInstallPhase) -> Void)? { get set }
    func checkForUpdates()
    func downloadAndInstall()        // begins background download → readyToInstall
    func relaunchToInstall()         // quits + installs + relaunches
}
```

**Step 2: Write a failing test** (`UpdaterProvidingTests`) using a `StubUpdater` that transitions `idle → checking → available → downloading → readyToInstall` and asserts `UpdateController` mirrors each phase.

**Step 3: Run** `swift test --filter UpdaterProvidingTests` → expect FAIL (controller doesn't observe yet).

**Step 4–5:** Implement (Task 5) then re-run to green. **Commit.**

---

### Task 5: Extend `UpdateController` to surface install phase + actions

**Objective:** Add `@Published var installPhase` and `downloadAndInstall()` / `relaunchToInstall()` that forward to an injected `UpdaterProviding`, keeping the existing GitHub poll for the badge.

**Files:**
- Modify: `Packages/SupraSessions/Sources/SupraSessions/UpdateChecker.swift`
- Test: `Packages/SupraSessions/Tests/SupraSessionsTests/UpdaterProvidingTests.swift`

**Step 1:** Add an optional `updater: UpdaterProviding?` init param (default `nil`, so existing tests/usages compile). Mirror `updater.phase` into a new `@Published public private(set) var installPhase: UpdateInstallPhase` via `onPhaseChange`. Add passthrough methods guarded on `updater != nil`.

**Step 2:** Run the full suite: `swift test` → expect existing 258 still green + new phase tests green.

**Step 3: Commit.**

---

### Task 6: Implement the Sparkle-backed `SparkleUpdater` in the app target

**Objective:** Concrete `UpdaterProviding` that wraps `SPUUpdater` + `SPUStandardUserDriver` and maps Sparkle delegate callbacks to `UpdateInstallPhase`.

**Files:**
- Create: `Apps/SupraAI/SupraAI/Updater/SparkleUpdater.swift`
- Modify: `Apps/SupraAI/SupraAI/AppEnvironment.swift` (construct `SparkleUpdater`, inject into `UpdateController`).

**Step 1:** Implement `final class SparkleUpdater: NSObject, UpdaterProviding, SPUUpdaterDelegate, SPUStandardUserDriverDelegate`. Own an `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)`. Map: `didFindValidUpdate → .available`, download progress → `.downloading(fraction:)`, `didExtractUpdate`/ready → `.readyToInstall`, `didAbortWithError → .failed`. `relaunchToInstall()` calls the user driver's install+relaunch.

**Step 2:** In `AppEnvironment.init`, build `SparkleUpdater()` and pass it to `UpdateController(store:currentVersion:updater:)`.

**Step 3: Build** the app (Debug). Expected `** BUILD SUCCEEDED **`.

**Step 4: Commit.**

---

### Task 7: Persistent "update available" indicator in the shell

**Objective:** A always-visible, dismissible affordance (toolbar badge + a slide-in banner) whenever `installPhase`/`available` indicates a newer version — not buried in Settings.

**Files:**
- Create: `Apps/SupraAI/SupraAI/Updater/UpdateBannerView.swift`
- Modify: `Apps/SupraAI/SupraAI/MainShellView.swift` (host the banner via `.safeAreaInset(edge: .top)` or an overlay; add a toolbar badge button bound to `environment.updateController`).

**Step 1:** `UpdateBannerView` renders by phase:
- `.available(v)` → "Supra AI \(v) is available · [Install in background] · [Release notes] · [Later]"
- `.downloading(f)` → progress bar.
- `.readyToInstall(v)` → "Update ready · [Relaunch to finish] · [Later]".
- `.failed(m)` → inline error + Retry.
A `@AppStorage("updates.bannerDismissedVersion")` suppresses re-nagging for a version the user dismissed (still shown in Settings + toolbar badge).

**Step 2:** Add a toolbar circle-badge button (e.g. `arrow.down.circle.fill`) visible only when an update exists, opening the banner/Settings.

**Step 3: Build.** Expected SUCCEEDED.

**Step 4: Commit.**

---

### Task 8: Replace the Settings "Download (browser)" flow

**Objective:** Swap `NSWorkspace.shared.open(downloadURL)` for the in-app background install actions.

**Files:**
- Modify: `Apps/SupraAI/SupraAI/SettingsView.swift:97-117`.

**Step 1:** Replace the Download button with phase-aware buttons: "Install in background" (`downloadAndInstall()`), progress while `.downloading`, "Relaunch to finish" (`relaunchToInstall()`) when `.readyToInstall`. Keep "Release notes…" and "Check Now".

**Step 2: Build.** Expected SUCCEEDED.

**Step 3: Commit.**

---

### Task 9: Generate + publish the appcast in `release.sh`

**Objective:** Produce a signed `appcast.xml` and publish it to the stable feed URL on every release.

**Files:**
- Modify: `Scripts/release.sh` (after the zip is built/notarized).
- Create: `Scripts/appcast/` working dir (gitignored) or push to `gh-pages`.

**Step 1:** After packaging the zip, run Sparkle's `generate_appcast` over a directory containing the notarized `SupraAI-<v>.zip` (Sparkle signs with the Keychain private key and emits `appcast.xml` with the EdDSA signature + version + URL pointing at the GitHub release asset). Set the enclosure URL base to the release download URL.

**Step 2:** Publish `appcast.xml` to `https://cadespivey.github.io/Supra-AI/appcast.xml` (commit to `gh-pages`), then health-check: `curl -fsSL <feed> | head` must show the new `<sparkle:version>`.

**Step 3:** Smoke-test note: the FIRST Sparkle release can't be auto-verified by an older non-Sparkle build; document that 1.6.0 users must do one manual update to the first Sparkle build, after which auto-update works.

**Step 4: Commit.**

---

### Task 10: End-to-end manual verification

**Objective:** Prove the background update actually installs.

**Steps (manual, documented in the PR):**
1. Build + notarize version `X` (Sparkle-enabled), install to `/Applications`, launch.
2. Build + release version `X+1`; publish appcast.
3. In the running `X`: confirm the persistent banner appears, click "Install in background", watch progress → "Relaunch to finish".
4. Click relaunch; confirm the app reopens as `X+1` (check About / `MARKETING_VERSION`).
5. Confirm Gatekeeper still happy: `spctl -a -vv /Applications/SupraAI.app` → `accepted, source=Notarized Developer ID`.

---

## Files likely to change (summary)

| File | Change |
|---|---|
| `Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj` | Sparkle dep, Info.plist keys |
| `SupraAI.xcworkspace/.../Package.resolved` | pin Sparkle |
| `Apps/SupraAI/SupraAI/SupraAI.entitlements` | Sparkle XPC mach-lookup exceptions |
| `Apps/SupraAI/SupraAI/Info.plist` | `SUFeedURL`, `SUPublicEDKey`, installer-launcher |
| `Packages/SupraSessions/.../UpdateChecker.swift` | `installPhase`, actions, `UpdaterProviding` seam |
| `Packages/SupraSessions/.../Updater/UpdaterProviding.swift` | new protocol + phase enum |
| `Apps/SupraAI/SupraAI/Updater/SparkleUpdater.swift` | new Sparkle bridge |
| `Apps/SupraAI/SupraAI/Updater/UpdateBannerView.swift` | new persistent indicator |
| `Apps/SupraAI/SupraAI/MainShellView.swift` | host banner + toolbar badge |
| `Apps/SupraAI/SupraAI/SettingsView.swift` | replace browser-download button |
| `Apps/SupraAI/SupraAI/AppEnvironment.swift` | inject `SparkleUpdater` |
| `Scripts/release.sh` | generate + publish signed appcast |
| `Scripts/sparkle-public-key.txt` | public key reference |

## Validation

- `swift test` in `Packages/SupraSessions` (phase state machine, version compare) — stays green, Sparkle-free.
- `xcodebuild … build` (Debug) after each app-target task.
- Manual end-to-end (Task 10) on a real notarized install — the only way to prove background install.

## Test / unit coverage notes

- Keep all Sparkle types out of `SupraSessions`; the `UpdaterProviding` stub gives full phase-machine coverage without the framework.
- `ReleaseUpdateChecker.isNewer` already has coverage; reuse for the badge signal.
