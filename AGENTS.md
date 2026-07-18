# Using Diamond from an agent

Diamond is a local CLI for semantic search over an Obsidian vault. Prefer it over `grep`/`find` + reading whole notes when you need relevant context from the vault.

## When to use it

- Locating notes by meaning ("cozy game recommendations", "how do I deploy X")
- Finding the right section before editing a note
- Gathering a small set of snippets for a grounded answer

Do **not** use it for: writing/editing notes, Obsidian plugin control, or generating final prose answers (Diamond only retrieves).

## Command

```bash
diamond ask --vault <VAULT_PATH> "<natural language or keyword query>" --json --top-k 5
```

- Always pass `--json` so you can parse results.
- Prefer focused queries (entity + intent) over long pasted chat history.
- Default `top-k` is 5; raise only if the first page is insufficient.
- Vault path must be the Obsidian vault root (the folder that contains `.obsidian/` or your note tree).

If `diamond` is not on `PATH`, use the built binary:

```bash
/path/to/diamond/zig-out/bin/diamond ask --vault <VAULT_PATH> "<query>" --json
```

## How to consume results

Parse the JSON. Each hit has:

| Field | Use |
|-------|-----|
| `path` | Vault-relative note path — open this file |
| `heading_trail` | Heading breadcrumb to the section |
| `start_line` / `end_line` | 1-indexed inclusive lines — jump here; do not re-grep |
| `snippet` | Retrieved text — usually enough to decide relevance |
| `score` | Ordering only; not a calibrated probability |

Workflow:

1. Call `diamond ask ... --json` once with a focused query.
2. Open `path` at `start_line` for the top hit(s) you need.
3. If the snippet is too thin, re-ask with a sharper query or read the surrounding lines in that file — do not dump the whole vault.

Stderr may show `rebuilding index (...) in Nms` on first use or after vault changes. That is normal. Warm queries are silent on stderr.

## Query tips

- Names / titles: `"Dinkum"`, `"Cozy Logistics"`
- Tags: `"#gardening"` or the tag word itself
- Behavior: `"how do I set up the Minecraft server"`
- Avoid dumping error logs or entire files as the query string

## What Diamond indexes

- Markdown notes only (`.md`)
- Frontmatter `title`, `aliases`, `tags`; ATX headings; inline `#tags`
- Skips `.obsidian/`, `.trash/`, `.git/`, `node_modules/`
- Wiki-links are searchable as text but not resolved as a graph

## Failures

- Unsupported `title` / `aliases` / `tags` YAML forms abort indexing with path + line — fix the frontmatter or remove the field form.
- Empty vault / no markdown → non-zero exit.
- Exit `2` = bad CLI args; `1` = runtime failure; `0` = success (including zero hits).
