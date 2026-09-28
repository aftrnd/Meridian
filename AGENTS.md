# Meridian — Agent Foundation

The single source of agent rules for this repo, shared by every assistant (Claude Code, Qwen, Cursor, Copilot).
`CLAUDE.md` and `QWEN.md` just import this file. **Edit rules here, not in the shims.**

Meridian is a native Swift 6 / SwiftUI macOS app that plays Steam (Windows) games on Mac through a Wine/CrossOver engine.
Architecture map and code conventions: [.github/copilot-instructions.md](.github/copilot-instructions.md).
Branching, commits, versioning, releases: [CONTRIBUTING.md](CONTRIBUTING.md).

## Where the detailed rules live

`.cursor/rules/*.mdc` holds the deep, subsystem-specific rules. Cursor loads them automatically. Other agents should
**read the matching rule before working in that area**. Don't load them all up front: `engine-research-findings.mdc` alone is ~190 KB.

| Working on… | Read first |
|---|---|
| Any code change | `development-standards.mdc`, `no-piling-on.mdc`, `fail-fast.mdc` |
| Boot / bootstrap / prefix failures | `bootstrap-diagnosis.mdc`, `logging-system.mdc` |
| A game crashing or failing to launch | `game-debugging.mdc`, then search `engine-research-findings.mdc` |
| GPU / rendering / frame capture | `gpu-debugging.mdc`, `engine-research-findings.mdc` |
| Tests | `testing-standards.mdc` |
| Builds, version bumps, releases | [Builds, versions & releases](#builds-versions--releases), `versioning.mdc` |
| Ending a session | `knowledge-preservation.mdc` |

## Hard rules (non-negotiable)

1. **Never build, run, or install the app.** No `xcodebuild`, `swift build`, `swift run`, `open *.app`, and no copying builds into `/Applications`. Run `swift test` only when the user asks. The user builds in Xcode. See `xcode-build-only.mdc` and [Builds, versions & releases](#builds-versions--releases).
2. **Never guess Wine, Steam, or macOS behavior.** Base every claim on docs, source, CLI output, or `meridian.log`. If you can't find evidence, say so.
3. **Fix root causes, don't pile on.** Before adding a workaround, ask whether the layer underneath is wrong. Deleting code is often the right fix.
4. **The UI is pixel-perfect.** Refactors and performance work must not change visible appearance.
5. **No SPM dependencies.** Never block the main actor.
6. **No force-pushing `main`.** Never delete remote branches, rewrite pushed history, or tag a release without the user's explicit OK.

## Two assistants: Qwen first, Claude for the hard parts

Nick runs **Qwen locally (served by oMLX)** as the default assistant and brings in **Claude Code** for complex work.
The two can't talk directly. They coordinate through one file: **`Scripts/HANDOFF-ACTIVE.md`** (gitignored and local, like the other `HANDOFF-*.md` files).

**At the start of every session:** if `Scripts/HANDOFF-ACTIVE.md` exists and is addressed to you, read it before doing anything else.

### When Qwen should escalate to Claude

Stop and write a handoff, instead of trying again, when **any** of these is true:
- You've made **two attempts** and still can't state the root cause with evidence (log lines, CLI output).
- The work touches **Wine, Steam auth or bootstrap, the engine, or the graphics stack** (DXMT/DXVK/GPTK/MoltenVK) beyond a one-line, well-understood change.
- The change spans **more than ~3 files**, alters concurrency or actor isolation, or restructures a subsystem.
- Your self-review says "not the cleanest way", but you can't see how to get there.
- It's a release, a history rewrite, or anything in the hard rules you're unsure about.

Escalating early is correct. Two failed patches cost more than a handoff.

### When Claude should hand back to Qwen

Once the hard part is solved, the remaining work is mechanical (applying the pattern elsewhere, tests, docs, wrap-up), and Claude has written it down.

### Handoff format

Overwrite `Scripts/HANDOFF-ACTIVE.md` with:

```markdown
# Handoff: <topic>
From: <Qwen|Claude> → To: <Claude|Qwen>   Date: YYYY-MM-DD   Branch: <branch>

## Goal
<one or two sentences: what "done" looks like>

## State
<what's changed so far: commits, uncommitted files, what's verified vs. untested>

## Evidence
<exact commands run, their output, relevant meridian.log lines. Facts, not guesses.>

## Tried and ruled out
<each dead end, and why it failed>

## Blocked on / the ask
<the specific question or task for the receiver>
```

**On receiving:** read it, do the work, then either write a return handoff to the other assistant or, if the work is finished,
move the file to `Scripts/archive/HANDOFF-YYYY-MM-DD-<topic>.md` and save the findings where `knowledge-preservation.mdc` says they belong.

## Builds, versions & releases

Meridian has exactly **two** kinds of build. Anything else is wrong.

| Build | How | Signed with | Where it runs |
|---|---|---|---|
| **Dev build** | The user presses Run in Xcode (Debug) | Apple Development (local) | From Xcode's DerivedData. Never copied anywhere. |
| **Release** | `bash Scripts/release-app.sh --patch\|--minor --tag-only` → GitHub Actions | Developer ID, notarized and stapled | The DMG from GitHub Releases, or the in-app update |

When the user asks for a "release", a "release build", or "put it in Applications":
- **Want to ship it?** Run the wrap-up protocol first (everything merged and verified on `main`), propose the version level (`--patch` or `--minor`, with the reason), and run `release-app.sh --tag-only` after they confirm. CI does the build. This Mac has no Developer ID certificate, so a proper release **cannot** be built locally.
- **Want to test Release-config performance?** In Xcode: Product → Scheme → Edit Scheme → Run → Build Configuration → Release. It still runs from Xcode.
- **Never** hand-build with `xcodebuild` and copy it to `/Applications`. Such a build:
  - shows the last release's version while containing unreleased commits, so the update checker thinks it's current
  - is Gatekeeper-rejected because it's signed "Apple Development" and not notarized
  - shares its bundle ID, Wine prefix, and preferences with the dev build, so two copies fight over one wineserver

**Versions:** never edit `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` by hand. `release-app.sh` owns them. The format is 3-part `0.MINOR.PATCH`, and the tag is `v{MARKETING_VERSION}`. Engine releases are a separate line (`vX.Y.Z-engine`, via `release-engine.sh`). Details: `versioning.mdc`.

## Self-review before saying "done"

Before you report any change as finished, answer these questions honestly and fix what fails. Then give a one-line verdict in your reply.

- **Is this the cleanest way?** Would a senior engineer reviewing this diff suggest something simpler, such as reusing an existing helper or deleting code instead of adding it?
- **Root cause or symptom?** If the fix counteracts something the code does elsewhere, that other code is probably the real bug.
- **Did I follow the codebase's idiom?** Check naming, `@Observable`/`@MainActor` patterns, `MeridianLog`, `// MARK: -` sections and comment density.
- **What could this break?** Name the regression risk. Contract tests in `MeridianTests/` grep source text, so if you renamed anything, check them.
- **Is the evidence real?** Anything you call "verified" must have command output or log lines behind it. Otherwise call it "untested — build in Xcode to confirm".
- **Is the knowledge saved?** Record root causes and dead ends where `knowledge-preservation.mdc` says they belong.

If the honest answer to "cleanest way?" is no, say so and propose the better approach before continuing. Don't silently ship the worse one.

## "Wrap up and push" protocol

When the user says *wrap up*, *push*, *ship it*, *let's commit*, or anything similar, **always run this procedure**. Don't just `git push`.

### 1. Inventory

```bash
git status --short
git branch --show-current
git fetch origin && git log --oneline origin/main..HEAD   # unpushed commits
git log --oneline $(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-engine')..origin/main  # changes since the last release
```

### 2. Decide where the work belongs

| Situation | Action |
|---|---|
| On `main`, change is **trivial**: docs, comments, `.gitignore`, a single-file chore, no behavior change | Commit directly to `main` and push. |
| On `main`, change is **anything else**: touches Swift behavior, spans several commits, is unverified, experimental, or a probe | **Cut a branch first**: `git switch -c <type>/<topic>` (uncommitted changes carry over). Then follow the branch rows below. |
| On `main` with **unpushed** commits that should have been a branch | Stop and propose moving them (`git branch <type>/<topic>` then reset `main` to `origin/main`). **Ask before resetting.** |
| On a `<type>/<topic>` branch, work **complete and user-verified** (built and ran in Xcode) | Commit, `git switch main && git pull --ff-only && git merge --no-ff <branch>`, push `main`, delete the branch locally and on origin (ask first for origin). |
| On a branch, work **incomplete or unverified** | Commit (mark WIP in the `STABLE:` line) and push **the branch only**: `git push -u origin <branch>`. Don't merge. |
| **Unrelated changes mixed together** | Split them into separate commits, and separate branches when they're non-trivial. One topic per branch. |
| On a stale or unexpected branch (`v0.9.x`, `agents/*`, `backup/*`) | Don't commit there. Cut a proper branch from `main` and flag the stale one. |

Branch names use `<type>/<short-kebab-topic>`, where `<type>` is `feat`, `fix`, `perf`, `refactor`, `docs`, `chore` or `test`, matching the commit prefix.
Example: `fix/steam-auth-retry`. **Never name a branch like a version.** Versions are tags.

If you don't know whether the user has verified the change in Xcode, **ask**. Don't assume it works.

### 3. Commit

Conventional commits (`type(scope): summary`), with a body that explains what was broken, the root-cause chain, and the fix.
Merge commits into `main` and direct-to-`main` commits must end with a `STABLE:` line (see `commit-safety.mdc`).

### 4. Release check

If `main` now has user-facing changes since the last `vX.Y.Z` tag, **suggest** a release:
use `--patch` for fixes and perf, `--minor` for features, then run `bash Scripts/release-app.sh --<level> --tag-only`.
Never tag without the user's go-ahead.

### 5. Report

End with a short summary: the branch decision and why, the commits made, what was pushed and where, whether it was merged, any leftover branches, and whether a release is suggested.
If work is being passed to the other assistant, write `Scripts/HANDOFF-ACTIVE.md` before pushing.
