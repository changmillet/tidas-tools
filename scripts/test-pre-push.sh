#!/bin/sh
# Focused regression for the pre-push deletion-only classification.
# Uses an isolated temporary Git repository and stub gate commands; it never
# contacts a remote, never builds Rust, and never reads .env or production data.
set -eu

# Isolate the entire test process, including hook invocations, from its caller.
# The source hook still uses Git's real bindings; only this fixture harness clears them.
for git_local_name in $(git rev-parse --local-env-vars); do
  unset "$git_local_name"
done

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
hook_src="$root/.githooks/pre-push"
helper_src="$root/scripts/pre-push-deletion-only.sh"
maintenance_src="$root/scripts/pre-push-maintenance-only.sh"

fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT HUP INT TERM

repo="$fixture/repo"
mkdir -p "$repo/.githooks" "$repo/scripts" "$fixture/bin"
cp "$hook_src" "$repo/.githooks/pre-push"
cp "$helper_src" "$repo/scripts/pre-push-deletion-only.sh"
cp "$maintenance_src" "$repo/scripts/pre-push-maintenance-only.sh"
chmod +x "$repo/.githooks/pre-push" "$repo/scripts/pre-push-deletion-only.sh" "$repo/scripts/pre-push-maintenance-only.sh"

trace="$fixture/trace"

# Ordered trace of every stub invocation, including full argv.
cat > "$repo/scripts/docpact-gate.sh" <<'STUB'
#!/bin/sh
{
  printf 'docpact-gate|%s' "$#"
  for argument do printf '|%s' "$argument"; done
  printf '\n'
} >> "$FIXTURE_TRACE"
if [ "${FIXTURE_EDIT_DURING_DOCPACT:-}" = 1 ]; then printf drift >> tracked.txt; fi
exit "${FIXTURE_DOCPACT_EXIT:-0}"
STUB
cat > "$repo/scripts/audit-rust-only.sh" <<'STUB'
#!/bin/sh
{
  printf 'audit-rust-only|%s' "$#"
  for argument do printf '|%s' "$argument"; done
  printf '\n'
} >> "$FIXTURE_TRACE"
exit "${FIXTURE_AUDIT_EXIT:-0}"
STUB
cat > "$fixture/bin/cargo" <<'STUB'
#!/bin/sh
case "$1" in
  run)
    case " $* " in
      *" public-rules-check "*) step=public-rules ;;
      *) step=asset-lock ;;
    esac
    ;;
  fmt) step=fmt ;;
  clippy) step=clippy ;;
  test) step=test ;;
  *) step="unknown:$1" ;;
esac
{
  printf '%s|%s' "$step" "$#"
  for argument do printf '|%s' "$argument"; done
  printf '\n'
} >> "$FIXTURE_TRACE"
if [ "${FIXTURE_FAIL_STEP:-}" = "$step" ]; then exit "${FIXTURE_FAIL_EXIT:-7}"; fi
exit "${FIXTURE_CARGO_EXIT:-0}"
STUB
chmod +x "$repo/scripts/docpact-gate.sh" "$repo/scripts/audit-rust-only.sh" "$fixture/bin/cargo"

(
  cd "$repo"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config core.hooksPath .githooks
  git config commit.gpgsign false
  printf 'fixture\n' > tracked.txt
  git add tracked.txt
  git commit -qm fixture
) >/dev/null 2>&1

sha1a=1111111111111111111111111111111111111111
sha1b=2222222222222222222222222222222222222222
zero40=0000000000000000000000000000000000000000
sha256a=$(printf 'ab%.0s' $(seq 1 32))
sha256b=$(printf 'cd%.0s' $(seq 1 32))
zero64=$(printf '00%.0s' $(seq 1 32))

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s: %s\n' "$1" "$2"; failures=$((failures+1)); }

# Remote name and a remote path containing a space exercise argument fidelity.
remote_name="origin"
remote_path="$fixture/remote with space.git"

