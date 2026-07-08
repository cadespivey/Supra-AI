# Test-First Development Methodology

How substantial features are planned, verified, and implemented in this repo. This is the
feature-agnostic method; it pairs with the milestone pattern in
[CONTRIBUTING.md](../CONTRIBUTING.md) ("How work is organized"). It exists because the most
expensive test failures are the ones that never happen: tests that pass whether or not the
code under test works. Every rule below closes a specific silent-pass hole.

The Firm Style Profile feature (PR #50) was built end-to-end with this method; its commit
history is the worked example — each test commit precedes its implementation commit, so the
red state of every test is directly observable by checkout.

---

## 1. The three-document pattern

Plan a substantial feature as three working documents **before writing production code**:

| Document | Contents | Fate |
|---|---|---|
| **SPEC** | What & why: data model, invariants, non-goals, deferred items, open questions | Working artifact |
| **PLAN** | Ordered tasks; each names the Test IDs that gate it; a progress ledger with human sign-off cells | Working artifact |
| **TESTPLAN** | The verification contract, authored **first**: test catalog (one row per test: target, fixture, exact assertions, expected RED reason), coverage matrix mapping every SPEC invariant to test IDs | Working artifact |

Cross-reference by ID in both directions (Task `M1-T5` ⇄ Test `T-CAP-03`) so nothing gates on
a test that doesn't exist and no test is orphaned. A coverage matrix row with only a parity
test and no wire-proof (see §3.1) is a **gap** and blocks the task's definition of done.

**The documents are scaffolding, not deliverables.** They stay out of the repo (keep them
locally or in a private space); what lands here is the code, the tests, and this method. The
tests themselves are the durable form of the TESTPLAN's catalog.

## 2. RED first, and make RED observable

No task's production code is written until its gating tests exist and have been **observed
failing for the recorded reason** — either a compile error naming the missing symbol, or an
assertion failure stating the concrete wrong value that will be seen.

- **Commit the tests before the implementation**, as a separate commit. The red state then
  lives in history: anyone can `git checkout <tests-commit> && swift test` and watch it fail,
  then check out the next commit and watch it pass. This matters most when the author's
  environment cannot compile (see §5) — the red proof survives for whoever runs the gate.
- A test whose expected RED reason is "already green" is suspect. The only accepted form is a
  **standing guard**: a test green from day one whose job is to fail on a *future* regression
  (e.g. reflecting a type's stored properties to pin that it never grows a field). Document
  the justification on the test itself.

## 3. The anti-silent-failure doctrine

### 3.1 Wire-proof rule

When new behavior is configurable and its **default equals the old hardcoded behavior** (the
usual way to keep byte-for-byte output parity), a test that exercises only the default passes
whether or not the code actually reads the new configuration. The proof that a knob is wired
**must**:

1. set a **non-default** value,
2. assert the customized output **is present**, and
3. assert the default output **is absent** (`XCTAssertFalse`),

with both assertions **scoped to the exact output element** (e.g. the full
`<w:t xml:space="preserve">…</w:t>` run) or to the specific target fragment (e.g. the one
`<w:p>…</w:p>` paragraph containing a known anchor string) — never a whole-document search for
a short or shared token. A whole-output absence assert on a token that other elements also
emit (`<w:b/>`, a bare `/`) can never go green even when the code is correct, and such a test
will inevitably be "fixed" by loosening it into a silent pass.

### 3.2 Parity rule

Default-behavior parity is checked against **frozen** goldens/baselines committed *before* the
change, or authored from an independent source of truth (e.g. a Word round-trip). A test must
never regenerate the golden it compares against from the code under test. Note the limit:
parity catches accidental drift, but it cannot catch an unwired knob (both sides emit the
default) — that is exactly why every knob also carries a wire-proof. The two are complementary
and both are required.

### 3.3 No silent skips

- No `guard … else { return }` in a test body — use `XCTUnwrap` so a missing precondition
  fails loudly instead of passing vacuously.
- `await` the call under test; an unawaited async path tests nothing.
- No `try` whose result is never asserted.
- An assertion inside a closure/completion handler that may never run proves nothing on its
  own: pair it with an outer assertion that fails if the closure never fired (e.g. the
  operation's overall success, or a recorded call count).

### 3.4 Tautology ban

No assertion that is true regardless of the code under test: comparing a value to itself,
asserting a constant the test defined, `contains("")`, or asserting a fixture property the
code never touches.

### 3.5 Fix review findings red-first too

A review finding (human or automated) about a behavioral flaw gets the same treatment as a
feature: first a test that reproduces the flaw (RED — the wrong behavior observed), then the
fix (GREEN), as separate commits. If the finding reveals that an *existing test encoded the
wrong expectation*, revise the test in the RED commit and say so — the reviewer caught the
test, not just the code.

## 4. Static safeguards (run before any test run)

Grep-level checks that catch the silent-pass shapes without compiling. Run over the test files
you touched:

```sh
# Whole-output absence assert on a short/shared token (≤ 6 chars) — rewrite to an exact
# element or a scoped fragment:
rg -n 'XCTAssertFalse\(.*contains\("[^"]{1,6}"\)' <test paths>

# Silent guard-return in a test body — use XCTUnwrap:
rg -n 'guard .* else \{ return \}' <test paths>

# try without a surrounding assertion (inspect hits manually):
rg -n '^\s*_ = try |^\s*try [a-z]' <test paths>

# Empty-string containment (always true):
rg -n 'contains\(""\)' <test paths>
```

Add project-specific patterns as new failure shapes are discovered; this list is a floor, not
a ceiling.

## 5. The observation gate

Red→green must be **observed**, not assumed. When work is authored in an environment that
cannot compile it (no macOS/Xcode, etc.), the run becomes an explicit human gate:

- The PLAN's progress ledger carries "RED observed" and "GREEN observed" cells that only a
  person who ran the suite may check.
- Until the gate runs, verification-by-inspection (symbol cross-checks, assertion-vs-emitter
  comparison, the §4 greps, simulating pure functions) reduces risk but **does not discharge
  the gate** — say so plainly in PRs and commit messages.
- The suite-level bar is unchanged from CONTRIBUTING.md: zero failures across all packages
  before merge.

## 6. Goldens and fixtures

- Fixtures are synthetic and clearly fictional; never real client data (see `TestData/`).
- Goldens live in the repo, are captured from a known-good state, and change only in a commit
  whose message says why the *expected* output changed.
- Pin determinism at the level you control: assert on generated content (e.g. normalized
  document XML), not on container bytes that embed timestamps you don't own.
- When output must vary (dates, UUIDs), fix them in the fixture — a deterministic sample
  beats a normalizer.
