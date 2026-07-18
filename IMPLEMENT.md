# Diamond — implement to testable state

You are implementing Diamond in this empty git repo at `/home/kix/diamond`.
Read `PLAN.md` end-to-end. It is the approved hardened architecture. Follow it literally. Do not expand scope.

## Definition of done (this pass)
A working, buildable Zig CLI that can:
1. `zig build` succeeds (ReleaseFast + Debug)
2. `zig build test` passes with golden fixtures for parse/chunk/BM25/ranking basics
3. `./zig-out/bin/diamond ask --vault <fixture> "query" --json` returns ranked chunks
4. First run builds cache; second run is a cache hit (stderr notes rebuild reason/time only when rebuilding)
5. Sample fixture vault under `testdata/vault/` with a few notes covering title/aliases/tags/headings

Full 100-query eval corpus and release binaries are OUT OF SCOPE for this pass. Get to testable.

## Hard constraints from PLAN.md
- CLI only: `diamond ask --vault PATH QUERY [--top-k N] [--json]`
- Zig 0.16.0; pin `PaytonWebber/model2vec-zig` v0.2.0; embed `potion-base-8M` i8 via `@embedFile`
- Equal-weight RRF k=60 (NO adaptive alpha)
- Boosts ONLY: title/alias/name exact ×1.50 XOR #tag ×1.25; note saturation 0.5^n
- NO wiki-link graph, NO HNSW, NO incremental index, NO `index`/`status` commands
- Fail loudly: unsupported title/aliases/tags YAML forms abort with path+line
- Cache: `~/.cache/diamond/<sha256>/manifest.json` + `index.bin`; advisory lock; atomic rename; full rebuild when stale
- Module layout exactly as PLAN.md (`main/vault/embed/bm25/index/search.zig`)

## How to get the model asset
Use model2vec-zig's documented fetch/quantize path for potion-base-8M i8, OR download from HuggingFace and quantize with the dependency's tool. Commit tokenizer.json + model.i8.safetensors + LICENSE under `assets/potion-base-8M/`. Record SHA-256 in comments/manifest.

## Process
1. Scaffold build.zig / build.zig.zon; fetch model2vec-zig; embed assets
2. vault walk/parse/chunk + tests
3. bm25 + dense index + cache
4. search + CLI
5. Run `zig build test` and a manual ask against testdata/vault
6. Commit all work with short one-line messages (Capitalized, no feat/fix prefix). You MAY commit.

Trust this brief. Search only when you need something not here. Do not invent extra features.
