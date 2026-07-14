#!/usr/bin/env bash
# Archive release evidence and clear the release runner workspace, restoring the
# ephemeral-equivalent baseline required by Docs/Release-Protection.md. Run AS the
# release user after every rehearsal or release run, BEFORE stopping for the day.
#
# Archives every build/release directory found in the runner workspace — including
# release-result-v<version>.json, whose recorded appcast merge commit is a required
# input to the emergency rollback workflow — then deletes the workspace.
set -euo pipefail

runner_home="${HOME}/actions-runner"
work_dir="${runner_home}/_work"
archive_root="${HOME}/ReleaseEvidence"

[[ -d "$runner_home" ]] || { printf 'no runner at %s\n' "$runner_home" >&2; exit 2; }

if pgrep -U "$(id -u)" -f 'Runner.Listener' >/dev/null 2>&1; then
  printf 'stop the runner (Ctrl-C on run.sh) before resetting the workspace\n' >&2
  exit 2
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive_dir="${archive_root}/${timestamp}"

if [[ -d "$work_dir" ]]; then
  evidence_found=0
  while IFS= read -r -d '' release_dir; do
    evidence_found=1
    mkdir -p "$archive_dir"
    destination="${archive_dir}/$(printf '%s' "${release_dir#"${work_dir}/"}" | tr '/' '_')"
    cp -R "$release_dir" "$destination"
    printf 'archived %s -> %s\n' "$release_dir" "$destination"
  done < <(find "$work_dir" -type d -path '*/build/release' -print0 2>/dev/null)
  if (( evidence_found == 0 )); then
    printf 'no build/release evidence found under %s\n' "$work_dir"
  fi
  rm -rf "$work_dir"
  printf 'cleared runner workspace %s\n' "$work_dir"
else
  printf 'no workspace to clear at %s\n' "$work_dir"
fi

if [[ -d "$archive_dir" ]]; then
  printf 'evidence archived under %s — retain per Docs/Release-Protection.md\n' "$archive_dir"
fi
