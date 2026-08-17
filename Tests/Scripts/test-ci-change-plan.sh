#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
planner="$repo_root/Scripts/ci-change-plan.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/Packages/SupraCore" "$fixture/Packages/SupraSessions" "$fixture/Docs" "$fixture/website"
printf '// swift-tools-version: 6.0\n' >"$fixture/Packages/SupraCore/Package.swift"
printf '// swift-tools-version: 6.0\n.package(path: "../SupraCore")\n' >"$fixture/Packages/SupraSessions/Package.swift"
git -C "$fixture" init -q -b main
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.invalid
git -C "$fixture" add .
git -C "$fixture" commit -qm base
base="$(git -C "$fixture" rev-parse HEAD)"

printf 'copy\n' >"$fixture/Docs/guide.md"
git -C "$fixture" add .
git -C "$fixture" commit -qm docs
docs_plan="$(SUPRA_REPO_ROOT="$fixture" bash "$planner" "$base" HEAD)"
jq -e '.packages == [] and .app == false and .ui == false and .website == false' <<<"$docs_plan" >/dev/null

base="$(git -C "$fixture" rev-parse HEAD)"
printf 'logic\n' >"$fixture/Packages/SupraCore/Core.swift"
git -C "$fixture" add .
git -C "$fixture" commit -qm package
package_plan="$(SUPRA_REPO_ROOT="$fixture" bash "$planner" "$base" HEAD)"
jq -e '.packages == ["SupraCore", "SupraSessions"] and .app == false' <<<"$package_plan" >/dev/null

base="$(git -C "$fixture" rev-parse HEAD)"
printf 'site\n' >"$fixture/website/page.tsx"
git -C "$fixture" add .
git -C "$fixture" commit -qm website
website_plan="$(SUPRA_REPO_ROOT="$fixture" bash "$planner" "$base" HEAD)"
jq -e '.packages == [] and .website == true and .app == false' <<<"$website_plan" >/dev/null

base="$(git -C "$fixture" rev-parse HEAD)"
mkdir -p "$fixture/website/public" "$fixture/website/lib"
printf '<rss/>\n' >"$fixture/website/public/appcast.xml"
printf 'export const version = "1.2.3";\n' >"$fixture/website/lib/constants.ts"
git -C "$fixture" add .
git -C "$fixture" commit -qm publication
publication_plan="$(SUPRA_REPO_ROOT="$fixture" bash "$planner" "$base" HEAD)"
jq -e '.website == true and .publicationMetadata == true' <<<"$publication_plan" >/dev/null

printf '%s\n' 'CI change-plan tests passed.'
