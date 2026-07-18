# Diamond

Fast, on-device semantic search for Obsidian vaults.

```bash
diamond ask --vault ~/Documents/Obsidian "what's my most recommended cozy game"
```

Returns ranked markdown snippets with file path, heading trail, and line anchors — entirely offline, CPU-only, no API keys.

## Why

Coding agents and humans both burn tokens grepping and reading whole notes. Diamond indexes a vault once, then answers natural-language questions with the exact chunks that matter.

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

## Development

```bash
zig build test
zig build -Doptimize=ReleaseFast
./zig-out/bin/diamond ask --vault testdata/vault "garden watering" --json
```

## License

MIT. Embedding weights: `minishlab/potion-base-8M` (MIT) — see `assets/potion-base-8M/LICENSE`.
