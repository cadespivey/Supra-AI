#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
restore_doc="${repo_root}/Docs/Backup-and-Restore.md"
readme="${repo_root}/README.md"
settings_view="${repo_root}/Apps/SupraAI/SupraAI/SettingsView.swift"
app_environment="${repo_root}/Apps/SupraAI/SupraAI/AppEnvironment.swift"
failures=0

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'FAIL: required restore documentation is missing: %s\n' "${path#${repo_root}/}" >&2
    failures=$((failures + 1))
  fi
}

require_literal() {
  local path="$1"
  local literal="$2"
  local description="$3"
  if [[ ! -f "$path" ]] || ! grep -Fq -- "$literal" "$path"; then
    printf 'FAIL: %s\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

require_restore_startup_ordering() {
  local path="$1"
  if ! awk '
    $0 == "    init() {" { in_init = 1; next }
    in_init && /^    private func / { in_init = 0 }
    $0 == "    private static func makeStore(" { in_store = 1; next }
    in_store && /^    private static func / { in_store = 0 }
    $0 == "    private static func prepareColdStartRestore() -> ColdStartRestoreEvidence? {" {
      in_prepare = 1
      next
    }
    in_prepare && /^    private static func / { in_prepare = 0 }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      if (line !~ /^(\/\/|\/\*|\*)/ && index(line, "SupraStore.openAppSupportStore(") != 0) {
        app_support_opens++
      }
    }
    in_init {
      if (line == "let coldStartRestore = AppEnvironment.prepareColdStartRestore()") {
        if (init_step != 0) invalid = 1
        init_step = 1
      } else if (line == "let restoreActivation = coldStartRestore?.activation") {
        if (init_step != 1) invalid = 1
        init_step = 2
      } else if (line == "let storeResult = AppEnvironment.makeStore(") {
        if (init_step != 2) invalid = 1
        init_step = 3
      } else if (line == "after: restoreActivation,") {
        if (init_step != 3) invalid = 1
        init_step = 4
      } else if (line == "replayOutcome: coldStartRestore?.outcome,") {
        if (init_step != 4) invalid = 1
        init_step = 5
      } else if (line == "outcomeReadFailed: coldStartRestore?.outcomeReadFailed == true") {
        if (init_step != 5) invalid = 1
        init_step = 6
      } else if (line == "let store = storeResult.store") {
        if (init_step != 6) invalid = 1
        init_step = 7
      } else if (line == "self.chatController = GlobalChatController(") {
        if (init_step != 7) invalid = 1
        init_step = 8
      }
    }
    in_store {
      if (line == "if restoreActivation?.status == .recoveryRequired") {
        if (store_step != 0) invalid = 1
        store_step = 1
      } else if (line == "|| replayOutcome?.status == .recoveryRequired") {
        if (store_step != 1) invalid = 1
        store_step = 2
      } else if (line == "|| outcomeReadFailed") {
        if (store_step != 2) invalid = 1
        store_step = 3
      } else if (line == "return (" && store_step != 0) {
        if (store_step != 3) invalid = 1
        store_step = 4
      } else if (line == "makeFallbackStore()," && store_step != 0) {
        if (store_step != 4) invalid = 1
        store_step = 5
      } else if (line == "failure: .restore," && store_step != 0) {
        if (store_step != 5) invalid = 1
        store_step = 6
      } else if (line == "return (try SupraStore.openAppSupportStore(), false, nil)") {
        if (store_step != 6) invalid = 1
        store_step = 7
      }
    }
    in_prepare {
      if (line == "guard !isUITestMode, !isDemoMode, !isHeadlessProbeMode,") {
        if (prepare_step != 0) invalid = 1
        prepare_step = 1
      } else if (line == "let activation = RestoreActivationService.activatePendingRestore(liveLayout: layout)") {
        if (prepare_step != 1) invalid = 1
        prepare_step = 2
      } else if (line == "do {") {
        if (prepare_step != 2) invalid = 1
        prepare_step = 3
      } else if (line == "outcome = try RestoreSidecarStore.readActivationOutcome(") {
        if (prepare_step != 3) invalid = 1
        prepare_step = 4
      } else if (line == "outcomeReadFailed = false") {
        if (prepare_step != 4) invalid = 1
        prepare_step = 5
      } else if (line == "} catch {") {
        if (prepare_step != 5) invalid = 1
        prepare_step = 6
      } else if (line == "outcome = nil") {
        if (prepare_step != 6) invalid = 1
        prepare_step = 7
      } else if (line == "outcomeReadFailed = true") {
        if (prepare_step != 7) invalid = 1
        prepare_step = 8
      } else if (line == "return ColdStartRestoreEvidence(") {
        if (prepare_step != 8) invalid = 1
        prepare_step = 9
      } else if (line == "activation: activation,") {
        if (prepare_step != 9) invalid = 1
        prepare_step = 10
      } else if (line == "outcome: outcome,") {
        if (prepare_step != 10) invalid = 1
        prepare_step = 11
      } else if (line == "outcomeReadFailed: outcomeReadFailed,") {
        if (prepare_step != 11) invalid = 1
        prepare_step = 12
      }
    }
    END {
      exit (init_step == 8 && store_step == 7 && prepare_step == 12 && app_support_opens == 1 && !invalid ? 0 : 1)
    }
  ' "$path"; then
    printf '%s\n' \
      'FAIL: AppEnvironment must activate restore before store/controller construction and route every recovery predicate to the restore fallback before opening the user store' >&2
    failures=$((failures + 1))
  fi
}

