#!/usr/bin/env bash
# Collection linter. Rules come ONLY from ../../zotero-semantic-tagger/tag-vocabulary.json (.rules.collections).
# Checks: name regex, max depth (Private_Projects = level 1), allowed roots, duplicate sibling names,
# and ZotMoov source of truth: folder tree under pdf_root/Private_Projects == collection tree.
# Usage: collection-lint.sh [--vocab FILE] [--collections-json FILE] [--pdf-root DIR] [--no-fs]
# Output TSV SEVERITY CODE KEY DETAIL; exit 1 on any ERROR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vocab="$here/../../zotero-semantic-tagger/tag-vocabulary.json"; cj=""; root=""; fs=1
while [ $# -gt 0 ]; do case "$1" in
  --vocab) vocab="$2"; shift 2;; --collections-json) cj="$2"; shift 2;;
  --pdf-root) root="$2"; shift 2;; --no-fs) fs=0; shift;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
cols="$( [ -n "$cj" ] && cat "$cj" || zotero-cli --json get collections )"
jq -e '.ok' <<<"$cols" >/dev/null || { echo "get collections failed" >&2; exit 2; }
[ -n "$root" ] || root="$(jq -r '.rules.collections.pdf_root' "$vocab")"

# path list: key<TAB>path<TAB>depth (depth of the path from its top-level root)
paths="$(jq -r '
 [.data.collections[]] as $c | ($c|map({key:.key,value:.})|from_entries) as $m
 | def path($k): $m[$k] as $x | if ($x.parentCollection//"")=="" then $x.name else path($x.parentCollection)+"/"+$x.name end;
 $c[] | [.key, path(.key), (path(.key)|split("/")|length|tostring)] | @tsv' <<<"$cols")"

out="$(jq -rn --arg paths "$paths" --slurpfile v "$vocab" --argjson c "$cols" --arg fsdirs "$( [ "$fs" = 1 ] && [ -d "$root/Private_Projects" ] && (cd "$root" && find Private_Projects -mindepth 1 -type d | sort) || echo __SKIP__ )" '
 $v[0].rules.collections as $R
 | def e(s;c;k;d): [s,c,k,d]|@tsv;
 ($paths|split("\n")|map(select(length>0)|split("\t")|{key:.[0],path:.[1],depth:(.[2]|tonumber)})) as $P
 | ($c.data.collections|map({key:.key,value:.name})|from_entries) as $name
 | ( $P[] | . as $p | ($p.path|split("/")) as $seg
   | (if ($R.roots|index($seg[0]))==null then e("ERROR";"ROOT";$p.key;"top-level "+$seg[0]+" not in "+($R.roots|join(","))) else empty end),
     (if ($name[$p.key]|test($R.name_regex))|not then e("ERROR";"NAME";$p.key;$p.path) else empty end),
     (if $p.depth > $R.max_depth then e("ERROR";"DEPTH";$p.key;"level \($p.depth) > \($R.max_depth): "+$p.path) else empty end) ),
   ( $P|group_by(.path)|map(select(length>1))[]|e("ERROR";"DUPLICATE_PATH";(map(.key)|join(","));.[0].path) ),
   ( if $fsdirs=="__SKIP__" then e("WARN";"FS_SKIPPED";"-";"no PDF folder tree checked") else
       ($fsdirs|split("\n")|map(select(length>0))) as $d
       | ($P|map(select(.path|startswith("Private_Projects/"))|.path)) as $cp
       | (( ($cp-$d)[]|e("ERROR";"FOLDER_MISSING";"-";"collection without folder: "+.) ),
          ( ($d-$cp-["Private_Projects"])[]|e("ERROR";"FOLDER_ORPHAN";"-";"folder without collection: "+.) ))
     end ),
   e("INFO";"SUMMARY";"-";"\($P|length) collections, max depth \([$P[].depth]|max)")
')"
printf '%s\n' "$out"
errs=$(grep -c '^ERROR' <<<"$out" || true)
echo "collection-lint: $errs error(s)" >&2
[ "$errs" -eq 0 ]
