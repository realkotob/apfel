# Routine #4 - Distribution-channel sync watch

**Triggers:** Scheduled, Mondays 09:00 UTC.
**Runs on:** Anthropic cloud (Linux, no Apple Intelligence).
**Status:** Phase 3 - live.

When pasting this prompt into claude.ai, prepend `_golden-goal.md` verbatim, then append everything below the dividing line.

---

(paste `_golden-goal.md` above this line)

---

## Your job

Check whether apfel's three distribution channels are in sync. If any channel is lagging by more than 48 hours, open a GitHub issue on `Arthur-Ficial/apfel` with the information Franz needs to fix it in one command. You do not fix anything yourself.

### The three channels you check

| Channel | Source of truth |
|---|---|
| **GitHub Releases** (the upstream that the other two feed from) | `gh release view --repo Arthur-Ficial/apfel` latest tag, published-at |
| **homebrew-core** (`brew install apfel`) | `curl -s https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/a/apfel.rb` - look for the `version` / `url` fields |
| **nixpkgs** (`nix profile install nixpkgs#apfel-llm`) | `curl -s https://raw.githubusercontent.com/NixOS/nixpkgs/master/pkgs/by-name/ap/apfel-llm/package.nix` - look for the `version` field |

### Step-by-step

1. **Read `CLAUDE.md`** and `docs/release.md` to stay current on the distribution story.

2. **Fetch the canonical version** from the latest GitHub Release:
   ```bash
   gh release view --repo Arthur-Ficial/apfel --json tagName,publishedAt
   ```

3. **Fetch the homebrew-core formula** and parse its version:
   ```bash
   curl -sf https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/a/apfel.rb | grep -E 'version|url'
   ```

4. **Fetch the nixpkgs package** and parse its version:
   ```bash
   curl -sf https://raw.githubusercontent.com/NixOS/nixpkgs/master/pkgs/by-name/ap/apfel-llm/package.nix | grep -E 'version|hash'
   ```

5. **Compute lag.** For each channel that is behind the latest GitHub Release:
   - Time since the GitHub Release was published (use `publishedAt`)
   - Current version in that channel vs. canonical

   A channel is "lagging" if it is at a version older than the canonical AND the canonical release is more than 48 hours old.

6. **If no lag, do nothing.** The routine budget is precious. Log nothing, open nothing, comment nothing. Exit clean.

7. **If there is lag on one or both channels**, open ONE issue (not two) summarizing the state and suggesting commands. Template below.

### Issue template

Title format: `dist-sync: <channel> behind v<canonical> by <N>h`

Body (short, Arthur voice):

```
Routine check this morning - looks like <channel(s)> are trailing the latest release.

## State

| Channel | Current | Expected | Lag |
|---|---|---|---|
| GitHub Releases | v<canonical> | - | - |
| homebrew-core | v<hb-current> | v<canonical> | ~<N>h |
| nixpkgs `apfel-llm` | <nix-current> | <canonical> | ~<N>h |

## Fixing it (for you, not me)

**Homebrew-core:** normally autobumps within ~24h. If it is stuck, manually:

\```bash
brew bump-formula-pr apfel \
  --url=https://github.com/Arthur-Ficial/apfel/releases/download/v<canonical>/apfel-<canonical>-arm64-macos.tar.gz \
  --sha256=<sha256>
\```

(SHA256 from the release asset: `<computed-sha256>`)

**nixpkgs:** `r-ryantm` picks up new versions weekly via the package's `passthru.updateScript`. If it has not fired and we are >7 days behind, anyone with a nixpkgs checkout can manually open a bump PR (see [docs/nixpkgs.md](../../docs/nixpkgs.md) - "Manual self-bump"). We do not maintain our own release-triggered workflow.

## What I did NOT do

No bump PRs, no pushes, no formula edits. Routines never touch distribution channels - that's yours.

Cheers, Arthur
cc @franzenzenhofer
```

### De-duplication

Before opening a new issue, check for an existing open dist-sync issue:

```bash
gh issue list --repo Arthur-Ficial/apfel --state open --search "dist-sync" --json number,title
```

If one already exists for the same canonical version, **update** it with a comment rather than opening a duplicate:

```
Still not in sync as of <today>. Same state as the issue body, channels still at <hb-current> / <nix-current>. No action taken on my end.

Cheers, Arthur
```

### Hard limits - repeat

- Never run `brew bump-formula-pr`, never push to `Arthur-Ficial/homebrew-tap`.
- Never run a manual nixpkgs bump from the routine - only point Franz at [docs/nixpkgs.md](../../docs/nixpkgs.md) "Manual self-bump" if a bump is genuinely needed.
- Never create PRs against homebrew-core or nixpkgs from this routine.
- Never edit the formula or package.nix.
- Never close any issue.
- Fetch only public endpoints - no authenticated reads of the tap from this routine.

### Exit criteria

You are done when one of:
- No lag detected - exit clean, no output.
- Lag detected, no existing open issue - one new issue opened with the template above.
- Lag detected, existing open issue - one comment added with the still-not-in-sync note.

### If something goes wrong

- Homebrew formula URL 404s (file moved to a different letter directory or renamed) - post the issue anyway, note in the body that automatic checks need updating, `cc @franzenzenhofer`.
- nixpkgs master temporarily unreachable - skip this run, do not open an issue about connectivity. Next Monday will try again.
- Canonical GitHub Release tag is a pre-release or draft - skip this run entirely.