run_hook() { # $1 = stdin file, $2 = extra env assignment (optional)
  : > "$trace"
  set +e
  (
    cd "$repo"
    env FIXTURE_TRACE="$trace" PATH="$fixture/bin:$PATH" ${2:-} \
        sh "$repo/.githooks/pre-push" "$remote_name" "$remote_path" < "$1"
  ) >"$fixture/out" 2>&1
  hook_rc=$?
  set -e
}

expected_gate_trace() {
  printf 'docpact-gate|2|%s|%s\n' "$remote_name" "$remote_path"
  printf 'audit-rust-only|0\n'
  printf 'asset-lock|8|run|--locked|-p|tidas-assets|--bin|tidas-asset-lock|--|check\n'
  printf 'public-rules|8|run|--locked|-p|tidas-assets|--bin|tidas-asset-lock|--|public-rules-check\n'
  printf 'fmt|3|fmt|--all|--check\n'
  printf 'clippy|7|clippy|--locked|--workspace|--all-targets|--|-D|warnings\n'
  printf 'test|4|test|--locked|--workspace|--all-targets\n'
}

# The full ordered gate trace must match exactly: order, uniqueness and argv.
expect_gate() {
  name="$1"; input="$2"; want_rc="${3:-0}"
  run_hook "$input" "${4:-}"
  if [ "$hook_rc" -ne "$want_rc" ]; then fail "$name" "exit $hook_rc, wanted $want_rc"; return; fi
  expected_gate_trace > "$fixture/expected"
  if ! diff -u "$fixture/expected" "$trace" > "$fixture/trace.diff" 2>&1; then
    fail "$name" "ordered gate trace differs: $(tr '\n' ';' < "$fixture/trace.diff" | cut -c1-200)"; return
  fi
  pass "$name"
}

expect_fast_path() {
  name="$1"; input="$2"
  run_hook "$input" "${3:-}"
  if [ "$hook_rc" -ne 0 ]; then fail "$name" "exit $hook_rc"; return; fi
  if [ -s "$trace" ]; then fail "$name" "gate ran: $(tr '\n' ' ' < "$trace")"; return; fi
  pass "$name"
}

write() { printf '%b' "$2" > "$fixture/$1"; }

# --- canonical wire inputs (classification) --------------------------------
write pure-delete "(delete) $zero40 refs/heads/old-branch $sha1a\n"
write multi-delete "(delete) $zero40 refs/heads/one $sha1a\n(delete) $zero40 refs/heads/two $sha1b\n"
write sha256-delete "(delete) $zero64 refs/heads/old-branch $sha256a\n"
write code-update "refs/heads/main $sha1a refs/heads/main $sha1b\n"
write branch-creation "refs/heads/new $sha1a refs/heads/new $zero40\n"
write tag-push "refs/tags/v1.0.0 $sha1a refs/tags/v1.0.0 $zero40\n"
write tag-delete "(delete) $zero40 refs/tags/v1.0.0 $sha1a\n"
write mixed "(delete) $zero40 refs/heads/gone $sha1a\nrefs/heads/main $sha1a refs/heads/main $sha1b\n"
write delete-last "refs/heads/main $sha1a refs/heads/main $sha1b\n(delete) $zero40 refs/heads/gone $sha1b\n"
write empty ""
write blank-line "\n"
write malformed "(delete) $zero40\n"
write truncated "(delete) $zero40 refs/heads/old-branch\n"
write five-fields "(delete) $zero40 refs/heads/one $sha1a extra\n"
write short-sha "(delete) 0000 refs/heads/one $sha1a\n"
write unknown-sha-length "(delete) $(printf '0%.0s' $(seq 1 50)) refs/heads/one $sha1a\n"
write zero-remote "(delete) $zero40 refs/heads/one $zero40\n"
write invalid-ref "(delete) $zero40 refs/heads/bad name $sha1a\n"
write delete-marker-nonzero-local "(delete) $sha1a refs/heads/one $sha1b\n"
write non-branch-ref "(delete) $zero40 refs/notes/x $sha1a\n"
write no-trailing-newline "(delete) $zero40 refs/heads/old-branch $sha1a"
write crlf "(delete) $zero40 refs/heads/old-branch $sha1a\r\n"
write nul "(delete) $zero40 refs/heads/old-branch $sha1a\000\n"
write ref-dotdot "(delete) $zero40 refs/heads/../evil $sha1a\n"
write width-mismatch "(delete) $zero40 refs/heads/one $sha256a\n"
write non-hex-remote "(delete) $zero40 refs/heads/one zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n"
write sha256-non-hex-remote "(delete) $zero64 refs/heads/one $(printf 'zz%.0s' $(seq 1 32))\n"

