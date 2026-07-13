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
