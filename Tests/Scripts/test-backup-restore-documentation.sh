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
require_literal "$restore_doc" 'does not replace the open database' \
  'restore documentation must state that staging never swaps the open database'
require_literal "$restore_doc" 'safety copy' \
  'restore documentation must explain the rollback safety copy'
require_literal "$restore_doc" 'cold start' \
  'restore documentation must explain the cold-start activation boundary'
require_literal "$restore_doc" 'Recovery Required' \
  'restore documentation must explain the recovery-required path'
require_literal "$restore_doc" 'does not modify the backup source' \
  'restore documentation must promise source immutability narrowly'
require_literal "$readme" '[Backup and restore](Docs/Backup-and-Restore.md)' \
  'README must link the backup and restore guide'
require_literal "$settings_view" 'Quit and Restore on Next Launch' \
  'Settings must expose the staged-restart restore action'
require_literal "$settings_view" 'How restore works' \
  'Settings must expose concise restore help'

if (( failures != 0 )); then
  printf 'Backup and restore documentation checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'Backup and restore documentation checks passed.'