# The polluted invocation covers fixture creation and both hook branches; the
# full wire-format matrix runs once in the parent, not redundantly twice.
if [ "${1:-}" = '--polluted-child' ]; then
  expect_fast_path "polluted caller: deletion" "$fixture/pure-delete"
  expect_gate "polluted caller: code publication" "$fixture/code-update"
  [ "$failures" -eq 0 ]
  exit
fi

expect_fast_path "pure branch deletion skips the gate"        "$fixture/pure-delete"
expect_fast_path "multiple branch deletions skip the gate"    "$fixture/multi-delete"
expect_fast_path "SHA256 wire deletion skips the gate"        "$fixture/sha256-delete"

expect_gate "code update runs the full gate"                  "$fixture/code-update"
expect_gate "branch creation runs the full gate"              "$fixture/branch-creation"
expect_gate "tag push runs the full gate"                     "$fixture/tag-push"
expect_gate "tag deletion runs the full gate"                 "$fixture/tag-delete"
expect_gate "mixed delete+update runs the full gate"          "$fixture/mixed"
expect_gate "code then delete still runs the full gate"       "$fixture/delete-last"
expect_gate "empty input runs the full gate"                  "$fixture/empty"
expect_gate "blank line runs the full gate"                   "$fixture/blank-line"
expect_gate "malformed line runs the full gate"               "$fixture/malformed"
expect_gate "truncated line runs the full gate"               "$fixture/truncated"
expect_gate "five fields run the full gate"                   "$fixture/five-fields"
expect_gate "short SHA runs the full gate"                    "$fixture/short-sha"
expect_gate "unknown SHA length runs the full gate"           "$fixture/unknown-sha-length"
expect_gate "zero remote oid runs the full gate"              "$fixture/zero-remote"
expect_gate "invalid ref runs the full gate"                  "$fixture/invalid-ref"
expect_gate "delete marker with non-zero local oid runs the full gate" "$fixture/delete-marker-nonzero-local"
expect_gate "non-branch ref runs the full gate"               "$fixture/non-branch-ref"
expect_gate "missing trailing newline runs the full gate"     "$fixture/no-trailing-newline"
expect_gate "CRLF input runs the full gate"                   "$fixture/crlf"
expect_gate "NUL byte runs the full gate"                     "$fixture/nul"
expect_gate "dot-dot ref runs the full gate"                  "$fixture/ref-dotdot"
expect_gate "40/64 width mismatch runs the full gate"         "$fixture/width-mismatch"
expect_gate "non-hex remote SHA runs the full gate"           "$fixture/non-hex-remote"
expect_gate "non-hex SHA256 remote runs the full gate"        "$fixture/sha256-non-hex-remote"

