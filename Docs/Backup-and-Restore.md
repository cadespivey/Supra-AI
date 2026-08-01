# Backup and Restore

Supra AI can keep completed database snapshots and the managed documents they reference in a
folder you choose. Configure that folder in **Settings → Backup**, then use **Back Up Now** whenever
you want a fresh recovery point. A snapshot appears as complete only after its database, referenced
documents, and completion record have been written and verified.

## Restore from Backup

1. Open **Settings → Backup** and choose **Inspect Backups**.
2. Review the date, app version and build, database size, and managed-document count. Supra AI
   disables any snapshot that is incomplete, damaged, missing a referenced document, or uses an
   unsupported schema.
3. Select a compatible snapshot and review the confirmation naming that exact snapshot.
4. Choose **Schedule Restore and Quit**. Supra AI records the content-free schedule and audit event,
   blocks the entire workspace, closes the exact live database writer, creates and verifies a safety
   copy, and stages the selected snapshot. It publishes the restart marker only after every staged
   component passes verification, then quits automatically. Once staging begins, the process quits
   whether staging succeeds or fails; the closed controller graph is never reused.
5. Reopen Supra AI. On that cold start, Supra AI installs the staged database and managed documents
   before opening a database writer, migrates the database if necessary, and validates the result.

Restore does not modify the backup source. It reads the selected snapshot and shared document pool,
then works from private staged copies. A completed restore consumes its restart marker, so later
launches do not repeat the operation. After a verified activation or verified rollback, Supra AI
durably records the outcome and removes only that authenticated operation's private staging tree.
Cleanup is retried from the durable outcome if interruption occurs.

## If activation fails

If staging fails after the live writer closes, Supra AI writes a coarse, content-free failure sidecar
and quits. The next launch replays that failure into the restore status and audit ledger, then
acknowledges the sidecar. If the sidecar itself could not be written, the pre-close scheduled status
is reported as an interrupted staging attempt. Neither path replaces the live data.

If the staged database cannot be installed, opened, migrated, or validated, Supra AI restores and
validates the safety copy before normal work resumes. A verified rollback is terminal and its private
operation tree is cleaned after the durable outcome is recorded.

If both activation and automatic rollback fail, Supra AI opens a **Recovery Required** screen instead
of the normal workspace. Use **Show Recovery Snapshot** to reveal the verified recovery database in
Finder, preserve that file, and quit without creating new work. Do not move or edit restore-staging
files while Supra AI is attempting recovery. Recovery-required operation trees are deliberately
preserved; terminal cleanup never removes them.

Restore status records contain only the operation identifier, snapshot identifier, outcome category,
failure category, and completion time. They do not contain database content or absolute filesystem
paths.

## Release qualification drill

Before shipping restore changes, the owner must sign off on a synthetic-data drill that exercises the
complete process boundary: inspect and select the snapshot, choose **Schedule Restore and Quit**,
observe the blocking surface and automatic exit, relaunch, confirm the restored synthetic record,
and verify that the source backup is unchanged. The drill must also force activation failure, verify
the safety rollback, and confirm that a deliberately unsupported future-schema snapshot remains
disabled. Never use client or privileged data for this drill.
