#!/usr/bin/env bash
# Deterministic tag linter. Rules + catalog come ONLY from tag-vocabulary.json.
# Usage: tag-lint.sh [--vocab FILE] [--items-json FILE] [--quiet]
#   --items-json FILE  use a saved `zotero-cli --json get recent` envelope instead of the live library
# Output: TSV  SEVERITY<TAB>CODE<TAB>KEY<TAB>DETAIL ; exit 1 if any ERROR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vocab="$here/../tag-vocabulary.json"; items_file=""; quiet=0
while [ $# -gt 0 ]; do case "$1" in
  --vocab) vocab="$2"; shift 2;; --items-json) items_file="$2"; shift 2;;
  --quiet) quiet=1; shift;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
command -v jq >/dev/null || { echo "jq missing" >&2; exit 2; }
jq -e '.rules and .tags' "$vocab" >/dev/null || { echo "bad vocabulary: $vocab" >&2; exit 2; }

if [ -n "$items_file" ]; then items="$(cat "$items_file")"
else items="$(zotero-cli --json get recent --limit 100000)"; fi
jq -e '.ok' <<<"$items" >/dev/null || { echo "zotero-cli failed: $(jq -r '.error' <<<"$items")" >&2; exit 2; }
if [ -n "$items_file" ]; then libtags="$(jq '[.data.items[].tags[]]|unique|map({tag:.})|{ok:true,data:{tags:.}}' <<<"$items")"
else libtags="$(zotero-cli --json get tags)"; fi
jq -e '.ok' <<<"$libtags" >/dev/null || { echo "get tags failed" >&2; exit 2; }

out="$(jq -r --slurpfile v "$vocab" --argjson lt "$libtags" '
 $v[0] as $V | $V.rules as $R | ($R.ignore_tags) as $ign
 | ($R.prefixes|map(select(.kind=="domain").prefix|rtrimstr(":"))) as $dp
 | ($R.prefixes|map(.prefix)) as $allp
 | ($V.tags|map({key:.tag,value:.})|from_entries) as $cat
 | [.data.items[] | {key, title, tags:([.tags[]?]|map(select(. as $t|$ign|index($t)|not)))}] as $it
 | def e(sev;code;key;d): [sev,code,key,d]|@tsv;
 # ---- vocabulary self-check
 ( ("^(" + ($dp|join("|")) + "):[a-z0-9]+(-[a-z0-9]+)*$") as $exp
   | (if $exp != $R.regex.domain then e("ERROR";"VOCAB_REGEX_MISMATCH";"-";"rules.regex.domain != built from active prefixes: "+$exp) else empty end),
     ($V.tags|map(.tag)) as $names
   | ($names|group_by(.)|map(select(length>1)|.[0])[]|e("ERROR";"VOCAB_DUPLICATE";"-";.)),
     (if $names != ($names|sort) then e("ERROR";"VOCAB_UNSORTED";"-";"catalog not sorted by tag") else empty end),
     ($V.tags[]| select((.tag|test($R.regex.domain) or test($R.regex.status))|not)|e("ERROR";"VOCAB_BAD_TAG";"-";.tag)),
     ($V.tags[]| select((if (.tag|startswith("_")) then "_" else (.tag|split(":")[0]) end) != .prefix)|e("ERROR";"VOCAB_PREFIX_FIELD";"-";.tag)),
     ($V.tags[]| select(.prefix as $p | ($allp|index(if $p=="_" then "_" else $p+":" end))==null)|e("ERROR";"VOCAB_UNKNOWN_PREFIX";"-";.tag)),
     ($V.tags[]| .tag as $t | (.requires//[])[] | select($cat[.]==null)|e("ERROR";"VOCAB_REQUIRES_MISSING";"-";$t+" -> "+.)),
     ($R.interaction_rules.allowed[]| select($cat[.]==null)|e("ERROR";"VOCAB_INTERACTION_MISSING";"-";.))
 ),
 # ---- per item
 ( $it[] | . as $i | .key as $k | .tags as $tg
   | (if ($tg|length) < $R.count.min or ($tg|length) > $R.count.max then e("ERROR";"COUNT";$k;"\($tg|length) tags (allowed \($R.count.min)-\($R.count.max))")
      elif ($tg|length) < $R.count.target_min or ($tg|length) > $R.count.target_max then e("WARN";"TARGET";$k;"\($tg|length) tags (target \($R.count.target_min)-\($R.count.target_max))") else empty end),
     ($tg[] | . as $t
       | if ($R.legacy_patterns|map(. as $p|$t|test($p))|any) then e("ERROR";"LEGACY";$k;$t)
         elif ($R.rejected_prefixes|map(. as $r|select($t|startswith($r.prefix)))|length)>0 then e("ERROR";"REJECTED_PREFIX";$k;$t)
         elif (($t|test($R.regex.domain))|not) and (($t|test($R.regex.status))|not) then e("ERROR";"REGEX";$k;$t)
         else
           ( if ($t|test($R.interaction_rules.pattern)) and (($R.interaction_rules.allowed|index($t))==null) then e("ERROR";"INTERACTION";$k;$t+" (allowed: fixed six)") else empty end ),
           ( if ($R.granularity_anti_explosion.forbidden_tags|index($t)) or ($R.granularity_anti_explosion.forbidden_patterns|map(. as $p|$t|test($p))|any) then e("ERROR";"GRANULARITY";$k;$t) else empty end ),
           ( ($cat[$t].requires//[])[] | select(. as $r | ($tg|index($r))==null) | e("ERROR";"REQUIRES";$k;$t+" needs "+.) ),
           ( if $cat[$t]==null then e("ERROR";"DRIFT_UNCATALOGED";$k;$t) else empty end )
         end),
     empty
 ),
 # ---- drift: library tag list vs catalog vs items
 ( ([$it[].tags[]]|group_by(.)|map({key:.[0],value:length})|from_entries) as $use
   | ([$lt.data.tags[].tag] | map(select(. as $t|$ign|index($t)|not))) as $live
   | ($live[]| select($use[.]==null)|e("WARN";"TAG_WITHOUT_ITEMS";"-";.)),
     ($V.tags[]| select(.status!="reserved" and $use[.tag]==null)|e("ERROR";"DRIFT_UNUSED_CATALOG";"-";.tag+" (not in use; mark status=reserved or remove)")),
     ($V.tags[]| select(.status=="reserved" and $use[.tag]!=null)|e("WARN";"RESERVED_IN_USE";"-";.tag+" ("+($use[.tag]|tostring)+" items; drop status)"))
 ),
 e("INFO";"SUMMARY";"-";"\($it|length) items, \([$it[].tags[]]|unique|length) distinct tags, \($V.tags|length) catalog entries")
' <<<"$items")"

[ "$quiet" = 1 ] || printf '%s\n' "$out"
errs=$(grep -c '^ERROR' <<<"$out" || true); warns=$(grep -c '^WARN' <<<"$out" || true)
echo "tag-lint: $errs error(s), $warns warning(s)" >&2
[ "$errs" -eq 0 ]
