# Public Website Asset Licensing

## Non-negotiable rule

Equity font files must never be publicly accessible through Supra AI. They must not appear in
this public repository, any Git commit or ref, Git LFS, the marketing website, GitHub Pages,
Actions artifacts or caches, releases, downloadable packages, fixtures, or other public
storage.

This prohibition still applies when a font is renamed, converted to another format,
subsetted, obfuscated, embedded in CSS or JavaScript, base64-encoded, or copied into a build
artifact. A deletion commit is not an adequate remedy after exposure because the binary
remains in Git history.

## Website implementation requirements

- Use system fonts or font assets whose licenses expressly permit repository distribution,
  web serving, artifact distribution, and the project's intended use.
- Do not assume possession of a font file grants redistribution rights. Record and review the
  license before adding any new font binary.
- Any future local/private Equity integration must be opt-in, absent by default, stored
  outside this repository, and structurally incapable of entering public builds or artifacts.
- Every website SPEC, PLAN, and TESTPLAN must repeat this rule and include
  `bash Scripts/verify-public-font-license.sh` as an acceptance/release gate.
- Run the guard before every website commit and both before and after generating a deployment
  artifact.

## Automated guard

`Scripts/verify-public-font-license.sh` rejects:

- any file placed in the reserved public font path;
- Equity-named font files; and
- the six known prohibited binaries by Git blob hash, even if renamed or relocated.

The guard is defense in depth, not permission to add modified copies. Do not bypass, weaken,
or remove it to make a build pass.

## If an exposure is suspected

1. Stop deployments and pushes that could propagate the affected history.
2. Remove the asset from the current tree and rewrite every affected branch and tag.
3. Verify a fresh mirror clone contains no prohibited blob in public heads or tags.
4. Ask GitHub Support to delete affected pull-request refs and cached views and to run
   server-side garbage collection.
5. Coordinate with fork and clone owners so old history cannot be pushed back.
