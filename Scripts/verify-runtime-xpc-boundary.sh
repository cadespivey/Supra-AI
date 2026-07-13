#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
listener="${repo_root}/Apps/SupraAI/SupraRuntimeService/main.swift"
delegate="${repo_root}/Apps/SupraAI/SupraRuntimeService/RuntimeServiceDelegate.swift"
client="${repo_root}/Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClient.swift"
requirements="${repo_root}/Packages/SupraRuntimeInterface/Sources/SupraRuntimeInterface/XPC/RuntimeXPCInterfaces.swift"
service_entitlements="${repo_root}/Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.entitlements"
app_path="${1:-}"
if [[ "$app_path" == "--check" ]]; then
  app_path=""
fi

grep -Fq 'setCodeSigningRequirement(RuntimeXPCSigningRequirements.appClient)' "$delegate" || {
  printf '%s\n' 'ERROR: accepted XPC connection does not authenticate the app client.' >&2
  exit 1
}
grep -Fq 'setCodeSigningRequirement(RuntimeXPCSigningRequirements.runtimeService)' "$client" || {
  printf '%s\n' 'ERROR: app client does not authenticate the runtime service.' >&2
  exit 1
}
grep -Fq 'certificate leaf[subject.OU] = \"2DP657YB3K\"' "$requirements" || {
  printf '%s\n' 'ERROR: Release XPC requirement is not bound to the Supra Team ID.' >&2
  exit 1
}

if rg -n '_Sec|dlsym|dlopen|performSelector|valueForKey.*audit|class_getInstance' \
  "$listener" "$delegate" "$client" "$requirements"; then
  printf '%s\n' 'ERROR: private/dynamic API appeared in the XPC trust boundary.' >&2
  exit 1
fi

[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$service_entitlements")" == 'true' ]] || {
  printf '%s\n' 'ERROR: runtime service sandbox entitlement is missing.' >&2
  exit 1
}
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$service_entitlements" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$service_entitlements" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: runtime service acquired file-picker or network entitlement.' >&2
  exit 1
fi
source_entitlement_keys="$(plutil -p "$service_entitlements" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p')"
[[ "$source_entitlement_keys" == 'com.apple.security.app-sandbox' ]] || {
  printf '%s\n' 'ERROR: runtime service source entitlement set is broader than app-sandbox.' >&2
  exit 1
}

if [[ -n "$app_path" ]]; then
  xpc_path="${app_path}/Contents/XPCServices/SupraRuntimeService.xpc"
  [[ -d "$xpc_path" ]] || { printf 'ERROR: embedded XPC is missing: %s\n' "$xpc_path" >&2; exit 1; }
  codesign --verify --strict "$app_path"
  codesign --verify --strict "$xpc_path"
  codesign -dvv "$app_path" 2>&1 | grep -Fx 'Identifier=ai.supra.SupraAI' >/dev/null || {
    printf '%s\n' 'ERROR: signed app has the wrong code-signing identifier.' >&2
    exit 1
  }
  codesign -dvv "$xpc_path" 2>&1 | grep -Fx 'Identifier=ai.supra.SupraAI.SupraRuntimeService' >/dev/null || {
    printf '%s\n' 'ERROR: signed XPC has the wrong code-signing identifier.' >&2
    exit 1
  }

  signed_entitlements="$(mktemp)"
  trap 'rm -f "$signed_entitlements"' EXIT
  codesign -d --entitlements :- "$xpc_path" >"$signed_entitlements" 2>/dev/null
  plutil -lint "$signed_entitlements" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$signed_entitlements")" == 'true' ]] || {
    printf '%s\n' 'ERROR: signed XPC is missing its sandbox entitlement.' >&2
    exit 1
  }
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$signed_entitlements" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$signed_entitlements" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: signed XPC acquired file-picker or network entitlement.' >&2
    exit 1
  fi

  signed_keys="$(plutil -p "$signed_entitlements" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p')"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    case "$key" in
      com.apple.security.app-sandbox) ;;
      # Xcode injects only these three into ad-hoc UI-test products. The
      # distribution-signature branch below rejects them and requires the exact
      # production entitlement set.
      com.apple.security.get-task-allow \
        | com.apple.security.temporary-exception.files.absolute-path.read-only \
        | com.apple.security.temporary-exception.mach-lookup.global-name) ;;
      *)
        printf 'ERROR: signed XPC acquired unexpected entitlement: %s\n' "$key" >&2
        exit 1
        ;;
    esac
  done <<<"$signed_keys"

  # Sign-to-Run-Locally produces identifier-bearing ad-hoc code whose generated
  # designated requirement is a cdhash. A distribution signature must instead
  # expose the stable identifier requirement and the expected Team ID.
  if ! codesign -dvv "$app_path" 2>&1 | grep -F 'TeamIdentifier=not set' >/dev/null; then
    [[ "$signed_keys" == 'com.apple.security.app-sandbox' ]] || {
      printf '%s\n' 'ERROR: distribution-signed XPC entitlement set is broader than app-sandbox.' >&2
      exit 1
    }
    codesign -dvv "$app_path" 2>&1 | grep -Fx 'TeamIdentifier=2DP657YB3K' >/dev/null || {
      printf '%s\n' 'ERROR: signed app has the wrong Team ID.' >&2
      exit 1
    }
    codesign -dvv "$xpc_path" 2>&1 | grep -Fx 'TeamIdentifier=2DP657YB3K' >/dev/null || {
      printf '%s\n' 'ERROR: signed XPC has the wrong Team ID.' >&2
      exit 1
    }
    codesign -d -r- "$app_path" 2>&1 | grep -F 'identifier "ai.supra.SupraAI"' >/dev/null || {
      printf '%s\n' 'ERROR: app designated requirement omits its stable identifier.' >&2
      exit 1
    }
    codesign -d -r- "$xpc_path" 2>&1 | grep -F 'identifier "ai.supra.SupraAI.SupraRuntimeService"' >/dev/null || {
      printf '%s\n' 'ERROR: XPC designated requirement omits its stable identifier.' >&2
      exit 1
    }
  fi
fi

printf '%s\n' 'Runtime XPC signed-boundary gate passed.'
