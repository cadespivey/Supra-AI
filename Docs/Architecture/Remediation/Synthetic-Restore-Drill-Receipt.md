# Synthetic Restore Drill Receipt

**Execution date:** 2026-08-15  
**Execution candidate:** `f09216f3b7341091d61e6a38483b59629e9f17c2`  
**Owner decision:** Pending signature  
**Data classification:** Deterministic synthetic fixtures only; no user, client, or privileged data

## Environment

| Item | Observed value |
|---|---|
| Hardware architecture | Apple silicon (`arm64`) |
| macOS | 27.0 (`26A5406e`) |
| Xcode | 27.0 (`27A5194q`) |
| Swift toolchain selection | `/Applications/Xcode-beta.app/Contents/Developer` |
| Native app | Debug `SupraAI.app` built from the execution candidate |
| Shipping-fixture manifest | 8 supported versions; SHA-256 `656df61cd21b9a43d3d90fb453bf010baab98775deada056eed18b8a246b0276` |

## Required drill outcomes

### Successful restore and reopen — PASS

The native Settings flow was launched with the dedicated hermetic restore fixture. The operator
opened **Settings → Data & Backup**, inspected backups, selected exact snapshot
`SupraAI-20260731-090000-000`, reviewed the replacement confirmation, chose **Schedule Restore and
Quit**, and observed the process exit automatically. The fixture reported Supra AI 2.3.2 build 391,
8.4 MB, and three managed documents. No production store or backup directory participated.

The actual Store process boundary was exercised separately by
`ShippingMigrationFixtureTests.testTRST37EverySupportedShippingFixtureRestoresAndMigratesThroughColdStart`.
For all eight authenticated synthetic shipping fixtures, the test discovered the candidate, staged
it beside a synthetic live store, activated it at cold start, migrated it through the shipping
`SupraDatabase` boundary, reopened it as a healthy current `SupraStore`, and proved the source
database and manifest fingerprints were unchanged. Result: 1 selected test passed, 0 failures.

### Forced activation failure with verified safety rollback — PASS

Two independent fault paths passed:

- `RestoreActivationServiceTests.testSelectedReplacementFailureRollsBackExactPriorCanary` forced
  selected-database replacement failure and verified the exact prior canary after automatic safety
  replacement. Result: 1 selected test passed, 0 failures.
- `RestoreActivationServiceTests.testSelectedStateValidationAfterOpenTriggersVerifiedRollback`
  corrupted selected managed-blob state after open, forced post-open validation failure, reopened
  the safety database, and verified the prior database canary and managed blob. Result: 1 selected
  test passed, 0 failures.

Neither path reported rollback success from file copying alone; both crossed the open-and-validation
boundary required by the restore contract.

### Unsupported future schema rejection — PASS

`RestoreSnapshotInspectorTests.testMigrationMismatchAndFutureSchemaHaveDistinctBlockingReasons`
presented both a manifest/database mismatch and a database containing `v999_future`. The future
candidate was classified `unsupportedFutureSchema` and remained ineligible for staging. Result:
1 selected test passed, 0 failures.

The native mixed-candidate inspection also showed its incompatible synthetic snapshot as disabled
and kept **Review Restore…** disabled until the compatible snapshot was deliberately selected.

### Source immutability and documentation contract — PASS

`RestoreServiceTests.testStageCopiesSelectedStateWithoutMutatingLiveOrBackupSource` proved staging
copied the selected database and managed blob without changing either the live canary or source
backup fingerprint. Result: 1 selected test passed, 0 failures.

`Tests/Scripts/test-backup-restore-documentation.sh` passed. It verified the shipped user guidance,
terminal-process language, complete safety-folder preservation instructions, and the cold-start
activation-before-store-construction ordering.

## Scope and non-guarantees

This receipt qualifies restore behavior only. It does not authorize use of a real client store,
release publication, migration of production data, deletion of a safety folder, or cleanup of a
recovery-required operation. The native `-uiTestMode` surface proves the real Settings interaction
and terminal presentation; the Store tests prove the real file-backed staging, activation,
migration, validation, rollback, reopen, and source-immutability boundaries.

## Owner sign-off

To approve this drill, the owner should confirm the following statement without modification:

> I reviewed the 2026-08-15 synthetic restore drill receipt and approve its successful restore,
> verified safety rollback, and unsupported-future-schema rejection evidence for this release
> candidate.

**Owner:** Pending  
**Decision date:** Pending  
**Decision:** Pending
