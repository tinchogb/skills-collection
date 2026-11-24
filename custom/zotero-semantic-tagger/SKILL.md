---
name: zotero-semantic-tagger
description: Generate, normalize and score semantic tags for Zotero papers with a strict prefixed kebab-case schema (met:, ml:, bio:, tool:, data:, proc:, app:, dis:, _status) for cross-cutting retrieval. Use when the user asks to tag, retag, normalize tags, migrate legacy tags (topic/..., type/...), or suggest tags for papers.
---

# Zotero semantic tagger

Goal: give every item 1-10 orthogonal, regex-valid tags (target 4-7) for fast cross-cutting retrieval across biotechnology, bioinformatics, molecular biology, computer science, software engineering, statistics and machine learning. Read `.agents/skills/zotero-cli/SKILL.md` before running commands; pass `--json` when parsing.

## JSON handling (mandatory)

ALWAYS parse `zotero-cli --json` output with `jq` (never grep/sed/python on the raw JSON, never read whole envelopes into context). Check `.ok` first and print only the fields you need. Envelope: `{ok, data, error}`; item metadata is at `.data.data` (tags `.data.data.tags[].tag`, abstract `.data.data.abstractNote`), listings at `.data.items[]` / `.data.collections[]`, text output at `.data.text`.

```bash
zotero-cli --json get metadata <KEY> | jq '{ok, title: .data.data.title, abstract: .data.data.abstractNote, tags: [.data.data.tags[].tag], collections: .data.data.collections}'
zotero-cli --json get collection-items <COLL_KEY> --limit 100 | jq -r '.data.items[] | [.key, .title, (.tags|join(","))] | @tsv'
zotero-cli --json get collections | jq -r '.data.collections[] | [.key, .name, (.parentCollection // "-")] | @tsv'
zotero-cli --json batch ... | jq -e '.ok'    # fails the command when ok is false
```

Build `--add-tags`/`--remove-tags` JSON arrays with `jq -cn --arg s "a,b,c" '$s|split(",")'`.

## Single source of truth: `tag-vocabulary.json`

All rules and the approved catalog live in ONE file, `.agents/skills/zotero-semantic-tagger/tag-vocabulary.json` (no markdown mirror exists; never recreate one). Read it with `jq`, never by hand-copying rules into notes:

```bash
V=.agents/skills/zotero-semantic-tagger/tag-vocabulary.json
jq -r '.rules.prefixes[]|[.prefix,.kind,.boundary,.excludes]|@tsv' $V     # the 9 active prefixes + boundaries
jq '.rules|{regex,count,ignore_tags,legacy_patterns,rejected_prefixes}' $V
jq '.rules|{interaction_rules,base_tag_rules,granularity_anti_explosion}' $V
jq -r '.rules.form_rules[], .rules.composition_rules[]' $V                  # form + composition rules
jq -r '.rules.new_prefix_policy[]' $V                                       # how to add a prefix
jq -r '.tags[]|[.tag,.definition,.components]|@tsv' $V                      # catalog
jq -r '.rules.todo_deferred[]' $V                                           # deferred work (do not implement)
```

Structure: `{rules: {prefixes, regex, count, ignore_tags, legacy_patterns, rejected_prefixes, new_prefix_policy, interaction_rules, base_tag_rules, granularity_anti_explosion, composition_rules, form_rules, data_provenance_override, write_back, collections, todo_deferred}, tags: [{tag, prefix, definition, components, requires?, status?}]}`. Catalog `tags` stay sorted by tag (prefix, then name; `_` first). `status: "reserved"` = defined but not yet in use. `requires` = tags that must be on the same item (e.g. `bio:mirna` requires `bio:ncrna`).

Read it at the start of every run. The 9 active prefixes are `_`, `met:`, `ml:`, `bio:`, `tool:`, `data:`, `proc:`, `app:`, `dis:`; `doc:`, `lang:`, `task:` are permanently rejected. Count is 1-10 per item (target 4-7). Quick reminders (details in the JSON): never repeat collection names; pick the prefix by what the thing IS; stay at class level (granularity rule, no `bio:m6a`); only the six canonical interaction tags; ncRNA subclasses need `bio:ncrna`.

Changing a rule or adding a tag = edit the JSON (with `jq`, keep catalog sorted), then run the linter.

## Tag linter (run before and after every write-back)

```bash
.agents/skills/zotero-semantic-tagger/scripts/tag-lint.sh            # live library; exit 1 on any ERROR
.agents/skills/zotero-semantic-tagger/scripts/tag-lint.sh --quiet    # summary only
```

Reads rules + catalog from `tag-vocabulary.json` and prints `SEVERITY CODE KEY DETAIL`. Errors: `REGEX`, `LEGACY`, `REJECTED_PREFIX`, `COUNT` (1-10), `INTERACTION`, `REQUIRES` (base-tag/stacking), `GRANULARITY`, `DRIFT_UNCATALOGED` (live tag missing from catalog), `DRIFT_UNUSED_CATALOG` (catalog tag in no item and not `reserved`), `VOCAB_*` (catalog self-check: duplicates, order, regex, prefix, regex vs prefix list). Warnings: `TARGET` (outside 4-7), `RESERVED_IN_USE`, `TAG_WITHOUT_ITEMS`. `zotmoov` is ignored. A passing run is the Stage 5 verification; fix every ERROR before reporting done.

## Pipeline

### Stage 1 - Token-efficient bulk ingestion

Never loop `get metadata` yourself. Dump a whole collection (or the library) once, in parallel, then read the TSV:

```bash
S=.agents/skills/zotero-semantic-tagger/scripts
$S/export-items.sh --collection <COLL_KEY> [--fulltext]    # or --all ; default out .cache/zotero-export
cut -f1,2,4 .cache/zotero-export/items.tsv                 # key, title, tags
jq -r '[.key,.title,.abstract]|@tsv' .cache/zotero-export/items.jsonl   # key, title, abstract
```

