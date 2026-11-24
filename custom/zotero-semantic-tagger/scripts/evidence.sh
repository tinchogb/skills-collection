#!/usr/bin/env bash
# Multi-term / PCRE2 evidence counts per item, local, from export-items.sh output.
# Replaces hundreds of single-term `zotero-cli read --find` calls.
# Usage: evidence.sh [--dir DIR] [--scope abstracts|fulltext] [--min N] [--only-hits] TERM...
#   TERM = plain words      -> case-insensitive, whole-word, space/hyphen interchangeable ("rna seq" matches rna-seq, rna  seq)
#        = label=/PCRE2/    -> raw PCRE2 regex (e.g. 'ribo=/ribo(some)?[\s-]?(profiling|seq)/')
# Output TSV: key, title(40 chars), one count column per term (match counts; multi-line aware). Last line: totals.
# rg: /home/ubuntu/.cargo/bin/rg (needs +pcre2), fallback `rg` in PATH.
set -euo pipefail
dir=".cache/zotero-export"; scope=abstracts; min=1; only=0; terms=()
while [ $# -gt 0 ]; do case "$1" in
  --dir) dir="$2"; shift 2;; --scope) scope="$2"; shift 2;; --min) min="$2"; shift 2;;
  --only-hits) only=1; shift;; -h|--help) sed -n '2,10p' "$0"; exit 0;; *) terms+=("$1"); shift;; esac; done
[ ${#terms[@]} -gt 0 ] || { echo "no terms" >&2; exit 2; }
RG=/home/ubuntu/.cargo/bin/rg; [ -x "$RG" ] || RG=rg
command -v "$RG" >/dev/null || { echo "ripgrep not found" >&2; exit 2; }
"$RG" --pcre2-version >/dev/null 2>&1 || { echo "$RG lacks PCRE2" >&2; exit 2; }
src="$dir/$scope"; [ -d "$src" ] || { echo "missing $src (run export-items.sh${scope:+ }$([ "$scope" = fulltext ] && echo --fulltext))" >&2; exit 2; }
declare -A title; while IFS=$'\t' read -r k t _; do title[$k]="${t:0:40}"; done < "$dir/items.tsv"
labels=(); tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; i=0
for t in "${terms[@]}"; do
  if [[ "$t" =~ ^([^=/]+)=/(.*)/$ ]]; then lab="${BASH_REMATCH[1]}"; re="${BASH_REMATCH[2]}"
  else lab="$t"; esc="$(printf '%s' "$t" | sed -E 's/[][\\.^$*+?(){}|\/]/\\&/g; s/[ -]+/[\\s-]+/g')"; re="(?<![A-Za-z0-9])${esc}(?![A-Za-z0-9])"; fi
  labels+=("$lab")
  "$RG" --pcre2 -i -U --count-matches --no-heading -e "$re" "$src" 2>/dev/null | awk -F: '{n=$NF; sub(/:[0-9]+$/,""); f=$0; sub(/.*\//,"",f); sub(/\.txt$/,"",f); print f"\t"n}' > "$tmp/$i" || true
  i=$((i+1))
done
{ printf 'key\ttitle'; printf '\t%s' "${labels[@]}"; printf '\n'
  for k in "${!title[@]}"; do
    row="$k"$'\t'"${title[$k]}"; tot=0; hit=0
    for ((j=0;j<i;j++)); do c=$(awk -F'\t' -v k="$k" '$1==k{print $2}' "$tmp/$j"); c=${c:-0}; row+=$'\t'"$c"; tot=$((tot+c)); [ "$c" -ge "$min" ] && hit=1; done
    if [ "$only" = 0 ] || [ "$hit" = 1 ]; then printf '%s\n' "$row"; fi
  done | sort; } | awk -F'\t' 'NR==1{print;n=NF;next}{print;for(i=3;i<=n;i++)s[i]+=$i}END{printf "TOTAL\t-";for(i=3;i<=n;i++)printf "\t%d",s[i];printf "\n"}'
