---
title: Toolkit dependency maintenance
docType: guide
scope: repo
status: active
authoritative: false
owner: tidas-tools
language: en
whenToUse:
  - when reviewing Cargo, Actions or vcpkg proposals and explicit native/toolchain pins
  - when a monitoring-only update uses the existing pre-push hook
whenToUpdate:
  - when discovery scope, exact native ownership, maintenance classification or qualification changes
checkPaths:
  - .github/dependabot.yml
  - docs/dependency-maintenance.md
lastReviewedAt: 2026-10-16
lastReviewedCommit: 703dd262b205b847f21d618aacc4ea06e5c5b347
lastReviewedNote: "Reviewed Toolkit #247 candidate against its current base; baseline/compiler/runtime inputs remain unchanged. Hosted updater and native candidate qualification are separate."
---

# Dependency maintenance

`.github/dependabot.yml` monitors Cargo, Actions and the vcpkg manifest in
`packaging/vcpkg`. The vcpkg entry is weekly, staggered in Asia/Shanghai, with a
seven-day default cooldown and one open proposal. The existing Cargo/Actions
cadence and limits are preserved. No automatic merge or native upgrade occurs
when this configuration lands; validate the first actual hosted vcpkg job and
its proposal before claiming discovery works.

The official updater explicitly reads/writes `builtin-baseline` in `vcpkg.json`,
including bare string ports governed by the baseline. It does not individually
remediate transitive ports or ports from unsupported external registries.
Baseline discovery is not full native security coverage.

## Exact native and toolchain ownership

| Input | Source and handling | Required qualification |
| --- | --- | --- |
| vcpkg built-in baseline / libxslt closure | `packaging/vcpkg/vcpkg.json`; official vcpkg updater supports this format | Keep its baseline and `VCPKG_COMMIT` in `rust-release.yml` coordinated; never accept a baseline-only proposal as a qualified native build. |
| vcpkg checkout/build and static XML/CRT inputs | Explicit workflow/action pins, triplets and native setup remain owned by Toolkit release maintainers | Existing pinned checkout/bootstrap/install, cache-identity and mandatory-outcome proof, source-bound notices, all four native packages, static import checks, repeatable bytes, checksums and clean extracted smoke. |
| Rust 1.98.1 | `Cargo.toml`, workflow `toolchain` selectors and exact compiler notice material | Manual coordinated compiler qualification. No `rust-toolchain` or `rust-toolchain.toml` exists, so the official rust-toolchain updater has no supported manifest here; do not add an empty/invented monitor or another selector just to satisfy it. |
| Specification, executable assets and product dependencies | Existing qualified specification pin/asset locks and Cargo manifest/lock graph | Existing exact-source, product/native, release and downstream adoption contracts; monitoring never regenerates or adopts them automatically. |

The native notice producer checks that the source manifest baseline matches the
actual vcpkg checkout. A bot baseline proposal may therefore correctly fail
until a maintainer reviews and aligns the coupled workflow pin. The manifest,
release workflow, native-cache tests and package/notice proof must all be reviewed;
no cache hit or updater result bypasses them. Actions can monitor action `uses`
references, not arbitrary `with.toolchain`/`VCPKG_COMMIT` values. Those raw pins
remain an explicit manual responsibility rather than false automatic coverage.

## Bounded local maintenance path

Use ordinary `git push`; there is no developer toggle or additional command.
The existing hook preserves branch-deletion-only handling. Its additional
maintenance path is available only for one canonical existing-branch update:
local branch/ref equals the wire ref and checked-out HEAD; both exact commit
objects exist; remote is a proven ancestor; and the checkout/index/untracked set
is clean, with no assume-unchanged, skip-worktree or fsmonitor-valid index entry.
The exact local `refs/remotes/origin/main` must be a known commit contained in the
candidate with one canonical merge base. Missing, divergent or ambiguous tracking
context keeps the full gate; a stale older Main broadens the checked range rather
than hiding earlier work. Both the wire range and the complete cumulative
Main-to-candidate range must modify only the existing regular
non-executable `.github/dependabot.yml` and/or this guide. It is never inferred
from the last commit, an ambient Docpact base or an author identity. Every
commit diff in the range is checked, including merge-parent diffs; a protected
edit or executable-mode change followed by a revert still takes the full gate.

An already-pushed but unmerged Cargo/runtime/native commit remains protected even
when the next wire delta changes configuration only; remote publication is not
a qualification receipt. Cleanliness reads disable fsmonitor shortcuts and read
index flags without changing the user's index. The hook still runs strict
Docpact on the exact wire range, then rechecks the candidate before returning. New branches (zero/unknown remote base), tags,
multiple/mixed updates, force/unknown history, missing/malformed input, dirty or
untracked files, renamed/deleted/linked/mode-changed allowlisted files, missing
classifiers, and every other path take the complete existing gate. In particular
all Cargo manifests/locks, Rust source, assets/contracts, packaging/vcpkg and
other native inputs, workflows/actions, hook/helper code and unknown paths keep
Rust-only audit, asset/public-rule locks, formatting, Clippy and workspace tests.
A Docpact failure still rejects the push. First publication of a new maintenance
branch remains a full-gate operation; only a later proven monitor-only range can
avoid repeating unrelated Rust work.

Changes to the gate itself are not maintenance-only. `test-pre-push.sh` exercises
the real helper/hook against disposable Git history, including multi-commit
runtime changes, exact Docpact argv, candidate drift, forbidden path families,
unknown/new/non-ancestor ranges, symlinks/modes/deletions and gate failures.
Existing native-cache/package tests and Rust 1.98.1 source/CI gates remain required.
No general feature check or CI platform is added.

## Measured cost and limits

Retained #246 exact-Rust 1.98.1 measurements (same unchanged product graph) total
299.45 seconds for the existing hook's Rust/audit stages: asset-lock 90.00,
Clippy 158.74, workspace tests 48.15, audit 1.20, formatting 0.85 and public rules 0.51.
These include their then-current compilation/cache state; they are not a fresh
warm-hook benchmark or a promise of equivalent savings. Source PR248 did not
trigger the native/Rust workflows for its configuration/docs-only paths; its
existing CodeQL Rust job ran 301 seconds and Actions 41 seconds. A skipped native
job is not a native qualification or timing sample. This change preserves those
CI boundaries/security checks and adds only the new helper path to the existing
Rust workflow's own path selection.

Current full-gate and real Docpact/maintenance-hook timing receipts are recorded
on the owning #247 delivery. Different cache/fixture states demonstrate selected
paths, not a controlled native-cache speedup. First new-branch pushes still take
the full path; this optimization avoids repeated Rust work only on proven later
maintenance updates.

The strict fast path is intentionally narrower than all documentation work.
Source/protocol/toolchain/package acceptance and any publication or production
operation stay separately authorized. Generated proposals remain unadopted
until reviewed through the owning task and current live merger policy.

References: [official vcpkg updater](https://github.com/dependabot/dependabot-core/blob/main/vcpkg/README.md),
[baseline parser](https://github.com/dependabot/dependabot-core/blob/main/vcpkg/lib/dependabot/vcpkg/file_parser.rb),
[baseline writer](https://github.com/dependabot/dependabot-core/blob/main/vcpkg/lib/dependabot/vcpkg/file_updater.rb),
[toolchain fetcher](https://github.com/dependabot/dependabot-core/blob/main/rust_toolchain/lib/dependabot/rust_toolchain/file_fetcher.rb),
[GitHub options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference).