# Locale-sensitive shell ranges must not admit uppercase object IDs.
write locale-lower-sha1 "(delete) $zero40 refs/heads/hex 0123456789abcdef0123456789abcdef01234567\n"
write locale-upper-sha1 "(delete) $zero40 refs/heads/hex $(printf 'A%.0s' $(seq 1 40))\n"
write locale-upper-sha256 "(delete) $zero64 refs/heads/hex $(printf 'A%.0s' $(seq 1 64))\n"
for oid_test_locale in C en_US.UTF-8; do
  # C is always exercised. A host without this UTF-8 locale must report that
  # limitation instead of claiming the affected collation was tested.
  if [ "$oid_test_locale" != C ]; then
    if ! env LC_ALL="$oid_test_locale" locale charmap > "$fixture/locale-charmap" 2> "$fixture/locale-warning" ||
       [ -s "$fixture/locale-warning" ] ||
       ! grep -Eq '^UTF-?8$' "$fixture/locale-charmap"; then
      printf 'skip - unavailable test locale: %s\n' "$oid_test_locale"
      continue
    fi
  fi
  expect_fast_path "lowercase SHA1 deletion ($oid_test_locale)" "$fixture/locale-lower-sha1" "LC_ALL=$oid_test_locale"
  expect_fast_path "lowercase SHA256 deletion ($oid_test_locale)" "$fixture/sha256-delete" "LC_ALL=$oid_test_locale"
  expect_gate "uppercase SHA1 keeps full gate ($oid_test_locale)" "$fixture/locale-upper-sha1" 0 "LC_ALL=$oid_test_locale"
  expect_gate "uppercase SHA256 keeps full gate ($oid_test_locale)" "$fixture/locale-upper-sha256" 0 "LC_ALL=$oid_test_locale"
done

# --- failure propagation: exact code and no later gate step ----------------
expect_failure() { # name, input, failing step, expected exit code, env assignment
  name="$1"; input="$2"; step="$3"; want_rc="$4"; env_assign="$5"
  run_hook "$input" "$env_assign"
  if [ "$hook_rc" -ne "$want_rc" ]; then fail "$name" "exit $hook_rc, wanted $want_rc"; return; fi
  seen="$(cut -d'|' -f1 "$trace" | tr '\n' ' ')"
  case "$seen" in
    *"$step"*) ;;
    *) fail "$name" "failing step '$step' never ran"; return ;;
  esac
  after="$(printf '%s\n' "$seen" | sed 's/.*'"$step"'//')"
  if [ -n "$(printf '%s' "$after" | tr -d ' ')" ]; then
    fail "$name" "gate continued after $step: $after"; return
  fi
  pass "$name"
}

expect_failure "Docpact failure exits 64 and stops the gate" \
  "$fixture/code-update" docpact-gate 64 "FIXTURE_DOCPACT_EXIT=64"
expect_failure "audit failure exits 9 and stops the gate" \
  "$fixture/code-update" audit-rust-only 9 "FIXTURE_AUDIT_EXIT=9"
expect_failure "public-rule composition failure exits 7 and stops the gate" \
  "$fixture/code-update" public-rules 7 "FIXTURE_FAIL_STEP=public-rules FIXTURE_FAIL_EXIT=7"
expect_failure "intermediate Cargo failure exits 7 and stops the gate" \
  "$fixture/code-update" fmt 7 "FIXTURE_FAIL_STEP=fmt FIXTURE_FAIL_EXIT=7"
expect_failure "final Cargo failure exits 7" \
  "$fixture/code-update" test 7 "FIXTURE_FAIL_STEP=test FIXTURE_FAIL_EXIT=7"

# --- helper availability and classifier failure fall back to the gate ------
mv "$repo/scripts/pre-push-deletion-only.sh" "$fixture/classifier-original"
expect_gate "missing classifier falls back to the complete ordered gate" "$fixture/pure-delete"
printf '#!/bin/sh\nexit 42\n' > "$repo/scripts/pre-push-deletion-only.sh"
chmod +x "$repo/scripts/pre-push-deletion-only.sh"
expect_gate "failing classifier falls back to the complete ordered gate" "$fixture/pure-delete"
mv "$fixture/classifier-original" "$repo/scripts/pre-push-deletion-only.sh"

# --- maintenance ranges use real commits and the actual complete hook -------
# Track all fixture helpers so cleanliness checks are real, not stubbed Git.
(
  cd "$repo"
  mkdir -p .github docs
  printf 'version: 2\nupdates: []\n' > .github/dependabot.yml
  printf '# Dependency maintenance\n' > docs/dependency-maintenance.md
  git add .
  git commit -qm 'fixture maintenance base'
  git checkout -qb maintenance-fixture
)
maintenance_ref=refs/heads/maintenance-fixture
maintenance_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$maintenance_base"

