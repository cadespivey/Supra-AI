# Backup and Restore

> **Status:** Implemented on `main` for the next release after v2.3.4. The synthetic success,
> rollback, and unsupported-schema release qualification drill below remains required and is not
> recorded as complete.

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
   before constructing the normal app store, then opens, migrates, and validates the database through
   the normal database boundary.

Successful restore staging replaces the hosted workspace with a terminal restore shell before the process exits; a recovery-required launch replaces normal work with a recovery shell that identifies the entire safety folder for preservation.
Quiesced restore staging rejects a mismatched live database, closes the supplied live database writer before capturing a verified safety database and managed blobs, verifies the selected snapshot on the live volume, and publishes the cold-start marker only after every staged component passes.
Restore activation installs the selected database, opens and migrates it with SupraDatabase, and then validates it with RestoreValidation; after activation failure, it reports rollback success only if the safety database is reinstalled and passes the same open-and-validation boundary, otherwise it returns recovery required.
On a normal production launch, AppEnvironment completes pending-restore activation before constructing the normal SupraStore; a recovery-required activation, recovery-required durable outcome, or unreadable outcome prevents the user's Application Support store from opening.

Restore does not modify the backup source. It reads the selected snapshot and shared document pool,
then works from private staged copies. A completed restore consumes its restart marker, so later
launches do not repeat the operation. Supra AI durably records a verified activation or rollback
outcome before it consumes the restart marker. A launch interrupted between those writes reconciles
the authenticated marker without repeating database or blob mutation. The same content-free intent
is retained inside the private operation tree so a recovery launch can revalidate its safety copy
even when marker removal became visible before its directory sync completed. After successful activation,
Supra AI replays the authenticated scheduling audit into the restored database with its original timestamp
before recording the terminal activation audit and acknowledging the durable activation outcome. Supra AI
removes only that authenticated operation's private staging tree after marker consumption. Cleanup is retried
from the durable outcome if interruption occurs. Newly created staging and managed-document roots
are published through their parent directories before success is recorded.

## If activation fails

If staging fails after the live writer closes, Supra AI writes a coarse, content-free failure sidecar
and quits. The next launch replays that failure into the restore status and audit ledger, then
acknowledges the sidecar. If the sidecar itself could not be written, the pre-close scheduled status
is reported as an interrupted staging attempt. Any exact operation tree left by interrupted staging
is removed only when no marker or activation outcome claims it. If that bounded cleanup or evidence
acknowledgement cannot finish, its durable retry key is retained and new backup or restore work stays
blocked until a later launch succeeds. Evidence acknowledgement uses a content-free rename tombstone;
a later cold read completes and synchronizes either interrupted phase before work can reopen. Neither
path replaces the live data.

If the staged database cannot be installed, opened, migrated, or validated, Supra AI restores and
validates the safety copy before normal work resumes. A verified rollback is terminal and its private
operation tree is cleaned after the durable outcome is recorded.

If both activation and automatic rollback fail, Supra AI opens a **Recovery Required** screen instead
of the normal workspace. Use **Show Recovery Safety Copy** to reveal the verified safety directory in
Finder, preserve the entire safety folder—including `restore-safety.sqlite` and its sibling
managed-document blobs directory—and quit without creating new work. Do not separate, move, or edit
those contents while Supra AI is attempting recovery. Recovery-required operation trees are deliberately
preserved; terminal cleanup never removes them. A durable recovery-required outcome freezes later
activation attempts. Each later launch revalidates the retained safety database for the preservation
action without repeating live database or blob mutation, and recovery evidence is never acknowledged
away by the normal terminal-outcome API.

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
