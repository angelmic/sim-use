# ADR-0001: Net-diff replant for a deeply divergent upstream sync

**Date**: 2026-09-01
**Status**: accepted
**Deciders**: Rich Liu and the sync operator
**Recorded after the decision**: yes

## Context

The xd fork had diverged substantially from `upstream/main`: the old fork and
the v0.14.0 replant each had dozens of unique commits, while both sides had
independently changed device discovery, physical Apple-device support, command
routing, tests, and documentation. Replaying every historical fork commit
would repeatedly resolve obsolete intermediate conflicts instead of reviewing
the fork behavior that must survive today. The synchronization also had strict
constraints: Android stays upstream-owned, private device/signing values never
enter git, physical-device behavior must be tested, and public `main` must not
be force-pushed.

## Decision

When a normal commit-by-commit rebase becomes dominated by obsolete conflict
history, we may use a guarded **net-diff replant**. We create a branch and
worktree from freshly fetched `upstream/main`, squash the old fork's final tree
onto it, reconcile conflicts by module ownership, and validate the result
through the same five gates as a normal sync.

Because this branch does not descend from the old fork `main`, we add a
tree-preserving `ours` merge commit whose second parent is the unchanged old
`origin/main`. This ancestry bridge makes final integration a normal
fast-forward and avoids a force push. The bridge is created only after the
replant tree passes all tests and the old remote SHA is reverified.

This is a fallback strategy, not the default. The repository-owned
`sync-upstream-main` skill remains primary; use this ADR only when the history
audit shows that per-commit replay would obscure the intended fork behavior.

## Alternatives Considered

### Alternative 1: Rebase every fork commit onto upstream

- **Pros**: Preserves a linear, reviewable patch series and needs no ancestry bridge.
- **Cons**: Repeats conflicts in superseded intermediate implementations.
- **Why not**: The useful review unit was the current fork net behavior;
  replaying old mechanics would have made the conflict audit less reliable.

### Alternative 2: Merge upstream into the old fork main

- **Pros**: Preserves both histories with an ordinary merge commit.
- **Cons**: Keeps the fork's old baseline as first-parent architecture and
  makes upstream-owned modules harder to audit.
- **Why not**: The desired result was an upstream v0.14.0 baseline with an
  explicit xd feature layer.

### Alternative 3: Replace main with the replant using force push

- **Pros**: Produces the simplest first-parent history.
- **Cons**: Rewrites public history and can discard concurrent work.
- **Why not**: The synchronization contract prohibits force-pushing `main`;
  a tree-preserving ancestry bridge enables a normal fast-forward.

## Reusable Procedure

### 0. Freeze coordinates and authority

1. Read `AGENTS.md` and `.agents/skills/sync-upstream-main/SKILL.md`.
2. Require clean local `main == origin/main` and freshly fetch both remotes.
3. Record `OLD_MAIN`, `UPSTREAM_MAIN`, and their merge base under a unique
   `.build/e2e-sync/<timestamp>/` evidence directory.
4. Create `recovery/main-pre-replant-<timestamp>` at `OLD_MAIN`; retain it
   until remote, binary, simulator, and physical-device verification are green.
5. Create a sibling worktree and `sync/upstream-main-replant-<timestamp>` from
   `upstream/main`.
6. Ask before hardware use, integration/push, tagging, installation, or any
   other externally visible or destructive step.

### 1. Replant the net diff

Assign concrete values before using commands; do not paste angle-bracket
placeholders into a shell because zsh interprets them as redirections:

```bash
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RECOVERY_BRANCH="recovery/main-pre-replant-$RUN_ID"
SYNC_BRANCH="sync/upstream-main-replant-$RUN_ID"
MAIN_CHECKOUT=/absolute/path/to/sim-use-xd
git merge --squash "$RECOVERY_BRANCH"
```

Resolve each conflict rather than checking out an entire side:

- Android-owned paths (`bridge/`, `Sources/AndroidBackend/`) remain byte-for-
  byte upstream unless a shared compile contract requires a documented edit.
- Upstream's `iOSDeviceBackend` accessibility-audit channel and xd's
  Appium/WDA full-interaction backend coexist; neither replaces the other.
- Stored domain facts have one source of truth; compatibility fields derive
  from it instead of duplicating state.
- Shared command surfaces account for every target explicitly.
- Device IDs, team IDs, private bundle IDs, private/custom endpoint values, and
  signing values remain in ignored runtime configuration and never enter
  tracked files or reports. Public repository defaults may remain documented.

Audit ownership with path-scoped diffs against `upstream/main`, not only by
reading conflict resolutions.

### 2. Run the complete gate ledger against one exact tree

- **Gate 0 — guardrails and recovery**: record coordinates, clean worktrees,
  recovery ref, privacy boundaries, and evidence directory.
- **Gate 1/5 — replant and audit**: account for every conflict and
  upstream-owned path; require `git diff --check` to be clean.
- **Gate 2/5 — build and unit tests**: run `make build` and `make test` after
  the final source edit. Important assertions receive fresh-context mutation
  review.
- **Gate 3/5 — Simulator E2E**: iOS and tvOS runners are green; isolate and
  rerun a flaky suite without relabelling the original red result.
