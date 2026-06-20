#!/usr/bin/env bash
# WHAT: Generate a deterministic ~100k-row sales.csv (+ a small sales.xlsx) and
#       print a comparison table: reading the whole CSV into context vs running a
#       GROUP BY aggregate with DuckDB / qsv and getting back only the answer.
#       Tokens are estimated at ~bytes/4. Used in docs/tools/{duckdb,qsv}.md.
# WHY:  The agent-relevant win for tabular data is "query, don't read": a 100k-row
#       file is megabytes, but the aggregate answer is a handful of rows. This
#       script encodes that ratio and the xlsx-without-Excel capability so they are
#       not re-derived. The CSV is generated in-script (never committed) to keep
#       the repo light -- same discipline as bench-tokens.sh's Java fixtures.
# WHEN: Run to (re)confirm the tabular claims after upgrading DuckDB/qsv or
#       changing the row count (ROWS=NNN scripts/bench-tabular.sh).
# HOW:  scripts/bench-tabular.sh    (needs duckdb and/or qsv on PATH; absent tools
#       are skipped and their chapter stays [sourced]. python3 + openpyxl make the
#       xlsx; if openpyxl is absent the xlsx rows are skipped.)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d .venv/bin ] && export PATH="$PWD/.venv/bin:$PATH"

CSV=examples/bench/sales.csv
XLSX=examples/bench/sales.xlsx
ROWS=${ROWS:-100000}
mkdir -p examples/bench
# qsv stats drops a *.stats.* cache next to the CSV; a stale one breaks a later
# `qsv frequency`. Remove any from a prior run up front and on exit.
rm -f examples/bench/sales.stats.*
trap 'rm -f examples/bench/sales.stats.*' EXIT

# Deterministic fixture: 4 regions, amount/ts a pure function of the row index
# (no randomness -> byte-stable output run to run). 100k rows ~ a few MB of CSV.
python3 - "$CSV" "$ROWS" <<'PY'
import sys
path, rows = sys.argv[1], int(sys.argv[2])
regions = ["north", "south", "east", "west"]
with open(path, "w") as f:
    f.write("id,region,amount,ts\n")
    for i in range(rows):
        region = regions[i % 4]
        amount = (i * 37 % 1000) + (i % 7) * 0.5
        ts = "2026-01-%02dT%02d:%02d:%02d" % (i % 28 + 1, i // 3600 % 24, i // 60 % 60, i % 60)
        f.write("%d,%s,%.2f,%s\n" % (i, region, amount, ts))
PY

# Small xlsx (5k-row subset) for the "query Excel without Excel" demo.
XLSX_OK=0
if python3 - "$CSV" "$XLSX" <<'PY' 2>/dev/null
import sys, csv
try:
    from openpyxl import Workbook
except ImportError:
    sys.exit(1)
src, dst = sys.argv[1], sys.argv[2]
wb = Workbook(write_only=True); ws = wb.create_sheet("sales")
with open(src) as f:
    r = csv.reader(f)
    ws.append(next(r))                       # header row
    for n, row in enumerate(r):
        if n >= 5000: break
        # Write typed values so read_xlsx infers BIGINT/DOUBLE and SUM() works
        # (write_only + raw strings would land everything as text -> sum fails).
        ws.append([int(row[0]), row[1], float(row[2]), row[3]])
wb.save(dst)
PY
then XLSX_OK=1; fi

full=$(wc -c < "$CSV")
cnt() { local n; n=$("$@" 2>/dev/null | wc -c) || n=0; printf '%s' "$n"; }
row() { printf "%-36s %8d   %7d        %3d%%\n" "$1" "$2" "$(( $2 / 4 ))" "$(( full ? $2 * 100 / full : 0 ))"; }

Q="SELECT region, sum(amount) AS total, count(*) AS n FROM '$CSV' GROUP BY region ORDER BY region"
echo "=== tabular query (aggregate $ROWS rows -> small answer) ==="
echo "approach                              bytes   ~tokens(/4)   vs full"
printf "%-36s %8d   %7d        100%%\n" "read whole sales.csv (no tool)" "$full" "$((full/4))"

if command -v duckdb >/dev/null; then
  row "duckdb GROUP BY (table)" "$(cnt duckdb -c "$Q")"
  row "duckdb GROUP BY (-json)" "$(cnt duckdb -json -c "$Q")"
  row "duckdb DESCRIBE schema" "$(cnt duckdb -c "DESCRIBE SELECT * FROM '$CSV'")"
fi
if command -v qsv >/dev/null; then
  # --cache-threshold 0: don't write a stats cache next to the CSV. The cache
  # confuses a later `qsv frequency` ("missing field cardinality") and litters
  # examples/bench/ with sales.stats.* files.
  row "qsv stats" "$(cnt qsv stats --cache-threshold 0 "$CSV")"
  row "qsv count" "$(cnt qsv count "$CSV")"
  row "qsv slice -l 20" "$(cnt qsv slice -l 20 "$CSV")"
  # qsv's group-by-aggregate. `qsv sqlp` (Polars SQL, arbitrary GROUP BY/SUM) needs
  # a polars-enabled build; the brew "all_features" binary here does NOT ship it,
  # so we use `frequency` (per-value counts) -- for SUM/JOIN/window SQL, use DuckDB.
  if qsv sqlp --help >/dev/null 2>&1; then
    row "qsv sqlp GROUP BY (polars)" "$(cnt qsv sqlp "$CSV" "SELECT region, sum(amount) AS total, count(*) AS n FROM _t_1 GROUP BY region ORDER BY region")"
  else
    row "qsv frequency (per-region count)" "$(cnt qsv frequency --select region "$CSV")"
  fi
fi
echo

if [ "$XLSX_OK" = "1" ]; then
  echo "=== xlsx without Excel (offline; first DuckDB run fetches the excel ext once) ==="
  echo "approach                              bytes   ~tokens(/4)   vs full"
  xfull=$(wc -c < "$XLSX")
  printf "%-36s %8d   %7d        100%%\n" "raw sales.xlsx (binary, 5k rows)" "$xfull" "$((xfull/4))"
  fullx=$full
  if command -v duckdb >/dev/null; then
    QX="SELECT region, sum(amount) AS total, count(*) AS n FROM read_xlsx('$XLSX') GROUP BY region ORDER BY region"
    n=$(duckdb -c "INSTALL excel; LOAD excel; $QX" 2>/dev/null | wc -c) || n=0
    full=$xfull; row "duckdb read_xlsx GROUP BY" "$n"; full=$fullx
  fi
  if command -v qsv >/dev/null; then
    full=$xfull; row "qsv excel (xlsx -> csv)" "$(cnt qsv excel "$XLSX")"; full=$fullx
  fi
  echo
else
  echo "(xlsx rows skipped -- openpyxl not installed: pip install openpyxl)"
fi
echo "Takeaway: a GROUP BY answer is a few rows -- orders of magnitude smaller than"
echo "the whole CSV. Query the file, don't read it into context. DuckDB and qsv both"
echo "do this offline; DuckDB also reads .xlsx directly (no Excel, no conversion)."
