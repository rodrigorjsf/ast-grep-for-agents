#!/bin/sh
# WHAT: Censuses the project from `git ls-files` into deterministic, bucketed counts.
# WHY:  The bootstrap ranks every tool's Relevance to THIS codebase from
#       evidence (counts), never from novelty. The census is that evidence: source by
#       language, tabular, binary docs, notebooks, build files, repo size, monorepo
#       markers. Cheap + deterministic: it reads the tracked-file LIST only — no
#       full-tree walk, no file contents, no stat.
# WHEN: Run as the first half of the bootstrap's relevance pass, before rank.sh.
#       Order: detect.sh (availability) -> census.sh (this) -> rank.sh (verdicts).
# HOW:  Injectable env vars (all optional):
#         TO_PATHS       read the newline-delimited path list from this file instead of
#                        running `git ls-files` (seam tests feed fixtures this way).
#         TO_CENSUS_OUT  write the census JSON to this file instead of stdout.
#       Output: census JSON (stdout, or TO_CENSUS_OUT). Empty path list -> is_global=true.
#       Requires jq (a batch-script dependency, like detect/render/resolve; not the
#       SessionStart hot path). by_lang is sorted count-desc then name-asc; build_files
#       sorted; so two runs over the same tree are byte-identical.
#
#       Shell (.sh) is deliberately NOT counted as source — the LANG_EXT set below
#       excludes it; adding it would shift the relevance verdicts (the rank.seam.sh
#       fixtures pin the expected counts, so changing the buckets fails that seam).
#
#       Usage:
#         sh census.sh
#         TO_PATHS=/tmp/paths.txt sh census.sh
#         TO_CENSUS_OUT=/tmp/census.json sh census.sh

set -e

if [ -n "${TO_PATHS:-}" ]; then
  PATH_LIST=$(cat "$TO_PATHS")
else
  PATH_LIST=$(git ls-files 2>/dev/null || true)
fi

CENSUS=$(printf '%s' "$PATH_LIST" | jq -R -s '
  # ---- bucket maps (the validated prototype set; mirror exactly) ----
  {
    ".java":"java", ".kt":"java", ".py":"python", ".go":"go",
    ".js":"js/ts", ".jsx":"js/ts", ".ts":"js/ts", ".tsx":"js/ts",
    ".mjs":"js/ts", ".cjs":"js/ts",
    ".rs":"rust",
    ".c":"c/cpp", ".cc":"c/cpp", ".cpp":"c/cpp", ".cxx":"c/cpp",
    ".h":"c/cpp", ".hpp":"c/cpp",
    ".rb":"ruby"
  } as $lang
  # security_source sums these langs only — rust is source but NOT security-relevant here
  | { "java":1, "python":1, "js/ts":1, "go":1, "c/cpp":1, "ruby":1 } as $sec
  | { ".csv":1, ".tsv":1, ".parquet":1, ".xlsx":1, ".xls":1 } as $tab
  | { ".docx":1, ".pptx":1, ".pdf":1, ".epub":1, ".html":1, ".htm":1 } as $doc
  | { ".ipynb":1 } as $nb
  | {
      "pom.xml":1, "build.gradle":1, "build.gradle.kts":1, "pyproject.toml":1,
      "requirements.txt":1, "setup.py":1, "go.mod":1, "package.json":1,
      "Cargo.toml":1, "Gemfile":1
    } as $bf
  | ["packages/", "apps/", "services/", "libs/"] as $mono
  # ---- classify each path ----
  | (split("\n") | map(select(length > 0))) as $paths
  | ($paths | length) as $total
  | ($paths | map(
        . as $p
        | ($p | split("/") | last) as $base
        | ($base | rindex(".")) as $li
        # mirror Python os.path.splitext: leading dot / no dot => no extension
        | (if ($li == null or $li == 0) then "" else ($base[$li:] | ascii_downcase) end) as $ext
        | {base: $base, ext: $ext}
      )) as $cls
  | ($cls | map(.ext) | map($lang[.]) | map(select(. != null))
        | group_by(.) | map({lang: .[0], n: length})
        | sort_by([(-.n), .lang])) as $bylang
  | {
      total_files: $total,
      total_source: ($bylang | map(.n) | add // 0),
      security_source: ($bylang | map(select(.lang as $l | $sec[$l]) | .n) | add // 0),
      by_lang: $bylang,
      tabular: ($cls | map(select(.ext as $e | $tab[$e])) | length),
      docs: ($cls | map(select(.ext as $e | $doc[$e])) | length),
      notebooks: ($cls | map(select(.ext as $e | $nb[$e])) | length),
      build_files: ($cls | map(.base) | map(select($bf[.])) | unique),
      monorepo: (
        ($paths | any(. as $p | $mono | any(. as $d | ($p | startswith($d)) or ($p | contains("/" + $d)))))
        or (($cls | map(.base) | map(select($bf[.])) | unique | length) > 1)
      ),
      is_global: ($total == 0)
    }
')

if [ -n "${TO_CENSUS_OUT:-}" ]; then
  mkdir -p "$(dirname "$TO_CENSUS_OUT")"
  printf '%s\n' "$CENSUS" > "$TO_CENSUS_OUT"
else
  printf '%s\n' "$CENSUS"
fi
