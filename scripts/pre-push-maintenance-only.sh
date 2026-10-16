#!/bin/sh
# Print the exact remote/local commit range only for an existing clean branch
# update containing modifications to dependency-monitoring config/guide alone.
# Unknown, malformed, new/mixed/non-ancestor ranges keep the complete gate.
set -eu

[ -t 0 ] && exit 1
wire="$(mktemp "${TMPDIR:-/tmp}/pre-push-maintenance.XXXXXX")" || exit 1
trap 'rm -f "$wire"' EXIT HUP INT TERM
cat > "$wire" || exit 1
[ -s "$wire" ] || exit 1
[ "$(wc -l < "$wire" | tr -d ' ')" -eq 1 ] || exit 1
[ "$(tail -c 1 "$wire" | wc -l | tr -d ' ')" -eq 1 ] || exit 1
total="$(wc -c < "$wire" | tr -d ' ')"
canonical="$(tr -d '\r\000\t' < "$wire" | wc -c | tr -d ' ')"
[ "$total" -eq "$canonical" ] || exit 1

IFS=' ' read -r local_ref local_oid remote_ref remote_oid < "$wire"
# Canonical four-field input only; reject collapsed whitespace and extra fields.
[ "$(cat "$wire")" = "$local_ref $local_oid $remote_ref $remote_oid" ] || exit 1
[ "$local_ref" = "$remote_ref" ] || exit 1
case "$local_ref" in refs/heads/*) ;; *) exit 1 ;; esac
git check-ref-format "$local_ref" >/dev/null 2>&1 || exit 1
for oid in "$local_oid" "$remote_oid"; do
  case "${#oid}" in 40|64) ;; *) exit 1 ;; esac
  case "$oid" in *[!0123456789abcdef]*) exit 1 ;; esac
  # A creation/deletion has no known candidate range and always keeps full checks.
  [ -n "$(printf '%s' "$oid" | tr -d '0')" ] || exit 1
done
[ "${#local_oid}" -eq "${#remote_oid}" ] || exit 1
[ "$local_oid" != "$remote_oid" ] || exit 1
[ "$(git symbolic-ref --quiet HEAD 2>/dev/null)" = "$local_ref" ] || exit 1
[ "$(git rev-parse --verify HEAD 2>/dev/null)" = "$local_oid" ] || exit 1
for oid in "$local_oid" "$remote_oid"; do
  [ "$(git cat-file -t "$oid" 2>/dev/null)" = commit ] || exit 1
done
git merge-base --is-ancestor "$remote_oid" "$local_oid" >/dev/null 2>&1 || exit 1
# Already-pushed feature work is not a qualification receipt. The canonical
# tracking Main must be a known commit contained in this cumulative candidate;
# multiple merge bases/divergence/unknown context cannot select the exception.
canonical_main="$(git rev-parse --verify refs/remotes/origin/main 2>/dev/null)" || exit 1
[ "$(git cat-file -t "$canonical_main" 2>/dev/null)" = commit ] || exit 1
canonical_bases="$(git merge-base --all "$canonical_main" "$local_oid" 2>/dev/null)" || exit 1
[ "$canonical_bases" = "$canonical_main" ] || exit 1
# The checked-out inputs used by Docpact must be the exact candidate, not dirty,
# staged, untracked or side-branch contents. Ignored build outputs do not count.
# Hidden index flags can suppress an ordinary diff. Read them without changing
# the user's index; any non-normal/assumed/sparse/fsmonitor-valid entry is full.
for flag_option in -v -f; do
  index_entries="$(git -c core.fsmonitor=false ls-files "$flag_option")" || exit 1
  [ -n "$index_entries" ] || exit 1
  while IFS= read -r entry; do
    case "$entry" in 'H '*) ;; *) exit 1 ;; esac
  done <<EOF_INDEX
$index_entries
EOF_INDEX
done
git -c core.fsmonitor=false diff --quiet HEAD -- || exit 1
untracked="$(git -c core.fsmonitor=false ls-files --others --exclude-standard)" || exit 1
[ -z "$untracked" ] || exit 1
# Both the exact push delta and all unmerged work must be monitoring-only.
for comparison_base in "$remote_oid" "$canonical_main"; do
  [ "$comparison_base" != "$local_oid" ] || continue
paths="$(git -c core.quotePath=true diff --name-only --no-renames "$comparison_base" "$local_oid" --)" || exit 1
[ -n "$paths" ] || exit 1
while IFS= read -r path; do
  case "$path" in
    .github/dependabot.yml|docs/dependency-maintenance.md) ;;
    *) exit 1 ;;
  esac
  # No additions/deletions, symlinks, executable bits or renamed side effects.
  for oid in "$comparison_base" "$local_oid"; do
    entry="$(git ls-tree "$oid" -- "$path")" || exit 1
    case "$entry" in '100644 blob '*) ;; *) exit 1 ;; esac
  done
done <<EOF_PATHS
$paths
EOF_PATHS
# Inspect every published commit, including both sides of merges. A protected
# edit followed by a revert is still a protected range, not monitoring work.
changes="$(git -c core.quotePath=true log --format= --raw --no-abbrev -m --no-renames "$comparison_base..$local_oid" --)" || exit 1
[ -n "$changes" ] || exit 1
while IFS="$(printf '\t')" read -r metadata path; do
  [ -n "$metadata" ] || continue
  case "$path" in
    .github/dependabot.yml|docs/dependency-maintenance.md) ;;
    *) exit 1 ;;
  esac
  case "$metadata" in ':100644 100644 '*" M") ;; *) exit 1 ;; esac
done <<EOF_CHANGES
$changes
EOF_CHANGES
done
printf '%s %s\n' "$remote_oid" "$local_oid"
