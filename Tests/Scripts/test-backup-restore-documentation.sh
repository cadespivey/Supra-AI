#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
restore_doc="${repo_root}/Docs/Backup-and-Restore.md"
readme="${repo_root}/README.md"
settings_view="${repo_root}/Apps/SupraAI/SupraAI/SettingsView.swift"
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

if (( failures != 0 )); then
  printf 'Backup and restore documentation checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'Backup and restore documentation checks passed.'
