---
name: sync-upstream-main
description: Synchronize this sim-use fork with upstream/main through a guarded branch, worktree, rebase, verification, integration, and xd deployment workflow. Use when asked to catch up with upstream, repeat the fork rebase, validate the fork's iOS/tvOS simulator and physical-device support, merge and push main, or rebuild the exact fork-labelled binary. Android fork validation is excluded by default, and private device or signing identifiers must never enter git.
---

# Sync Upstream Main

Run this repository-specific workflow from the sim-use fork root. Keep a visible
`0/5` through `5/5` ledger and attach fresh evidence to every gate. A later
gate never repairs or excuses an earlier red gate.

## Fixed contract

- Branch from a clean, synchronized `main`, then rebase that branch onto the
  freshly fetched `upstream/main` in an isolated worktree.
- Accept Android from upstream as-is. Do not run the fork's Android build,
  bridge, emulator, or Android E2E unless the user explicitly changes scope.
  Shared Swift build and unit tests still compile and test cross-platform code.
- Preserve the fork's iOS/tvOS Simulator and physical-device behavior.
- Load physical-device and signing identifiers only at runtime from the
  gitignored local config or explicit environment variables.
- Run physical-device E2E only after simulator E2E is green and the user has
  approved that physical run. Integrate only after physical E2E is green.
- Keep the upstream semantic version. Use an exact fork display label such as
  `xd feat v0.12.0`; never bump upstream's version just for this fork.
- Treat maintaining or redeploying this skill as a separate task outside the
  five gates.

Read `AGENTS.md` before starting. If its build or test commands change, follow
the repository rather than stale commands in this skill and update this skill
after the five-gate run.

The default is a commit-by-commit rebase. If both sides rewrote the same
architecture so extensively that replaying obsolete intermediate commits would
make the audit less reliable, stop and obtain approval before changing
strategy. The accepted net-diff replant fallback, including its tree-preserving
ancestry bridge, is recorded in
[`ADR-0001`](../../../docs/adr/0001-net-diff-replant-for-divergent-upstream-sync.md).

## Gate 0: Freeze scope and create recovery

1. Record the repo root, current `main`, `origin/main`, and `upstream/main`.
2. Require a clean main worktree. Do not stash, discard, reset, or overwrite
   user changes.
3. Fetch both remotes without force:

   ```bash
   git fetch --prune origin main
   git fetch --prune upstream main
   ```

4. Require local `main` to equal `origin/main`. Stop on divergence.
5. Record:
   - old main SHA;
   - old merge-base with `upstream/main`;
   - fetched upstream SHA;
   - a unique run timestamp and evidence directory under `.build/e2e-sync/`.
6. Create a uniquely named recovery branch at old main.
7. Create a uniquely named `sync/upstream-main-*` branch from main in a sibling
   worktree. Open that exact worktree in Fork when Fork is available:

   ```bash
   open -a Fork -- /absolute/path/to/the/worktree
   ```

Keep the recovery branch until remote verification and installed-binary smoke
are both green. Never reuse a prior run's worktree or evidence as proof.

## Gate 1/5: Rebase and audit history

In the sync worktree:

```bash
git rebase upstream/main
```

Resolve conflicts path by path:

- For Android-owned paths, restore the exact `upstream/main` behavior unless a
  shared API contract requires an integration edit.
- For shared or Apple-owned paths, combine upstream behavior with the fork's
  iOS/tvOS Simulator and device capabilities. Never blanket-checkout a side.
- Never introduce developer, device, team, bundle, or signing values.
- Abort with `git rebase --abort` if the intended resolution is uncertain.

After rebase, require all of the following:

```bash
git status --short
git merge-base --is-ancestor upstream/main HEAD
git diff --check upstream/main...HEAD
git range-diff OLD_MERGE_BASE..OLD_MAIN upstream/main..HEAD
```

Review the range-diff rather than accepting a zero exit code alone. Account for
every dropped, rewritten, split, or newly added fork patch. Inspect the final
diff and history specifically for retained iOS/tvOS and physical-device work.
Mark `1/5` only when the rebase is complete, the worktree is clean, and the
history audit is explained.

## Gate 2/5: Build and unit tests

Run fresh:

```bash
make build
make test
```

Both must exit zero. A condensed test report is acceptable only when its final
suite summary is green; retain the raw failure log for any red run.

If compatibility code or tests must be added, use the Matt development flow:

- Claude Code: `/implement`, then `/code-review`.
- Codex: `$implement`, then `$code-review`.
- Drive each behavior red → green → refactor and review against both repository
  standards and this sync contract.
- Override the normal Matt-flow commit point: do not commit the repair until
  gate 4 is green, because gate 5 must commit the exact hardware-tested tree.
- For each red-green slice, sample mutation with a true 50% draw
  (`RANDOM % 2`). On a selected slice, have a fresh-context reviewer introduce
  one semantic mutant in changed production behavior, prove the relevant test
  turns red, restore the source exactly, and prove green again.
- If every slice misses the draw, force one mutation check on the final slice
  so a repair set cannot finish with zero assertion-strength checks.
- Do not optimize a mutation score. Record killed, survived, or equivalent and
  strengthen only behavior-worthy assertions.

Keep post-rebase compatibility edits uncommitted through gates 2–4 so the exact
tree that passes physical E2E is what gate 5 commits. Re-run both commands after
the final edit. Mark `2/5` only when both are green.

## Gate 3/5: iOS and tvOS Simulator E2E

