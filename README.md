# opencode-perf-demo

Minimal reproduction for opencode VCS / Snapshot / fff performance issues on large repositories.

## Quick Start

```bash
git clone https://github.com/cpkt9762/opencode-perf-demo
cd opencode-perf-demo
bash create-demo.sh medium   # generates 200k files (~1.5GB, ~2 min)
opencode                     # observe CPU in Activity Monitor / htop
```

Scales: `small` (50k files), `medium` (200k), `large` (500k).

## What It Creates

| Item | Count | Purpose |
|------|-------|---------|
| Tracked files | 50k–500k | Stress `git status` / `git add --all` |
| Modified files | 500 | Force `Vcs.status` to diff each |
| Large files (1MB) | 5 | Trigger `Snapshot.diff` OOM path |
| Untracked files | 1000 | Additional `git status` pressure |
| Nested git repo | 1 | Orphan submodule |
| Broken `.git/HEAD` | 1 | Triggers `fatal: bad object HEAD` |

## Issues Reproduced

### 1. fff `refresh_git_status` — CPU 100-200%+ on 500k file repos

**Root cause:** `fff-core/src/git.rs` `default_status_options()` uses `include_unmodified(true)`, forcing libgit2 to `lstat()` every tracked file. Combined with no single-flight guard (`shared.rs`), the background watcher can spawn 8 parallel rayon threads all doing full git status simultaneously.

**Reproduce:**
```bash
bash create-demo.sh large    # 500k files
opencode serve --port 19876 &
sleep 15
# trigger watcher:
for f in src/mod-000{0..9}/f-0{0..9}.ts; do echo "// poke" >> "$f"; done
sleep 5
ps aux | grep opencode       # observe %CPU
sample $(pgrep -f "opencode serve") 3   # see fff-bg-* threads in refresh_git_status
```

**Related fff issues:** [fff#151](https://github.com/dmtrKovalenko/fff/issues/151), [fff#294](https://github.com/dmtrKovalenko/fff/issues/294), [fff#616](https://github.com/dmtrKovalenko/fff/issues/616)

### 2. `Vcs.status` — repeated `git` subprocess spawning

**File:** `packages/opencode/src/project/vcs.ts` lines 348-371

The filesystem watcher triggers `Vcs.status()` on file changes. Each call spawns `git status --porcelain` + `git diff --numstat HEAD` as child processes. On large repos with many dirty files, this is O(seconds) per call with no throttle.

### 3. `Snapshot.track` — `git add --all` blocks TUI

**File:** `packages/opencode/src/snapshot/index.ts` lines 149, 779

Every LLM message turn calls `Snapshot.track()` which runs:
```
git add --all --sparse --pathspec-from-file=- --pathspec-file-nul
git write-tree
```
On large repos this blocks the TUI for seconds to minutes.

**Reproduce:** Start opencode in the demo repo and send any message. The TUI freezes between the model response and the next prompt while `git add --all` runs.

**Related:** [#32981](https://github.com/anomalyco/opencode/issues/32981), [#28952](https://github.com/anomalyco/opencode/issues/28952)

### 4. `Snapshot.diff` — full-context patch OOM

**File:** `packages/opencode/src/snapshot/index.ts` line 737

```ts
formatPatch(structuredPatch(file, file, before, after, "", "",
  { context: Number.MAX_SAFE_INTEGER }))
```

Materializes entire file content as a unified diff with infinite context lines. For the 5 large files (20k lines each), this creates ~5MB patch strings per file.

**Related:** [#29873](https://github.com/anomalyco/opencode/issues/29873)

### 5. Broken submodule — cascading git fatals

Without `-c submodule.recurse=false` in the git config array, `git status` / `git diff` descend into `vendor/broken/` and hit `fatal: bad object HEAD`.

## Proposed Fixes

### For fff (upstream: dmtrKovalenko/fff)

1. **Remove `include_unmodified(true)` from `default_status_options()`** — use dirty-only enumeration for watcher-triggered refreshes. Clear in-memory statuses before applying results.
2. **Add single-flight guard to `refresh_git_status()`** — `AtomicBool` CAS prevents concurrent refresh calls; pending requests coalesce.
3. **Increase debounce for expensive operations** — 50ms is too aggressive for `git status` on large repos.

Reference implementation: https://github.com/cpkt9762/fff/commit/30dc334

### For opencode

1. **Throttle `Vcs.status` calls** — debounce or coalesce watcher-triggered status updates.
2. **Make `Snapshot.track` async** — don't block the TUI event loop on `git add --all`.
3. **Cap `Snapshot.diff` context** — use a reasonable context value (e.g., 3-5 lines) instead of `MAX_SAFE_INTEGER`.
4. **Add `-c submodule.recurse=false`** to the git config array in `packages/opencode/src/git/index.ts`.

## Environment

- opencode 1.17.13 (official release)
- macOS 26.2, Apple Silicon (M4 Pro)
- Tested with both `opencode` TUI and `opencode serve`