maintenance_reset() { git -C "$repo" reset --hard -q "$maintenance_base"; git -C "$repo" clean -fdq; }
maintenance_commit() {
  git -C "$repo" add -A
  maintenance_commit_index
}
# Index plumbing fixtures must commit their explicit modes without re-adding
# the worktree, which may not expose executable bits or physical symlinks.
maintenance_commit_index() {
  git -C "$repo" commit -qm 'fixture candidate'
  maintenance_head="$(git -C "$repo" rev-parse HEAD)"
  printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$maintenance_base" > "$fixture/maintenance-wire"
}
# Fail the fixture itself if it did not create the intended committed mode.
assert_tree_mode() { # mode, path
  actual_mode="$(git -C "$repo" ls-tree HEAD -- "$2" | cut -d ' ' -f 1)"
  if [ "$actual_mode" != "$1" ]; then
    printf 'fixture mode for %s is %s, wanted %s\n' "$2" "$actual_mode" "$1" >&2
    exit 1
  fi
}
expect_maintenance() { # name, optional env
  run_hook "$fixture/maintenance-wire" "${2:-}"
  printf 'docpact-gate|6|%s|%s|--base|%s|--head|%s\n' "$remote_name" "$remote_path" "$maintenance_base" "$maintenance_head" > "$fixture/expected"
  if [ "$hook_rc" -eq 0 ] && cmp -s "$fixture/expected" "$trace"; then
    pass "$1"
  else
    fail "$1" "exact candidate Docpact-only trace or exit differs (exit=$hook_rc)"
    cat "$fixture/out" >&2
  fi
}

printf '# changed\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
expect_maintenance 'known clean monitor-only update uses exact wire range'
expect_maintenance 'ambient Docpact comparison cannot replace exact wire range' 'DOCPACT_BASE_REF=unrelated'
maintenance_reset
printf 'Reviewed\n' >> "$repo/docs/dependency-maintenance.md"
maintenance_commit
expect_maintenance 'focused guide-only update uses exact wire range'
printf '# paired config\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
expect_maintenance 'both allowed paths across all candidate commits remain maintenance-only'

# A known maintenance range must still fail Docpact; no Rust step follows it.
run_hook "$fixture/maintenance-wire" 'FIXTURE_DOCPACT_EXIT=64'
if [ "$hook_rc" -eq 64 ] && [ "$(wc -l < "$trace" | tr -d ' ')" -eq 1 ]; then
  pass 'maintenance Docpact failure is preserved without a bypass'
else fail 'maintenance Docpact failure is preserved' "exit=$hook_rc"; fi

# Dirty/index/untracked state cannot substitute working contents for the commit.
printf 'dirty runtime\n' >> "$repo/tracked.txt"
expect_gate 'dirty tracked candidate keeps full gate' "$fixture/maintenance-wire"
git -C "$repo" add tracked.txt
expect_gate 'staged runtime edit keeps full gate' "$fixture/maintenance-wire"
git -C "$repo" reset --hard -q "$maintenance_head"
printf 'untracked runtime\n' > "$repo/untracked.rs"
expect_gate 'untracked candidate keeps full gate' "$fixture/maintenance-wire"
rm "$repo/untracked.rs"

# Revalidation after Docpact must detect drift and execute the full path.
run_hook "$fixture/maintenance-wire" 'FIXTURE_EDIT_DURING_DOCPACT=1'
{
  printf 'docpact-gate|6|%s|%s|--base|%s|--head|%s\n' "$remote_name" "$remote_path" "$maintenance_base" "$maintenance_head"
  expected_gate_trace
} > "$fixture/expected"
if [ "$hook_rc" -eq 0 ] && cmp -s "$fixture/expected" "$trace"; then
  pass 'candidate drift during Docpact falls back to full ordered gate'
else fail 'candidate drift during Docpact falls back' "exit=$hook_rc"; fi
git -C "$repo" reset --hard -q "$maintenance_head"