Run only the fork-owned Apple simulator lanes:

```bash
make e2e-ios
make e2e-tvos
```

Read each runner's final pass/fail map. Do not mistake an early green suite for
a green runner, and do not accept a skipped required case.

When isolating the iOS typing suite, use the qualified filter
`SimUseTests.TypeTests/`. Do not use broad `--filter TypeTests`: it also selects
`AndroidTypeTests`, which is outside this fork gate and can produce a misleading
result.

Save summaries, screenshots, and environment-neutral evidence beneath the run's
`.build/e2e-sync/` directory. If a simulator is closed or replaced mid-gate,
boot and settle a task-owned replacement and rerun the affected gate. Mark
`3/5` only when both complete runners are green.

## Gate 4/5: Approved physical-device E2E

Stop before touching hardware unless the user has explicitly approved this
run's iOS/tvOS physical verification. A prior run's approval is not reusable.
Confirm the selected devices are connected and unlocked without copying their
names or identifiers into tracked files or the final report.

Use `.sim-use-e2e.local.env.example` as the schema. Values belong in the ignored
`.sim-use-e2e.local.env`, a path supplied through `SIM_USE_E2E_CONFIG_FILE`, or
non-empty runtime environment variables. Before loading a repo-local file,
verify it is ignored and untracked:

```bash
git check-ignore -q .sim-use-e2e.local.env
! git ls-files --error-unmatch .sim-use-e2e.local.env
```

Do not print the file. Keep detailed logs under `.build/` and redact private
values from status updates.

Run the strict gates against the already-built tree:

```bash
make e2e-ios-device ARGS="--no-build"
make e2e-tvos-device ARGS="--no-build"
```

Both must exit zero with no skipped required case. If either device is missing,
locked, unreachable, or cannot be signed, leave the run at `3/5`; do not
integrate. Mark `4/5` only when both strict summaries are green.

## Gate 5/5: Commit, integrate, push, build, install, and smoke

First ensure the tree is exactly the `4/5` tree:

1. Review every diff and run a privacy scan.
2. Commit any post-rebase compatibility edits with a conventional message and
   DCO sign-off:

   ```bash
   git commit -s
   ```

   Do not create an empty commit merely to satisfy this step. Rebased commits
   already are commits; only new edits need a new one.
3. Reconfirm gates 1–4 map to the exact branch HEAD.
4. Fetch `origin/main` again. Require it still equals the old main SHA.
5. In the original main worktree, fast-forward only:

   ```bash
   git merge --ff-only SYNC_BRANCH
   git push origin main
   git fetch origin main
   ```

6. Require local `main`, `origin/main`, and the pushed remote SHA to match.
   Never force-push main.

### Tag the fork source commit

Derive the semantic version from the latest `v*` release tag reachable from
`upstream/main`; do not edit version files. Use:

- display label and annotated tag message: `xd feat vX.Y.Z`;
- valid Git ref: `xd-feat-vX.Y.Z`.

Git refs cannot contain spaces. Create an annotated tag on the just-pushed
binary source commit, then push that exact tag. If the ref already exists,
verify its peeled commit and message; never move or force it.

### Build and install the exact xd binary

Use xd's guarded installer and pass the display label at build time:

```bash
SIM_USE_VERSION="xd feat vX.Y.Z" \
  bash ~/.agents/skills/xd/scripts/install-sim-use-xd.sh \
  /absolute/path/to/the/main-checkout
```

The installer must build from clean `main == origin/main`, ad-hoc sign the
universal executable, refuse real-file overwrites, and point both canonical
`sim-use` and compatibility `sim-use-xd` at the same fork binary. Verify:

```bash
sim-use --version
sim-use-xd --version
file build_products/sim-use
codesign --verify --deep --strict build_products/sim-use
shasum -a 256 build_products/sim-use
```

Require both commands to report the exact display label and both resolved paths
to equal the main checkout's `build_products/sim-use`.

### Run installed-binary simulator smoke

Use the installed command, not a `.build/debug` path. On fresh task-owned iOS
and tvOS simulators, perform observe → one state-changing action → fresh
observe → screenshot. For tvOS, use focus navigation rather than coordinates.
Prove screenshots are non-empty and the observed state changed as expected.

Stop only daemons, Appium processes, and simulators started by this run. Do not
kill shared servers or shut down devices owned by another task. Mark `5/5` only
after installed-binary smoke and cleanup are green.

## Completion report

Report:

- the five gate verdicts and evidence paths;
- old main, fetched upstream, integrated main, remote main, and peeled tag
  commits;
- commit sign-off and fast-forward/push verification;
- binary label, architectures, signature result, SHA-256, and resolved alias
  equality;
- simulator smoke outcomes;
- recovery branch/worktree disposition;
- any unverified item explicitly as pending.

Do not include physical-device names, identifiers, team IDs, private bundle
IDs, or signing values.

## Recovery rules

- Rebase in progress: use `git rebase --abort`.
- Main moved after physical E2E: stop. Reconcile on the sync branch and rerun
  every invalidated gate; do not merge or push stale evidence.
- Push rejected: fetch and diagnose. Never force.
- Tag mismatch: stop and report the existing peeled commit/message. Never
  retarget the tag.
- Failed build or smoke after push: keep the pushed commit and recovery ref,
  fix on a new branch, and rerun affected gates. Do not rewrite public main.
- Remove a worktree only after confirming it is task-owned and clean. Prefer
  keeping the recovery ref until all remote and binary checks pass.
