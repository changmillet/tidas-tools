#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/scripts/native-cache-contract.sh"
baseline=40f3c709db80acf154ac4b17a1f83c564ebd022e
inputs=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
key() { bash "$helper" key "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
original="$(key Linux-X64 ubuntu24-20260914 linux x64-linux "$baseline" "$inputs")"
[[ "$original" == "$(key Linux-X64 ubuntu24-20260914 linux x64-linux "$baseline" "$inputs")" ]] || fail 'unstable identity'
for changed in \
  "$(key Linux-X64 ubuntu24-20260915 linux x64-linux "$baseline" "$inputs")" \
  "$(key Linux-ARM64 ubuntu24-20260914 linux arm64-linux "$baseline" "$inputs")" \
  "$(key Linux-X64 ubuntu24-20260914 linux x64-linux "${baseline%?}f" "$inputs")" \
  "$(key Linux-X64 ubuntu24-20260914 linux x64-linux "$baseline" "${inputs%?}b")"; do
  [[ "$changed" != "$original" ]] || fail 'changed input reused a cache identity'
done
for missing in '' unknown 'line
break'; do
  if key Linux-X64 "$missing" linux x64-linux "$baseline" "$inputs" >/dev/null 2>&1; then fail 'invalid image accepted'; fi
done
if key Linux-X64 ubuntu24-20260914 linux x64-windows-static "$baseline" "$inputs" >/dev/null 2>&1; then fail 'foreign triplet accepted'; fi
if key Windows-X64 windows2025-20260914 linux x64-linux "$baseline" "$inputs" >/dev/null 2>&1; then fail 'foreign runner family accepted'; fi
key macOS-ARM64 macos15-20260914 macos arm64-osx "$baseline" "$inputs" >/dev/null
key Windows-X64 windows2025-20260914 windows x64-windows-static "$baseline" "$inputs" >/dev/null
if key Linux-X64 ubuntu24-20260914 linux x64-linux latest "$inputs" >/dev/null 2>&1; then fail 'floating baseline accepted'; fi
if key Linux-X64 ubuntu24-20260914 linux x64-linux "$baseline" '' >/dev/null 2>&1; then fail 'missing implementation/manifest hash accepted'; fi
if key Linux-X64 ubuntu24-20260914 linux x64-linux "$baseline" "$inputs" extra >/dev/null 2>&1; then fail 'unexpected argument accepted'; fi
bash "$helper" verify linux success skipped
bash "$helper" verify macos success skipped
bash "$helper" verify windows skipped success
for bad in skipped failure cancelled ''; do
  if bash "$helper" verify linux "$bad" skipped >/dev/null 2>&1; then fail 'Unix installation was not required'; fi
  if bash "$helper" verify windows skipped "$bad" >/dev/null 2>&1; then fail 'Windows installation was not required'; fi
done
if bash "$helper" verify windows success success >/dev/null 2>&1; then fail 'wrong platform installation accepted'; fi
if bash "$helper" verify other success skipped >/dev/null 2>&1; then fail 'unsupported family accepted'; fi
printf 'Native cache identity and required-installation regressions passed.\n'
