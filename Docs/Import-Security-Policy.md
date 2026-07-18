# Document import security policy

`ImportPolicy.default` is the shipping ceiling for document imports. Every
value is finite; code must not substitute an unbounded fallback.

| Resource | Shipping ceiling |
| --- | ---: |
| Directory depth | 32 levels |
| Files, including extracted attachments | 10,000 |
| Source file | 512 MiB |
| Aggregate source bytes | 2 GiB |
| Parser elapsed time | 30 seconds |
| Decoded text per item | 64 MiB |
| PDF pages / extracted parts | 10,000 |
| Rendered image or PDF pixels | 250,000,000 |
| ZIP entries | 50,000 |
| ZIP or decoded aggregate expansion | 1 GiB |
| ZIP compression ratio | 100:1 |
| MIME / nested-attachment depth | 20 levels |
| Attachments | 5,000 |
| XML markup nodes | 1,000,000 |

The selected filesystem root is pinned by device and inode before traversal.
Symlinks, Finder aliases, hard links, duplicate filesystem identities, root or
candidate replacement, and candidates outside the canonical root are rejected. ZIP paths
receive the same canonical-path checks, including slash normalization and
Unicode normalization.

Known extensions are compared with byte signatures, UTType evidence, and OOXML
content types/package structure before dispatch. A contradiction is rejected;
an unknown signature is not treated as contradictory evidence. This preserves
support for text-like formats that have no mandatory magic bytes.

Policy failures are recorded per item with a stable `rejectionCode`; unrelated
items continue until an aggregate budget is exhausted. Rejected hostile items
must not leave a document row or managed blob. Cancellation propagates and
removes import staging files.

When a completed import contains failures, the Documents warning reconstructs
the persisted report after relaunch and lists each failed item's display name,
stable rejection code when present, and exact recovery guidance. Aggregate Audit
events remain supplementary rather than the only explanation visible to the user.

## Encrypted and legacy-format disposition

Password-protected PDFs, OLE-wrapped encrypted OOXML packages exposing
`EncryptionInfo`/`EncryptedPackage`, and ZIP containers whose entry flags mark
encryption are rejected before managed storage. Their stable code is
`encrypted_source`, and the user is directed to remove encryption from a copy.
Supra AI does not prompt for, store, or attempt passwords.

Legacy `.xls` and Outlook `.msg` inputs remain selectable so the import report
can account for them, but they terminate as `unsupported_by_policy` before any
blob or document row is created. Guidance directs the user to export `.xls` as
`.xlsx` and `.msg` as `.eml`. A supported format that is admitted and then fails
its parser remains the distinct `failed` state.

Legacy `.doc` is the deliberate exception: it remains admitted through the
bounded AppKit text converter, is stamped `converted_lossy`, and enters
`needs_review`. Its warning explains that tables, numbering, and layout can be
lost. Retrieved text may support preliminary review with disclosure, but the
document keeps the scope from claiming completeness or a clean negative until
the user converts it to `.docx`/PDF and reviews the result.

## Durable source accounting and file authority

Migration v059 adds `document_import_sources`, an incremental ledger for every
top-level selection and discovered child. Files, directories, attachments, hidden
members, rejections, unsupported sources, failures, interruptions, cancellations,
and user exclusions all receive explicit states. Directories finish as
`container_completed` and never masquerade as content documents. Hidden members
are enumerated into `excluded_hidden` rows but are not parsed and remain absent
from the compatibility import report.

Only a top-level user selection may carry a security-scoped bookmark. Child and
attachment rows never store one, and every terminal transition clears the
top-level bookmark in the same database transaction. The batch also preserves
whether a target folder was requested and its exact identifier; repository writes
reject a target belonging to another matter. The final `report_json` remains the
completed-run compatibility artifact, while the ledger is authoritative for
incremental and interrupted source accounting.

Historical batches receive no fabricated source rows during v059 migration and
retain their existing `report_json`. The pre-migration snapshot is the recovery
path; a schema downgrade drops `document_import_sources` and the two additive
batch target columns. On bootstrap, post-v059 batches left in `discovering` or
`processing` are finalized as `interrupted` with a deterministic report
synthesized from the ledger. Active source rows become re-entrant `interrupted`
rows and retain only their top-level bookmark because copy resumption still
needs that authorization; already-terminal rows and their exact reasons are
preserved. The Documents tab offers Resume and Discard. Resume reopens only
persisted top-level bookmarks, skips completed rows, and preserves the exact
requested target folder; an unresolvable bookmark or missing target becomes an
explicit terminal failure. Discard cancels only unfinished rows. Every terminal
path clears its bookmark.
