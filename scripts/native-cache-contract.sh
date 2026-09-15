#!/usr/bin/env bash
# Cache identity is setup evidence; successful native installation is mandatory.
set -euo pipefail
mode="${1:-}"
[[ $# -gt 0 ]] && shift
fail() { printf '%s\n' "$*" >&2; exit 64; }
case "$mode" in
  key)
    [[ $# -eq 6 ]] || fail 'Expected platform, image, family, triplet, baseline and input hash.'
    platform="$1" image="$2" family="$3" triplet="$4" baseline="$5" inputs="$6"
    [[ "$platform" =~ ^[A-Za-z]+-(X64|ARM64)$ ]] || fail 'Missing or invalid runner platform.'
    [[ "$image" =~ ^[A-Za-z][A-Za-z0-9._-]*-[0-9][A-Za-z0-9._-]*$ ]] || fail 'Missing or invalid hosted runner image identity.'
    [[ "$baseline" =~ ^[0-9a-f]{40}$ ]] || fail 'vcpkg baseline must be an exact commit.'
    [[ "$inputs" =~ ^[0-9a-f]{64}$ ]] || fail 'Native implementation/manifest hash is required.'
    case "$platform/$family/$triplet" in
      Linux-X64/linux/x64-linux | Linux-ARM64/linux/arm64-linux | macOS-ARM64/macos/arm64-osx | Windows-X64/windows/x64-windows-static) ;;
      *) fail 'Unsupported runner platform/native family/triplet combination.' ;;
    esac
    if command -v sha256sum >/dev/null 2>&1; then
      digest="$(printf '%s\n' "$@" | sha256sum | cut -d ' ' -f 1)"
    else
      digest="$(printf '%s\n' "$@" | shasum -a 256 | cut -d ' ' -f 1)"
    fi
    printf 'native-xml-v1-%s-%s-%s\n' "$platform" "$triplet" "$digest"
    ;;
  verify)
    [[ $# -eq 3 ]] || fail 'Expected family and both installation outcomes.'
    case "$1/$2/$3" in
      linux/success/skipped | macos/success/skipped | windows/skipped/success)
        printf 'Required native installation executed successfully.\n' ;;
      *) fail 'The selected native installation must execute successfully; cache state is not acceptance.' ;;
    esac
    ;;
  *) fail 'Usage: native-cache-contract.sh key|verify <inputs>' ;;
esac