require_file "$restore_doc"
require_literal "$restore_doc" '## Restore from Backup' \
  'restore documentation must describe the user restore workflow'
# Standing guard: terminal restore documentation landed in 10bc839 before the
# expanded literal checks; these already-green assertions lock future copy drift.
require_literal "$restore_doc" 'Schedule Restore and Quit' \
  'restore documentation must name the terminal restore action'
require_literal "$restore_doc" 'blocks the entire workspace' \
  'restore documentation must state that staging blocks all further work'
require_literal "$restore_doc" 'closes the exact live database writer' \
  'restore documentation must state that staging quiesces the exact live writer'
require_literal "$restore_doc" 'quits automatically' \
  'restore documentation must state that the staging process exits automatically'
require_literal "$restore_doc" 'safety copy' \
  'restore documentation must explain the rollback safety copy'
require_literal "$restore_doc" 'cold start' \
  'restore documentation must explain the cold-start activation boundary'
require_literal "$restore_doc" 'Recovery Required' \
  'restore documentation must explain the recovery-required path'
# T-RST-H08 expected RED: the guide tells the user to preserve only the database
# instead of the complete safety folder containing its managed-document blobs.
require_literal "$restore_doc" 'preserve the entire safety folder' \
  'restore documentation must preserve the complete safety directory and blob tree'
require_literal "$restore_doc" 'managed-document blobs' \
  'restore documentation must name the managed-document blobs preserved with the database'
require_literal "$restore_doc" 'Recovery-required operation trees are deliberately' \
  'restore documentation must preserve recovery-required operation trees'
require_literal "$restore_doc" "removes only that authenticated operation's private staging tree" \
  'restore documentation must clean only terminal authenticated operation trees'
# T-RST-H09 expected RED: the guide does not disclose that successful database
# replacement reconstructs the authenticated scheduling audit in the restored ledger.
require_literal "$restore_doc" 'replays the authenticated scheduling audit into the restored database with its original timestamp' \
  'restore documentation must explain scheduling-audit continuity across activation'
require_literal "$restore_doc" 'does not modify the backup source' \
  'restore documentation must promise source immutability narrowly'
require_literal "$readme" '[Backup and restore](Docs/Backup-and-Restore.md)' \
  'README must link the backup and restore guide'
require_literal "$settings_view" 'Schedule Restore and Quit' \
  'Settings must expose the terminal staged-restore action'
require_literal "$settings_view" 'blocks further work' \
  'Settings must disclose that restore staging blocks further work'
require_literal "$settings_view" 'closes the live database' \
  'Settings must disclose that restore staging closes the live database'
require_literal "$settings_view" 'quits automatically' \
  'Settings must disclose the automatic process exit'
require_literal "$settings_view" 'How restore works' \
  'Settings must expose concise restore help'
# T-RST-H08 expected RED: Settings still offers only the recovery database.
require_literal "$settings_view" 'entire verified safety folder' \
  'Settings restore help must preserve the database and managed-document blobs together'
require_literal "$settings_view" 'managed-document blobs' \
  'Settings restore help must name the managed-document blobs in the safety folder'
require_restore_startup_ordering "$app_environment"

if (( failures != 0 )); then
  printf 'Backup and restore documentation checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'Backup and restore documentation checks passed.'
