---
name: zotero-library-curator
description: Curate scientific papers in Zotero with strict collection, subcollection and tag rules - classify, file, tag, triage the `Unclassified` queue, audit `Unfiled Items`, normalize tags, flag duplicates. Use when the user asks to organize, classify, file, tag, curate or clean up papers or collections.
---

# Zotero library curator

Goal: file every paper under a clean, filesystem-safe collection hierarchy with a small set of precise tags, using `zotero-cli` (read `.agents/skills/zotero-cli/SKILL.md` first). Always pass `--json` when parsing output.

## JSON handling (mandatory)

ALWAYS parse `zotero-cli --json` output with `jq` (never grep/sed/python on the raw JSON, never read whole envelopes into context). Check `.ok` first and print only the fields you need. Envelope: `{ok, data, error}`; item metadata is at `.data.data` (tags `.data.data.tags[].tag`, abstract `.data.data.abstractNote`), listings at `.data.items[]` / `.data.collections[]`, text output at `.data.text`.

```bash
zotero-cli --json get metadata <KEY> | jq '{ok, title: .data.data.title, abstract: .data.data.abstractNote, tags: [.data.data.tags[].tag], collections: .data.data.collections}'
zotero-cli --json get collection-items <COLL_KEY> --limit 100 | jq -r '.data.items[] | [.key, .title, (.tags|join(","))] | @tsv'
zotero-cli --json get collections | jq -r '.data.collections[] | [.key, .name, (.parentCollection // "-")] | @tsv'
zotero-cli --json batch ... | jq -e '.ok'    # fails the command when ok is false
```

Build `--add-tags`/`--remove-tags` JSON arrays with `jq -cn --arg s "a,b,c" '$s|split(",")'`.

## Rules at a glance (edit here)

| Topic | Rule |
|---|---|
| Collection names | Title Case, no spaces or special chars, `_` between concepts, `-` inside a phrase, acronyms stay uppercase |
| Roots | `Private_Projects` (mine to curate), `Shared_Projects` (read-only for this skill), `Unclassified` (queue) |
| Max depth | 4 levels counting `Private_Projects` as Level 1 (`Private_Projects/Level2/Level3/Level4`); a 5th needs user confirmation |
| Tags | delegate to `zotero-semantic-tagger`; fallback in step 2 reads `tag-vocabulary.json` directly |
| Primary Collection | exactly 1 per paper, inside `Private_Projects/...`; source of truth is the PDF's folder under `/mnt/pdfs-from-host/Private_Projects/...` (ZotMoov, ENABLED: folder tree verified to mirror the collection tree) |
| Secondary Collections | any number, in `Private_Projects/...` or `Shared_Projects/...` |
| Queue | top-level `Unclassified` (plus native `Unfiled Items`) |
| Duplicates | flag only; never delete or merge |
| Lint | run `scripts/collection-lint.sh` and `../zotero-semantic-tagger/scripts/tag-lint.sh` before and after changes; both must report 0 errors |
| Mutations | only after user confirms the summary table (unless told to auto-apply) |

## Rules source: `tag-vocabulary.json`

Tag and collection rules are NOT duplicated here. They live in `.agents/skills/zotero-semantic-tagger/tag-vocabulary.json` (`.rules` + `.tags`); read them with `jq`:

```bash
V=.agents/skills/zotero-semantic-tagger/tag-vocabulary.json
jq '.rules.collections' $V      # roots, name_regex, max_depth, pdf_root, ZotMoov flag
jq -r '.rules.prefixes[]|[.prefix,.boundary]|@tsv' $V
```

## Collection linter

```bash
.agents/skills/zotero-library-curator/scripts/collection-lint.sh     # exit 1 on ERROR
```

Checks, from `.rules.collections`: `NAME` (regex), `DEPTH` (Private_Projects = level 1, max 4), `ROOT` (only the three roots), `DUPLICATE_PATH`, and ZotMoov consistency: `FOLDER_MISSING` / `FOLDER_ORPHAN` compare the folder tree under `/mnt/pdfs-from-host/Private_Projects` with the collection tree (use `--no-fs` when the mount is absent). Run it before proposing a rename/move and after applying one.

## 0. Scope boundary