- **Gate 4/5 — approved physical E2E**: test the exact uncommitted tree. With
  one shared USB cable, finish Apple TV first, then connect and unlock the
  iPhone. A network-only iPhone needs an Appium RemoteXPC registry; direct USB
  permits Appium's legacy device fallback.
- **Gate 5/5 — delivery**: review and scan the complete staged tree, commit the
  tested replant, bridge ancestry without changing its tree, fast-forward and
  push, tag, install the release binary, synchronize downstream skills, and
  verify the installed binary through `$xd`.

Read final runner summaries, not individual green lines. Required device gates
may not skip. Preserve logs and screenshots under `.build/` without printing
private configuration.

### 3. Review and commit the tested replant

```bash
git status --short
git add -A
git diff --cached --check
git diff --cached | gitleaks stdin --no-banner --redact
git diff --cached
git commit -s -m "feat: replant xd device support onto upstream vX.Y.Z"
```

Review documentation, command help, changelog order, production type safety,
path ownership, and every staged file—including files that were untracked
before `git add`. Do not edit source after physical E2E without reopening the
affected gates.

### 4. Bridge ancestry without changing the tree

Fetch `origin` and require `origin/main == OLD_MAIN`. A replant normally cannot
fast-forward the old fork because neither tip is the other's ancestor.

```bash
TREE_BEFORE=$(git rev-parse HEAD^{tree})
git merge -s ours --no-ff --signoff origin/main \
  -m "chore: preserve pre-replant main ancestry"
TREE_AFTER=$(git rev-parse HEAD^{tree})
test "$TREE_BEFORE" = "$TREE_AFTER"
git merge-base --is-ancestor origin/main HEAD
```

The tree hashes must match. The merge commit has the replant first parent and
old `main` second parent.

### 5. Integrate, tag, install, and synchronize downstream

Recheck the remote lease immediately before integration, then fast-forward:

```bash
# Reuse the exact MAIN_CHECKOUT and SYNC_BRANCH recorded at Gate 0.
test -n "$MAIN_CHECKOUT"
test -n "$SYNC_BRANCH"
git -C "$MAIN_CHECKOUT" merge --ff-only "$SYNC_BRANCH"
git -C "$MAIN_CHECKOUT" push origin main
```

Verify local main, `origin/main`, and `git ls-remote` agree. Create the annotated
`xd-feat-vX.Y.Z` tag on the bridge commit without moving an existing tag. Build
and install the exact release binary with the guarded xd installer; verify its
version, signature, SHA-256, architectures, and alias realpaths. Then run
`$xd-sync-sim-use` so runtime sim-use documentation and xd's driver contract
follow the new binary.

Finally, exercise the installed binary through the deployed `$xd` workflow in
this order: iOS Simulator, physical iPhone, tvOS Simulator, physical Apple TV.
Keep the recovery branch until these checks pass.

## Failure Lessons from the v0.14.0 Replant

- `git diff --check` caught a staged conflict marker that build/test did not.
- Bash nested quoting made `awk` return an empty elapsed value. Validate timing
  measurements as numeric before comparing them so errors cannot pass as zero.
- A physical target can parse successfully while using simulator capabilities.
  Controller-routing tests and a fresh post-action hierarchy must prove the
  actual device path.
- Shell runners that pipe build output need `pipefail` or a formatter can hide
  a failed producer.
- CoreDevice `tunnelState: connected` does not mean Appium can list a
  network-only iPhone; Appium needs its RemoteXPC registry or direct USB.
- Strategy C does not naturally permit `--ff-only`. Inspect ancestry and use
  the verified tree-preserving bridge, never a surprise force push.

## Consequences

### Positive

- Upstream becomes the obvious baseline and upstream-owned modules are easy to audit.
- Review focuses on current fork behavior rather than obsolete intermediate commits.
- Public history is preserved and integration remains a normal fast-forward.
- The exact physical-device-tested tree becomes the release source.

### Negative

- Individual historical fork commits are represented by one replant commit.
- The ancestry bridge needs explanation for future history readers.
- A rigorous ownership ledger replaces `range-diff` for the squashed patch.

### Risks

- **Silent feature loss**: mitigate with ownership audits, bidirectional docs
  review, simulator/physical E2E, and mutation checks.
- **Private leakage**: keep configuration ignored and untracked, never print
  it, and scan the complete diff.
- **Concurrent main update**: compare the exact old SHA before bridge and push.
- **Evidence invalidation**: source edits after hardware testing reopen gates.

## Reference Instance

- Old fork main: `3d5826be1453a93272fb6948f82eca7f6b41837f`
- Upstream v0.14.0: `3a2f6486240206d77fce4cfd129b494609f3d0a9`
- Replant commit: `7d3a139818a3fe9a1ecafe61c6368cda3cb172b1`
- Tree-preserving bridge: `f7684edbc01d2a0f30f0d61cb33f736f2416ccf9`
- Annotated tag: `xd-feat-v0.14.0`

The final tree passed fresh build/unit gates, iOS and tvOS Simulator gates, and
strict physical iOS and tvOS gates. Detailed logs and screenshots remain under
task-owned `.build/` evidence directories rather than in git.