# Index flags must not hide actual changed bytes from candidate cleanliness.
for hidden_flag in assume-unchanged skip-worktree; do
  git -C "$repo" update-index --"$hidden_flag" tracked.txt
  printf 'hidden runtime bytes\n' >> "$repo/tracked.txt"
  expect_gate "hidden dirty $hidden_flag entry keeps full gate" "$fixture/maintenance-wire"
  git -C "$repo" update-index --no-"$hidden_flag" tracked.txt
  git -C "$repo" reset --hard -q "$maintenance_head"
done

# Every executable/runtime/native/workflow or unknown path retains full checks.
for protected in Cargo.toml Cargo.lock crates/example/src/lib.rs assets/fixture.json \
  packaging/vcpkg/vcpkg.json .github/workflows/rust-ci.yml .github/actions/native-xml/action.yml \
  scripts/native-cache-contract.sh scripts/pre-push-maintenance-only.sh .docpact/config.yaml unknown.txt; do
  maintenance_reset
  mkdir -p "$(dirname "$repo/$protected")"
  printf '# protected candidate\n' >> "$repo/$protected"
  printf '# maintenance too\n' >> "$repo/.github/dependabot.yml"
  maintenance_commit
  expect_gate "mixed/protected path $protected keeps full gate" "$fixture/maintenance-wire"
done

# An old remote feature tip does not prove its unmerged runtime work passed.
# The wire B..C is config-only, but canonical Main A..C includes protected B.
for already_remote_path in Cargo.toml crates/runtime.rs packaging/vcpkg/vcpkg.json; do
  maintenance_reset
  mkdir -p "$(dirname "$repo/$already_remote_path")"
  printf 'already-pushed runtime/native input\n' > "$repo/$already_remote_path"
  maintenance_commit
  already_remote="${maintenance_head}"
  printf '# later config only\n' >> "$repo/.github/dependabot.yml"
  maintenance_commit
  printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$already_remote" > "$fixture/maintenance-wire"
  expect_gate "already-remote $already_remote_path remains cumulative protected work" "$fixture/maintenance-wire"
done

# Unknown or non-contained canonical tracking context cannot prove scope.
maintenance_reset
printf '# canonical context controls\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
git -C "$repo" update-ref -d refs/remotes/origin/main
expect_gate 'missing canonical Main keeps full gate' "$fixture/maintenance-wire"
git -C "$repo" update-ref refs/remotes/origin/main "$maintenance_base"
noncommit_main="$(git -C "$repo" rev-parse "$maintenance_base:.github/dependabot.yml")"
git -C "$repo" update-ref refs/remotes/origin/main "$noncommit_main"
expect_gate 'noncommit canonical tracking object keeps full gate' "$fixture/maintenance-wire"
git -C "$repo" update-ref refs/remotes/origin/main "$maintenance_base"
canonical_tree="$(git -C "$repo" rev-parse "$maintenance_base^{tree}")"
diverged_main="$(printf 'diverged canonical' | git -C "$repo" commit-tree "$canonical_tree" -p "$maintenance_base")"
git -C "$repo" update-ref refs/remotes/origin/main "$diverged_main"
expect_gate 'diverged canonical Main keeps full gate' "$fixture/maintenance-wire"
git -C "$repo" update-ref refs/remotes/origin/main "$maintenance_base"
old_main="$(git -C "$repo" rev-parse "$maintenance_base^")"
git -C "$repo" update-ref refs/remotes/origin/main "$old_main"
expect_gate 'stale older Main broadens rather than hides unmerged inputs' "$fixture/maintenance-wire"
git -C "$repo" update-ref refs/remotes/origin/main "$maintenance_base"

