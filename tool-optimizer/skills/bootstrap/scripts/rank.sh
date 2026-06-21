#!/bin/sh
# WHAT: Ranks every detected tool's Relevance to THIS codebase and persists the verdicts
#       into the project inventory JSON.
# WHY:  Relevance ranks which Missing tools to recommend and flags
#       Available-but-unneeded ones ("you have DuckDB, but this repo has no tabular
#       data"), with the evidence behind each verdict. It NEVER hides a tool and NEVER
#       gates detection: it is a layer ON TOP of the full inventory, not a filter before
#       it. Every detected tool gets a verdict; none is omitted.
# WHEN: Run as the second half of the bootstrap's relevance pass, after detect.sh +
#       census.sh. Order: detect.sh -> census.sh -> rank.sh (this).
#       detect.sh overwrites the whole inventory file, so the relevance block survives a
#       re-detect ONLY because rank.sh runs again after it — it is regenerated, not
#       preserved. This keeps Relevance in sync as the codebase evolves.
# HOW:  Injectable env vars (all optional):
#         TO_CENSUS      read census JSON from this file (default: run census.sh).
#         TO_INVENTORY   inventory JSON to read + persist into
#                        (default: .claude/tool-optimizer.local.json).
#         TO_RANK_OUT    write the merged inventory here instead of in place over
#                        TO_INVENTORY (seam tests use this; real use writes in place).
#       Output: the inventory JSON with three added top-level keys —
#         "census"        the bucket counts behind the verdicts,
#         "relevance"     ordered array (alphabetical by tool, NONE omitted) of
#                         {tool, category, available, relevance, evidence, recommend, unneeded},
#         "recommendOrder" the Missing+recommended tools, ranked by relevance then name.
#       Requires jq (batch-script dependency, like detect/render/resolve).
#
#       The thresholds + per-tool mapping below are pinned by rank.seam.sh (exact
#       per-scenario verdicts). The global (no-codebase) verdict is split into GEN-core
#       (broadly useful -> recommended) vs GEN-conditional (gated on a need invisible
#       without a codebase -> shown, not pushed). rtk is GEN-core: its value ("output
#       compression, any project") is unconditional, unlike the doc/data/security tools
#       whose value is conditional.
#
#       The tool list is derived by filtering inventory VALUES that carry an `available`
#       field — so non-tool top-level keys (detectedAt, and rank's own census /
#       relevance / recommendOrder) are never mistaken for tools. This makes "none
#       omitted" structural and makes re-running rank idempotent.
#
#       Usage:
#         sh rank.sh
#         TO_CENSUS=/tmp/c.json TO_INVENTORY=/tmp/inv.json TO_RANK_OUT=/tmp/out.json sh rank.sh

set -e

SCRIPT_DIR=$(dirname "$0")

if [ -n "${TO_CENSUS:-}" ]; then
  CENSUS=$(cat "$TO_CENSUS")
else
  CENSUS=$(sh "$SCRIPT_DIR/census.sh")
fi

INV_PATH="${TO_INVENTORY:-.claude/tool-optimizer.local.json}"
if [ ! -f "$INV_PATH" ]; then
  printf 'rank: inventory not found at %s (run detect.sh first)\n' "$INV_PATH" >&2
  exit 1
fi
INV=$(cat "$INV_PATH")