- Three top-level roots exist: `Private_Projects`, `Shared_Projects`, and `Unclassified`.
- Operate ONLY inside `Private_Projects` (create, rename, restructure, file items) and `Unclassified` (triage and cleanup).
- NEVER rename, restructure, or remove items from anything under `Shared_Projects`, unless the user explicitly instructs it. Adding an item to a `Shared_Projects` collection as a Secondary is allowed only when proposed and confirmed.
- Never create a Primary Collection, and never trigger a ZotMoov move, into `Shared_Projects` or `Unclassified`.

## 1. Collection and subcollection naming

- Allowed characters: letters, digits, `_`, `-`. Nothing else: no spaces, `&`, `,`, `/`, `:`, `(`, `)`, `'`.
- `_` separates distinct fields or concepts (replaces `&` and `,`).
- `-` joins words of one multi-word phrase.
- Title Case for every word or phrase; keep acronyms uppercase (`RNA`, `CLIP`, `MD`, `ML`, `PDB`).
- Same convention for every subcollection at every level.

| Bad | Good |
|---|---|
| `Protein-RNA interactions & binding` | `Protein-RNA_Interactions_Binding` |
| `Binding interface prediction methods` | `Binding_Interface-Prediction-Methods` |
| `ML, MD simulations` | `ML_MD-Simulations` |

Before creating a collection, run `zotero-cli --json get collections` and `zotero-cli --json collections search "<query>"` to reuse an existing one. Rename non-conforming collections only as a proposal (see step 5).

## 2. Tags (delegation, with self-contained fallback)

**Primary delegation:** for every item you curate or audit, delegate ALL tag generation, normalization and legacy tag migration (`topic/...`, `type/...`) to `.agents/skills/zotero-semantic-tagger/SKILL.md` whenever that file exists. Follow its pipeline, then put its proposed adds/removes in this skill's table. Do not invent tags yourself in that case.

**Fallback (only if `zotero-semantic-tagger` is missing):** do not invent rules. Read them from `tag-vocabulary.json` (if the file is also missing, stop and ask the user): `jq '.rules' $V` gives the 9 active prefixes, the two regexes, the 1-10 count (target 4-7), rejected prefixes (`doc:`, `lang:`, `task:`), the six interaction tags, the ncRNA/stacking `requires` rules, the Granularity & Anti-Explosion rule, form rules, composition rules and the Data Provenance Override. `jq -r '.tags[]|[.tag,.definition]|@tsv' $V` is the catalog: reuse it before inventing. Always: ignore the legacy `zotmoov` tag, NEVER remove `_` tags unless told, propose an explicit replacement or removal for each legacy tag, write back only after confirmation with `batch --add-tags/--remove-tags` (never `edit --tags`), and finish with `.agents/skills/zotero-semantic-tagger/scripts/tag-lint.sh`.

**Deferred TODOs (not active):** Elephant-1 decision engine and local `bge-m3`/`gte-reranker` tag ranking (`.rules.todo_deferred`).

## 3. Hierarchy and depth limit

- Organize broad scientific domain -> subdomain -> topic -> specific subtopic using subcollections.
- Maximum 4 levels, with `Private_Projects` as Level 1: `Private_Projects/Level2/Level3/Level4`. Count the depth of every path you propose, including the root.
- If a 5th level seems necessary, STOP. Do not create it. Ask the user for confirmation with a clear justification (what papers, why levels 1-4 cannot hold them, alternative placement at level 4). Continue only after an explicit yes.

## 4. Multi-collection assignment and ZotMoov

- Assign a paper to ALL relevant collections when it spans several equally important topics.
- Every curated item has exactly ONE **Primary Collection**, inside `Private_Projects/...`: its main thematic home.
- **Persistent source of truth (enabled):** ZotMoov "Move Selected to Directory" has been run, so `/mnt/pdfs-from-host/Private_Projects/<collection path>/` mirrors the collection tree (verify with `collection-lint.sh`). The physical parent directory of the item's PDF attachment IS the Primary Collection. Get it first:

```bash
zotero-cli --json path <ITEM_KEY> | jq -r '.data.text'
```