# Two best merge bases are an ambiguous candidate context, even with equal trees.
left="$(printf left | git -C "$repo" commit-tree "$canonical_tree" -p "$maintenance_base")"
right="$(printf right | git -C "$repo" commit-tree "$canonical_tree" -p "$maintenance_base")"
left_merge="$(printf left-merge | git -C "$repo" commit-tree "$canonical_tree" -p "$left" -p "$right")"
right_merge="$(printf right-merge | git -C "$repo" commit-tree "$canonical_tree" -p "$right" -p "$left")"
git -C "$repo" reset --hard -q "$right_merge"
printf '# ambiguous canonical context\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$right_merge" > "$fixture/maintenance-wire"
git -C "$repo" update-ref refs/remotes/origin/main "$left_merge"
expect_gate 'multiple canonical merge bases keep full gate' "$fixture/maintenance-wire"
git -C "$repo" update-ref refs/remotes/origin/main "$maintenance_base"

# The complete range, not HEAD's last commit alone, governs eligibility.
maintenance_reset
printf 'earlier runtime edit\n' >> "$repo/tracked.txt"
maintenance_commit
printf '# latest docs only\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
expect_gate 'earlier runtime change in range keeps full gate' "$fixture/maintenance-wire"

# Even if a protected edit is reverted before the final tree, its pushed range
# does not become a maintenance-only delivery.
maintenance_reset
printf 'temporary runtime edit\n' >> "$repo/tracked.txt"
maintenance_commit
git -C "$repo" checkout "$maintenance_base" -- tracked.txt
printf '# runtime reverted\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
expect_gate 'reverted runtime commit still keeps full gate' "$fixture/maintenance-wire"
maintenance_reset
# chmod alone is not a Git mode change when core.fileMode=false (Windows).
# Keep the worktree consistent where supported and encode the tree explicitly.
chmod +x "$repo/.github/dependabot.yml"
git -C "$repo" update-index --chmod=+x .github/dependabot.yml
maintenance_commit_index
assert_tree_mode 100755 .github/dependabot.yml
chmod -x "$repo/.github/dependabot.yml"
printf '# mode reverted\n' >> "$repo/.github/dependabot.yml"
git -C "$repo" add -A
git -C "$repo" update-index --chmod=-x .github/dependabot.yml
maintenance_commit_index
assert_tree_mode 100644 .github/dependabot.yml
expect_gate 'reverted executable mode still keeps full gate' "$fixture/maintenance-wire"

maintenance_reset
chmod +x "$repo/.github/dependabot.yml"
git -C "$repo" update-index --chmod=+x .github/dependabot.yml
maintenance_commit_index
assert_tree_mode 100755 .github/dependabot.yml
expect_gate 'allowed path mode change keeps full gate' "$fixture/maintenance-wire"
maintenance_reset
# Store a real Git symlink even when checkout represents it as a regular file
# containing the target (core.symlinks=false); no symlink privilege is required.
link_blob="$(printf '%s' ../tracked.txt | git -C "$repo" hash-object -w --stdin)"
git -C "$repo" update-index --add --cacheinfo "120000,$link_blob,docs/dependency-maintenance.md"
maintenance_commit_index
assert_tree_mode 120000 docs/dependency-maintenance.md
rm "$repo/docs/dependency-maintenance.md"
git -C "$repo" checkout-index -- docs/dependency-maintenance.md
git -C "$repo" diff --exit-code HEAD -- docs/dependency-maintenance.md
expect_gate 'allowed path symlink keeps full gate' "$fixture/maintenance-wire"
maintenance_reset
rm "$repo/docs/dependency-maintenance.md"
maintenance_commit
expect_gate 'allowed path deletion keeps full gate' "$fixture/maintenance-wire"
maintenance_reset
git -C "$repo" mv docs/dependency-maintenance.md docs/renamed.md
maintenance_commit
expect_gate 'rename from allowed path keeps full gate' "$fixture/maintenance-wire"
maintenance_reset
printf '# known\n' >> "$repo/.github/dependabot.yml"
maintenance_commit
printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$zero40" > "$fixture/maintenance-new"
expect_gate 'real new-branch creation has unknown range and keeps full gate' "$fixture/maintenance-new"
printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_base" "$maintenance_ref" "$maintenance_head" > "$fixture/maintenance-stale"
expect_gate 'non-HEAD local candidate keeps full gate' "$fixture/maintenance-stale"
printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$sha1a" > "$fixture/maintenance-unknown"
expect_gate 'unknown remote commit keeps full gate' "$fixture/maintenance-unknown"
printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$maintenance_head" > "$fixture/maintenance-empty"
expect_gate 'empty source range keeps full gate' "$fixture/maintenance-empty"
cat "$fixture/maintenance-wire" "$fixture/maintenance-wire" > "$fixture/maintenance-multi"
expect_gate 'multiple updates keep full gate' "$fixture/maintenance-multi"
cat "$fixture/pure-delete" "$fixture/maintenance-wire" > "$fixture/maintenance-mixed"
expect_gate 'delete plus maintenance is mixed and keeps full gate' "$fixture/maintenance-mixed"

