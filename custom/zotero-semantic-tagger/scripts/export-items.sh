#!/usr/bin/env bash
# Bulk dump for Stage 1 (replaces one `get metadata` call per item) and for evidence.sh.
# Usage: export-items.sh [--collection KEY | --all] [--out DIR] [--fulltext] [-j N]
# Writes (default DIR=.cache/zotero-export, relative to cwd):
#   items.tsv      key, title, abstract, tags(;-joined), collections(;-joined)  (tabs/newlines flattened)
#   items.jsonl    one compact JSON object per item (key,title,abstract,tags,collections,doi,date)
#   abstracts/KEY.txt   title + abstract (evidence.sh input)
#   fulltext/KEY.txt    only with --fulltext (zotero-cli get fulltext; may be truncated by Zotero)
set -euo pipefail
scope=all; coll=""; out=".cache/zotero-export"; ft=0; jobs=6
while [ $# -gt 0 ]; do case "$1" in
  --collection) scope=coll; coll="$2"; shift 2;; --all) scope=all; shift;;
  --out) out="$2"; shift 2;; --fulltext) ft=1; shift;; -j) jobs="$2"; shift 2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
mkdir -p "$out/abstracts" "$out/.parts"; [ "$ft" = 1 ] && mkdir -p "$out/fulltext"
if [ "$scope" = coll ]; then list="$(zotero-cli --json get collection-items "$coll" --limit 100000)"
else list="$(zotero-cli --json get recent --limit 100000)"; fi
jq -e '.ok' <<<"$list" >/dev/null || { echo "listing failed: $(jq -r .error <<<"$list")" >&2; exit 2; }
keys="$(jq -r '.data.items[]|select(.itemType!="attachment" and .itemType!="note")|.key' <<<"$list")"
export OUT="$out" FT="$ft"
fetch_one() { k="$1"
  zotero-cli --json get metadata "$k" | jq -c --arg k "$k" 'select(.ok)|.data.data|{key:$k,title,abstract:(.abstractNote//""),tags:[.tags[]?.tag],collections,doi:(.DOI//""),date}' > "$OUT/.parts/$k.json"
  jq -r '.title+"\n\n"+.abstract' "$OUT/.parts/$k.json" > "$OUT/abstracts/$k.txt"
  if [ "$FT" = 1 ]; then zotero-cli --json get fulltext "$k" | jq -r 'select(.ok)|.data.text' > "$OUT/fulltext/$k.txt" || true; fi; }
export -f fetch_one
printf '%s\n' $keys | xargs -P "$jobs" -I{} bash -c 'fetch_one {}'
cat $(printf "$out/.parts/%s.json " $keys) > "$out/items.jsonl"
jq -r '[.key,.title,.abstract,(.tags|join(";")),(.collections|join(";"))]|map(gsub("[\t\r\n]+";" "))|@tsv' "$out/items.jsonl" > "$out/items.tsv"
rm -rf "$out/.parts"
echo "exported $(wc -l < "$out/items.tsv") items -> $out" >&2