MERGED=$(jq -n --argjson c "$CENSUS" --argjson inv "$INV" '
  # thresholds (the prototype constants)
  50 as $SRC_HIGH | 10 as $SRC_MED | 200 as $REPO_LARGE | 50 as $REPO_MED
  | 3 as $DOCS_HIGH | 3 as $TAB_HIGH

  # GEN split for the global (no-codebase) case
  | { "ripgrep":1, "ast-grep":1, "repomix":1, "files-to-prompt":1, "universal-ctags":1, "rtk":1 } as $gencore
  | {
      "ripgrep":"universal — every project needs text search",
      "ast-grep":"useful wherever there is source code",
      "semgrep":"only if you do security/taint review",
      "repomix":"useful on larger trees",
      "files-to-prompt":"useful for packing file subsets",
      "markitdown":"only if you handle Office/web docs",
      "duckdb":"only if you handle CSV/Excel/Parquet",
      "qsv":"only if you handle CSV",
      "universal-ctags":"useful on larger source repos",
      "rtk":"harness output compression — any project"
    } as $genev

  # rank weight for ordering recommendations (lower = recommend sooner)
  | { "HIGH":0, "MED":1, "GEN":2, "GEN-core":2, "LOW":3, "NA":4, "GEN-conditional":5 } as $weight

  # evidence helper: top-3 languages as "n lang", or "no source"
  | (if ($c.by_lang | length) == 0 then "no source"
     else ($c.by_lang[0:3] | map("\(.n) \(.lang)") | join(", ")) end) as $langs

  # per-tool verdict {relevance, evidence}
  | def verdict($t):
      if $c.is_global then
        ( if $gencore[$t] then "GEN-core" else "GEN-conditional" end ) as $rel
        | {relevance: $rel, evidence: ($genev[$t] // "generic")}

      elif $t == "ripgrep" then
        {relevance: "GEN", evidence: "universal — every repo needs text search"}
      elif $t == "rtk" then
        {relevance: "GEN", evidence: "output compression — environment-level, any project"}

      elif $t == "ast-grep" then
        ($c.total_source) as $s
        | if   $s >= $SRC_HIGH then {relevance:"HIGH", evidence:"\($langs) → structural search/rewrite pays off"}
          elif $s >= $SRC_MED  then {relevance:"MED",  evidence:"\($langs) → some structural value"}
          elif $s > 0          then {relevance:"LOW",  evidence:"only \($s) source files → marginal"}
          else                      {relevance:"NA",   evidence:"0 source files → not relevant here"} end

      elif $t == "semgrep" then
        ($c.security_source) as $sec
        | if   $sec >= $SRC_HIGH then {relevance:"MED", evidence:"\($sec) security-relevant source → taint/dataflow available"}
          elif $sec > 0          then {relevance:"LOW", evidence:"\($sec) security-relevant source → only if you need taint"}
          else                        {relevance:"NA",  evidence:"no security-relevant source → not needed here"} end

      elif $t == "repomix" then
        if   ($c.total_files >= $REPO_LARGE or $c.monorepo) then
              (if $c.monorepo then "monorepo" else "\($c.total_files) files" end) as $tag
              | {relevance:"HIGH", evidence:"\($tag) → whole-tree packing pays off"}
        elif $c.total_files >= $REPO_MED then {relevance:"MED", evidence:"\($c.total_files) files → packing helps"}
        else {relevance:"LOW", evidence:"\($c.total_files) files → just Read them"} end

      elif $t == "files-to-prompt" then
        if ($c.total_files >= $REPO_MED or $c.monorepo)
        then {relevance:"MED", evidence:"complements repomix for explicit file subsets"}
        else {relevance:"LOW", evidence:"\($c.total_files) files → native Read is enough"} end

      elif $t == "markitdown" then
        if   $c.docs >= $DOCS_HIGH then {relevance:"HIGH", evidence:"\($c.docs) Office/web docs → convert to Markdown"}
        elif $c.docs > 0           then {relevance:"MED",  evidence:"\($c.docs) Office/web doc(s) → handy"}
        else                            {relevance:"NA",   evidence:"0 Office/web docs → not needed here"} end

      elif $t == "duckdb" then
        if   $c.tabular >= $TAB_HIGH then {relevance:"HIGH", evidence:"\($c.tabular) tabular files → query, don'"'"'t load"}
        elif $c.tabular > 0          then {relevance:"MED",  evidence:"\($c.tabular) tabular file(s) → query helps"}
        else                              {relevance:"NA",   evidence:"0 tabular files → not needed here"} end

      elif $t == "qsv" then
        if $c.tabular > 0 then {relevance:"MED", evidence:"\($c.tabular) tabular file(s) → quick CSV stats/slice"}
        else {relevance:"NA", evidence:"0 tabular files → not needed here"} end

      elif $t == "universal-ctags" then
        ($c.total_source) as $s
        | if   ($s >= $SRC_HIGH and $c.total_files >= $REPO_MED) then {relevance:"HIGH", evidence:"\($s) source files → symbol index beats re-scanning"}
          elif $s >= $SRC_MED then {relevance:"MED", evidence:"\($s) source files → index may help"}
          else {relevance:"NA", evidence:"only \($s) source files → re-scan is fine"} end

      else {relevance:"NA", evidence:"unknown tool"}
      end;

  # tools = inventory values carrying an `available` field, alphabetical, none omitted
  ( $inv | to_entries
    | map(select(.value | type == "object" and has("available")))
    | sort_by(.key) ) as $tools

  | ( $tools | map(
        .key as $t | .value as $v
        | verdict($t) as $vd
        | ($v.available == true) as $avail
        | {
            tool: $t,
            category: ($v.category // "unknown"),
            available: $avail,
            relevance: $vd.relevance,
            evidence: $vd.evidence,
            recommend: ((($avail | not)) and ($vd.relevance as $r | ($r=="HIGH" or $r=="MED" or $r=="GEN" or $r=="GEN-core"))),
            unneeded:  ($avail and ($vd.relevance as $r | ($r=="NA" or $r=="LOW")))
          }
      ) ) as $relevance

  | ( $relevance | map(select(.recommend))
        | sort_by([ $weight[.relevance], .tool ])
        | map({tool, relevance}) ) as $recommendOrder

  | $inv + { census: $c, relevance: $relevance, recommendOrder: $recommendOrder }
')

OUT="${TO_RANK_OUT:-$INV_PATH}"
mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$MERGED" > "$OUT"
