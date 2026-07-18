# Diamond

Fast, on-device semantic search for Obsidian vaults.

```bash
diamond ask --vault ~/Documents/Obsidian "what's my most recommended cozy game"
```

Returns ranked markdown snippets with file path, heading trail, and line anchors — entirely offline, CPU-only, no API keys.

## Why

Coding agents and humans both burn tokens grepping and reading whole notes. Diamond indexes a vault once, then answers natural-language questions with the exact chunks that matter.

The way I actually use it: Diamond sits between my Hermes agent and Obsidian. Obsidian is the long-horizon / permanent context store — ideas, session notes, decisions, research. Hermes (and other coding agents) write into that vault over time; when I need something back, Diamond retrieves the relevant slices instead of dumping the whole history into the prompt. Persist freely, retrieve on demand.

Inspired by [Semble](https://github.com/MinishLab/semble)'s hybrid retrieval shape, adapted for Obsidian markdown (titles, aliases, tags, headings) instead of code.

## Install

Requires [Zig 0.16](https://ziglang.org/download/).

```bash
git clone https://github.com/sisig-ai/diamond.git
cd diamond
zig build -Doptimize=ReleaseFast
./zig-out/bin/diamond --help
```

Optional: put `./zig-out/bin/diamond` on your `PATH`.

## Usage

```bash
# Human-readable results
diamond ask --vault /path/to/vault "your question"

# JSON for agents / scripts
diamond ask --vault /path/to/vault "your question" --json --top-k 5
```

| Flag | Default | Notes |
|------|---------|-------|
| `--vault PATH` | required | Obsidian vault root |
| `--top-k N` | `5` | `1..50` |
| `--json` | off | Machine-readable results |

First run builds and caches an index under `~/.cache/diamond/` (or `$XDG_CACHE_HOME/diamond/`). Later runs reuse it until files change; rebuild reason and timing go to stderr.

### JSON shape

```json
{
  "results": [
    {
      "path": "Gaming/Cozy Logistics Game Recommendations.md",
      "heading_trail": ["Cozy Logistics Game Recommendations", "Where to start"],
      "start_line": 30,
      "end_line": 32,
      "score": 0.033,
      "snippet": "..."
    }
  ]
}
```

`score` is an uncalibrated ranking score (useful for ordering only).

## How it works

1. Walk `*.md`, skip `.obsidian/`, `.trash/`, `.git/`, `node_modules/`
2. Parse frontmatter (`title`, `aliases`, `tags`), ATX headings, inline tags
3. Chunk on heading boundaries (~750 bytes)
4. **Dense:** [Model2Vec](https://github.com/MinishLab/model2vec) `potion-base-8M` (i8, embedded in the binary via [model2vec-zig](https://github.com/PaytonWebber/model2vec-zig))
5. **Sparse:** BM25 over identifier-aware tokens, with title/alias/tag/path enrichment
6. Fuse with equal-weight RRF (`k=60`)
7. Light vault boosts: exact note-name/title/alias match, or `#tag` match; note saturation for diversity

No GPU, no network at query time, no LLM answer generation — retrieval only.

## Agent skill

Coding agents (Claude Code, Codex, Cursor, etc.) can load the portable skill at [`skills/ask-diamond/SKILL.md`](skills/ask-diamond/SKILL.md). It tells the agent when to call `diamond ask`, how to pass `--json`, and how to consume path/line anchors instead of grepping the vault.

Copy or symlink that directory into your agent's skills path (e.g. `.cursor/skills/ask-diamond`, `~/.claude/skills/ask-diamond`, or Codex skills). See also [`AGENTS.md`](AGENTS.md) for the same guidance inline.

## Development

```bash
zig build test
zig build -Doptimize=ReleaseFast
./zig-out/bin/diamond ask --vault testdata/vault "garden watering" --json
```

## Contributing

PRs welcome. Keep changes small and measured: run `zig build test`, and if you touch ranking or embeddings, show before/after on a real vault query (or the fixture vault) — don't ship new boosts without evidence.

### Honest gaps

These are known, intentional shortfalls vs a hardened v1 — good places to help:

1. **Embedding parity** — no checked-in golden vectors vs Python Model2Vec i8 (`potion-base-8M`). We need fixture texts + max abs diff ≤ `1e-5` so upgrades don't silently drift.
2. **Retrieval eval** — no labeled multi-vault corpus yet. Need ≥3 English vaults, ~100 queries (named-note, alias, tag, keyword, paraphrase), and gates: hybrid nDCG@10 ≥ better of BM25-only/dense-only; named-note/alias/tag top-3 ≥95%. Ranking changes should wait on this.
3. **Perf baselines** — PLAN targets exist (1k notes: cold index &lt;2s, warm ask p50 &lt;20ms; 10k notes: warm p50 &lt;100ms, RSS &lt;250 MiB) but aren't measured in CI. A small bench harness would help.
4. **mmap index load** — warm queries still read/copy `index.bin` into memory instead of mmap + bounds-checked views.
5. **Concurrent rebuilds** — advisory lock exists; no stress test that two `ask`s racing a stale vault never panic or serve a torn index.
6. **CLI strictness** — whitespace-only queries and misplaced/repeated `ask` tokens are accepted more loosely than they should be.
7. **Ignore rules** — does not read `.gitignore` or Obsidian's excluded-files settings; only hard-skips `.obsidian/`, `.trash/`, `.git/`, `node_modules/`.
8. **Platform** — developed on Linux/macOS; Windows is untested / unshipped.

Out of scope on purpose (don't reopen without a strong case): wiki-link graph resolution, adaptive dense/sparse α, HNSW, LLM answer generation, incremental indexing.

## License

MIT. Embedding weights: `minishlab/potion-base-8M` (MIT) — see `assets/potion-base-8M/LICENSE`.