Files: `items.tsv` (key, title, abstract, tags `;`-joined, collections), `items.jsonl`, `abstracts/KEY.txt`, and `fulltext/KEY.txt` with `--fulltext` (Zotero text may be truncated). Print only the columns/rows you need, about 20 items per table. Re-export after a write-back if you need fresh tags in the TSV. Always also read the catalog from `tag-vocabulary.json` and the live list: `zotero-cli --json get tags | jq -r '.data.tags[].tag'`.

- Collections come from the export; use their names only to AVOID duplicating them.
- Need a single item's attachment path: `zotero-cli --json path <KEY> | jq -r '.data.text'`.
- Never dump full raw PDFs, full text or page images into a remote LLM. For a passage in context use `zotero-cli --json read <KEY> --find "<term>" --context 1 | jq '.data | {hits, matches}'` only for the few terms the local evidence helper cannot settle.

### Stage 2 - Candidate generation

Propose 8-12 candidates across the prefixes. Reuse catalog tags (then live library tags) whenever semantically equivalent. Decompose into orthogonal atomic tags: `bio:rna-protein-interaction` + `bio:ncrna`, never a compound like `bio:ncrna-protein-interaction`.

### Stage 2b - Local evidence (groundedness)

Count candidate terms across ALL exported items in one call instead of per-item `read --find`:

```bash
$S/evidence.sh --only-hits "rna-seq" "molecular dynamics" 'clip=/(e|i)?CLIP(-seq)?/'          # abstracts
$S/evidence.sh --scope fulltext --min 3 --only-hits "phase separation" "disordered region"    # needs export --fulltext
```

Plain terms are case-insensitive whole-word matches with space/hyphen interchangeable. For regexes use `label=/PCRE2/` (e.g. `'ribo=/ribo(some)?[\s-]?(profiling|seq)/'`; alternation is plain `|`, not `\|`). It uses `/home/ubuntu/.cargo/bin/rg` (ripgrep 15.2, +pcre2), falling back to `rg` in PATH, multi-line aware. Output is a TSV matrix (item x term) with a TOTAL row. Short, ambiguous terms (`R`, `C++`) need an explicit regex with lookarounds, otherwise they match everything. Abstract hits alone can undercount; absence is weak evidence, presence is strong.

### Stage 3 - Deterministic normalization, regex gate, legacy protection

Apply to every candidate and every existing tag on the item:
1. Lowercase, transliterate accents, replace spaces/`/`/`_` with `-`, collapse repeated `-`.
2. Strip stopwords; collapse versions; apply singular/plural rules (`rules.form_rules`).
3. Fuzzy-dedupe against the catalog and the library vocabulary (`rnaseq` -> `met:rna-seq`); map to the existing canonical tag. Split compound tags into orthogonal ones.
4. Regex gate (`rules.regex`): drop or fix anything not matching. Reject unknown and rejected prefixes.
5. Drop candidates that equal a collection or folder name.
6. **Never remove `_` status tags** unless the user explicitly says so.
7. Legacy non-conforming tags: propose an explicit mapping or removal, one line each. Never silently delete.

### Stage 4 - Decision / scoring round

**Deferred (TODO, do not implement):** the local Elephant-1 9B decision engine (interface unspecified) and local embedding/reranker ranking with `bge-m3` / `gte-reranker` (`/srv/ai/registry/weights/embeddings`, untested). Do not invent a command for them; mention them only if asked. Use the interactive fallback:

- Score each candidate 1-5 on Specificity, Groundedness (stated in title, abstract or evidence-helper hits), Utility (would help retrieve this paper among others).
- Discard any candidate with Groundedness < 4. Keep candidates with mean >= 4.0.
- **Data Provenance Override** (`rules.data_provenance_override`): only if the proposal table flags it `OVERRIDE` and the user confirms.

### Stage 5 - Selection and safe write-back

1. Select the top 4-7 tags, enforcing `1 <= total_tags <= 10` for the final set. If more than 10 would remain, propose removals.
2. Show one table and wait for confirmation:

| Item | Current Tags | Proposed Add | Proposed Remove | Scores/Rationale |
|---|---|---|---|---|

3. After confirmation (or explicit auto-apply):

```bash
zotero-cli --json batch --item-keys <KEY> --add-tags "met:rna-seq,tool:star" | jq -e '.ok'
zotero-cli --json batch --item-keys <KEY> --remove-tags "topic/interface,type/method" | jq -e '.ok'
```

4. Add every newly approved tag to the catalog in `tag-vocabulary.json` (`tag`, `prefix`, `definition`, `components`, `requires` if stacked), keep `.tags` sorted, e.g.:

```bash
jq --arg t "met:rna-seq" --arg d "Bulk RNA sequencing." '.tags += [{tag:$t,prefix:($t|split(":")[0]),definition:$d,components:"atomic"}] | .tags |= sort_by(.tag)' $V > /tmp/v.json && mv /tmp/v.json $V
```

5. Verify: run `scripts/tag-lint.sh`; it must end with 0 errors (regex, 1-10 count, base/interaction rules, no drift, `_` tags intact).

## Gotchas

- Tags containing `:` or `/` are fine for the CLI, but quote the list. Use a JSON array if a name has a comma.
- `edit --tags` replaces ALL tags (and would wipe `_` tags); use `batch --add-tags/--remove-tags`.
- Process about 20 items per table.
- This skill never touches collections; hand that to `zotero-library-curator`.
- Revisit rule (TODO): when a new prefix is promoted, re-run older collections (e.g. `proc:`/`app:`/`dis:` pass).
