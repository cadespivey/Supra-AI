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
4. Confirm staging. This copies and verifies the selected snapshot and creates a verified safety
   copy of the current data. Staging does not replace the open database.
5. Choose **Quit and Restore on Next Launch**. On the next cold start, Supra AI installs the staged
   database and managed documents before opening a database writer, migrates the database if
   necessary, and validates the result.

Restore does not modify the backup source. It reads the selected snapshot and shared document pool,
then works from private staged copies. A completed restore consumes its restart marker, so later
launches do not repeat the operation.

## If activation fails

If the staged database cannot be installed, opened, migrated, or validated, Supra AI restores and
validates the safety copy before normal work resumes. The original staged material remains available
for diagnosis.

If both activation and automatic rollback fail, Supra AI opens a **Recovery Required** screen instead
of the normal workspace. Use **Show Recovery Snapshot** to reveal the verified recovery database in
Finder, preserve that file, and quit without creating new work. Do not move or edit restore-staging
files while Supra AI is attempting recovery.

Restore status records contain only the operation identifier, snapshot identifier, outcome category,
failure category, and completion time. They do not contain database content or absolute filesystem
paths.

## Release qualification drill

Before shipping restore changes, use a synthetic-data backup to exercise the complete flow: inspect
and select the snapshot, stage it, quit, relaunch, confirm the restored synthetic record, and verify
that the source backup is unchanged. Also verify that a deliberately unsupported future-schema
snapshot remains disabled. Never use client or privileged data for this drill.
