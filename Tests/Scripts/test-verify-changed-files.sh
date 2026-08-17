#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
guard="$repo_root/Scripts/verify-changed-files.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q -b main
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.invalid
printf 'safe\n' >"$fixture/file.txt"
git -C "$fixture" add .
git -C "$fixture" commit -qm base
base="$(git -C "$fixture" rev-parse HEAD)"

printf 'still safe\n' >>"$fixture/file.txt"
git -C "$fixture" add .
git -C "$fixture" commit -qm safe
SUPRA_REPO_ROOT="$fixture" bash "$guard" "$base" HEAD >/dev/null

base="$(git -C "$fixture" rev-parse HEAD)"
printf 'github_pat_%s%s\n' 'abcdefghijklmnop' 'qrstuvwxyz123456' >"$fixture/leak.txt"
git -C "$fixture" add .
git -C "$fixture" commit -qm secret
if SUPRA_REPO_ROOT="$fixture" bash "$guard" "$base" HEAD >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: changed secret was accepted' >&2
  exit 1
fi

git -C "$fixture" reset -q --hard "$base"
mkdir -p "$fixture/website/public/fonts"
printf 'font\n' >"$fixture/website/public/fonts/Equity-A.woff2"
git -C "$fixture" add .
git -C "$fixture" commit -qm font
if SUPRA_REPO_ROOT="$fixture" bash "$guard" "$base" HEAD >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: prohibited changed artifact was accepted' >&2
  exit 1
fi

printf '%s\n' 'Changed-file safety tests passed.'
