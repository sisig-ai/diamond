---
name: ask-diamond
description: >-
  Search an Obsidian vault with Diamond (local hybrid semantic+BM25 CLI).
  Use when the user asks about their notes/vault, when you need vault context
  before editing a note, or instead of grep/find+reading whole markdown files
  across an Obsidian vault. Triggers: Obsidian, vault, notes, diamond ask.
---

# Ask Diamond

Diamond retrieves ranked markdown snippets from an Obsidian vault. Offline, CPU-only. Retrieval only — it does not write notes or generate answers.

Prefer Diamond over `grep` / `find` / reading entire notes when you need relevant vault context.

## Prerequisites

- `diamond` on `PATH`, or a built binary at `<diamond-repo>/zig-out/bin/diamond`
- Vault path = Obsidian vault root (folder containing notes / `.obsidian/`)

If missing, build once:

```bash
cd <diamond-repo> && zig build -Doptimize=ReleaseFast
```

## Procedure

1. Form a **focused** query (entity + intent). Do not paste chat logs or whole files.
2. Run:

```bash
diamond ask --vault "$VAULT" "<query>" --json --top-k 5
```

3. Parse stdout JSON. Ignore stderr unless exit non-zero (`rebuilding index (...)` on stderr is normal).
4. Use top hits:
   - Open `path` at `start_line` — do not re-grep for the same content.
   - Prefer `snippet` first; widen to nearby lines only if needed.
5. If results miss: one sharper re-query, then stop. Do not dump the vault.

## JSON fields

| Field | Meaning |
|-------|---------|
| `path` | Vault-relative note path |
| `heading_trail` | Heading breadcrumb array |
| `start_line` / `end_line` | 1-indexed inclusive line range |
| `snippet` | Retrieved text |
| `score` | Rank order only (uncalibrated) |

## Query patterns

| Intent | Example |
|--------|---------|
| By name / title | `Dinkum`, `Cozy Logistics` |
| By tag | `#gardening` |
| By meaning | `how do I set up the Minecraft server` |
| Recommendation | `most recommended cozy game` |

## Do not

- Use Diamond to edit notes or drive Obsidian plugins
- Treat `score` as a probability
- Raise `--top-k` above ~10 unless the first page is clearly insufficient
- Fall back to whole-vault greps after a good Diamond hit for the same question

## Failures

| Exit | Meaning |
|------|---------|
| `0` | Success (including zero hits) |
| `1` | Runtime / index failure |
| `2` | Bad CLI args |

Unsupported frontmatter forms for `title` / `aliases` / `tags` abort indexing with path + line — fix that note's YAML.