- If the PDF already sits under `/mnt/pdfs-from-host/Private_Projects/<...>/`, keep that folder's collection as Primary unless its core thematic classification was wrong. Only then propose a new Primary, flagged as a file move for confirmation.
- If the PDF is elsewhere (e.g. `Shared_Projects`, `Unclassified`, or not yet moved), choose the Primary within `Private_Projects` by topic. Do not move files into `Shared_Projects` or `Unclassified`.
- **Secondary Collections** are cross-references in `Private_Projects/...` or `Shared_Projects/...`. They never move files.
- Prefer adding Secondary collections over reassigning the Primary.

### Multi-branch representation

Zotero's native multi-collection membership is the only record of an item's branches. Inspect it with `zotero-cli --json get metadata <KEY>`. Do NOT copy collection paths or the Primary into notes or `Extra` fields.

## 5. Triage and audit workflow

Inputs: items in `Unclassified` and in `Unfiled Items` (items in no collection). Status: this workflow has not been exercised yet (no unfiled items); first real run should be a dry run that stops at the table.

```bash
zotero-cli --json get collections | jq -r '.data.collections[] | select(.name=="Unclassified") | .key'
zotero-cli --json get collection-items <UNCLASSIFIED_KEY> --limit 100 | jq -r '.data.items[] | [.key, .title] | @tsv'
zotero-cli --json get metadata <ITEM_KEY> | jq '.data.data | {title, abstractNote, tags: [.tags[].tag], collections}'
```

For each item:

1. Inspect the attachment path first (`zotero-cli --json path <KEY>`), then read the metadata and abstract (read the PDF only if the abstract is not enough).
2. **Human pre-classification rule:** if the item is in `Unclassified`, evaluate ALL its current collection assignments, even ones the user set during browser import. Judge each for taxonomic accuracy and propose keep, add, remove or reassign, with a one-line justification.
3. Choose Primary (per step 4 and the attachment path), Secondary, and Collections to Remove. Check names and depth against steps 1 and 3, and scope against step 0 (never propose removing from `Shared_Projects`).
4. Get normalized tags via `zotero-semantic-tagger` (or the step 2 fallback): 1-10 tags, target 4-7, `_` tags kept. For many items, bulk-export once with `zotero-semantic-tagger/scripts/export-items.sh` instead of per-item metadata calls.
5. Check for duplicates (below).
6. Present one concise markdown table and wait for confirmation:

| Item (key, short title) | Current PDF folder | Primary Collection | Secondary Collections | Collections to Remove | Normalized Tags | Why |
|---|---|---|---|---|---|---|

7. After confirmation (or if the user said to auto-apply), apply:

```bash
zotero-cli collections create "<Name>" --parent "<ParentKey>"      # only if missing
zotero-cli collections manage --item-keys <KEY> --add-to <PRIMARY_KEY>,<SECONDARY_KEY>
zotero-cli collections manage --item-keys <KEY> --remove-from <WRONG_KEY>
zotero-cli batch --item-keys <KEY> --add-tags "met:rna-seq,tool:star" --remove-tags "topic/interface"
```

8. **Cleanup rule:** once curated, ALWAYS remove the item from `Unclassified`:

```bash
zotero-cli collections manage --item-keys <KEY> --remove-from <UNCLASSIFIED_KEY>
```

9. Verify: `zotero-cli --json get metadata <KEY>` shows the intended collections and tags, `Unclassified` no longer lists it, and both linters (`collection-lint.sh`, `tag-lint.sh`) report 0 errors.

If the item cannot be classified confidently, leave it in `Unclassified`, say why, and ask the user.

## 6. Duplicates

- Never run `delete` or `duplicates merge` on items, and never create duplicates (`--if-exists duplicate`).
- Use `zotero-cli --json duplicates find` (read-only) or notice same DOI/title while triaging.
- List suspected duplicates (keys, titles, DOI) in the report under "Potential duplicates" and leave resolution to the Zotero desktop app.

## Gotchas

- `edit --collections` and `--tags` REPLACE everything; use `collections manage` and `batch --add-tags/--remove-tags` to change incrementally.
- `collections manage --add-to` takes collection keys; look them up first, names can repeat under different parents.
- `Shared_Projects` memberships are not yours to remove: when cleaning an item, leave them untouched.
- Collection renames/moves (`collections update`) change ZotMoov folders: propose them, never batch them silently.
- Process at most ~20 items per table to keep reviews manageable.