# A foreign root commit cannot be a proven published ancestor.
foreign_tree="$(git -C "$repo" rev-parse "$maintenance_base^{tree}")"
unrelated="$(printf unrelated | git -C "$repo" commit-tree "$foreign_tree")"
printf '%s %s %s %s\n' "$maintenance_ref" "$maintenance_head" "$maintenance_ref" "$unrelated" > "$fixture/maintenance-unrelated"
expect_gate 'unrelated remote history keeps full gate' "$fixture/maintenance-unrelated"

mv "$repo/scripts/pre-push-maintenance-only.sh" "$fixture/maintenance-helper"
expect_gate 'missing maintenance classifier keeps complete gate' "$fixture/maintenance-wire"
printf '#!/bin/sh\nexit 42\n' > "$repo/scripts/pre-push-maintenance-only.sh"
chmod +x "$repo/scripts/pre-push-maintenance-only.sh"
expect_gate 'failed maintenance classifier keeps complete gate' "$fixture/maintenance-wire"
mv "$fixture/maintenance-helper" "$repo/scripts/pre-push-maintenance-only.sh"
maintenance_reset

# --- manual TTY input must not block --------------------------------------
# The guard must run before any stdin read; a terminal is never wire format.
guard_line="$(grep -n '\[ -t 0 \] && exit 1' "$helper_src" | cut -d: -f1)"
read_line="$(grep -n 'cat > "\$tmp"' "$helper_src" | head -1 | cut -d: -f1)"
if [ -n "$guard_line" ] && [ -n "$read_line" ] && [ "$guard_line" -lt "$read_line" ]; then
  pass "TTY guard precedes the first stdin read (line $guard_line < $read_line)"
else
  fail "TTY guard precedes the first stdin read" "guard=$guard_line read=$read_line"
fi

# Run this same harness under foreign bindings; do not test a copied cleanup snippet.
if [ "${1:-}" != '--polluted-child' ]; then
  foreign="$fixture/foreign-repo"
  git init -q "$foreign"
  git -C "$foreign" config core.hooksPath "$fixture/no-hooks"
  git -C "$foreign" config commit.gpgsign false
  git -C "$foreign" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
  git -C "$foreign" show-ref > "$fixture/foreign-before"
  cp "$foreign/.git/config" "$fixture/foreign-config"
  set +e
  env GIT_DIR="$foreign/.git" GIT_WORK_TREE="$foreign" GIT_INDEX_FILE="$foreign/.git/index" \
    sh "$root/scripts/test-pre-push.sh" --polluted-child > "$fixture/polluted.log" 2>&1
  polluted_rc=$?
  set -e
  git -C "$foreign" show-ref > "$fixture/foreign-after"
  if [ "$polluted_rc" -eq 0 ] && cmp -s "$fixture/foreign-before" "$fixture/foreign-after" \
    && cmp -s "$fixture/foreign-config" "$foreign/.git/config" \
    && [ -z "$(git -C "$foreign" status --porcelain)" ]; then
    pass "fixture creation and both hook paths isolate foreign Git bindings and preserve foreign repo"
  else
    fail "fixture creation and both hook paths isolate foreign Git bindings" "child exit=$polluted_rc"
    cat "$fixture/polluted.log" >&2
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d case(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall pre-push deletion and exact maintenance-range cases passed\n'
