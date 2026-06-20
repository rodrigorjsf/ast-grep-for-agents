#!/usr/bin/env bash
# WHAT: Generate small binary office/PDF fixtures (each a heading + a 3-row table)
#       and convert each to Markdown with MarkItDown, printing raw-bytes vs
#       md-bytes vs ~md-tokens and whether the table survived as Markdown pipes.
#       Used in docs/tools/markitdown.md and the pdf-skill section.
# WHY:  An agent cannot read a .docx/.pptx/.xlsx/.pdf -- they are binary (zip/PDF
#       streams). The win is turning them into compact, table-preserving Markdown
#       in one step. This encodes the byte ratio and the table-fidelity check so
#       they are not re-derived. Fixtures are generated in-script (gitignored).
# WHEN: Run to (re)confirm the doc->md claims after upgrading MarkItDown or the
#       fixture libraries.
# HOW:  scripts/bench-docs.sh   (needs markitdown on PATH; python-docx/python-pptx/
#       openpyxl/fpdf2 make the fixtures -- a format whose lib is absent is
#       skipped, and markitdown absent -> chapters stay [sourced].)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d .venv/bin ] && export PATH="$PWD/.venv/bin:$PATH"
mkdir -p examples/bench

# Each fixture: same "Quarterly Report" heading + a small table, so the four
# formats are comparable. A missing writer lib skips only that one format.
python3 - <<'PY'
B = "examples/bench"
ROWS = [("North", "120", "$4,800"), ("South", "98", "$3,920"), ("East", "75", "$3,000")]
HEAD = ("Region", "Units", "Revenue")

try:
    from docx import Document
    d = Document(); d.add_heading("Quarterly Report", level=1)
    d.add_paragraph("Regional sales summary for Q1.")
    t = d.add_table(rows=1, cols=3)
    for i, h in enumerate(HEAD): t.rows[0].cells[i].text = h
    for r in ROWS:
        c = t.add_row().cells
        for i, v in enumerate(r): c[i].text = v
    d.save(f"{B}/sample.docx")
except Exception as e: print("skip docx:", e)

try:
    from pptx import Presentation
    from pptx.util import Inches
    p = Presentation(); s = p.slides.add_slide(p.slide_layouts[5])
    s.shapes.title.text = "Quarterly Report"
    tbl = s.shapes.add_table(4, 3, Inches(1), Inches(1.5), Inches(6), Inches(2)).table
    for c, h in enumerate(HEAD): tbl.cell(0, c).text = h
    for r, row in enumerate(ROWS, start=1):
        for c, v in enumerate(row): tbl.cell(r, c).text = v
    p.save(f"{B}/sample.pptx")
except Exception as e: print("skip pptx:", e)

try:
    from openpyxl import Workbook
    wb = Workbook(); ws = wb.active; ws.title = "Q1"
    ws.append(list(HEAD))
    for r in ROWS: ws.append(list(r))
    wb.save(f"{B}/sample.xlsx")
except Exception as e: print("skip xlsx:", e)

try:
    from fpdf import FPDF
    pdf = FPDF(); pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, "Quarterly Report", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", size=11)
    pdf.cell(0, 8, "Regional sales summary for Q1.", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(3)
    for region, _u, rev in [HEAD] + ROWS:
        pdf.cell(45, 8, region, border=1)
        pdf.cell(45, 8, rev, border=1, new_x="LMARGIN", new_y="NEXT")
    pdf.output(f"{B}/sample.pdf")
except Exception as e: print("skip pdf:", e)
PY

command -v markitdown >/dev/null || {
  echo "markitdown not on PATH -- skipping (docs/tools/markitdown.md stays [sourced])."
  echo "Install: pip install 'markitdown[all]'"
  exit 0
}

echo "=== doc -> markdown (binary document into LLM-readable text) ==="
printf "%-6s %10s %10s %12s %10s %12s\n" "format" "raw bytes" "md bytes" "~md tokens" "md vs raw" "table pipes?"
for ext in docx pptx xlsx pdf; do
  src="examples/bench/sample.$ext"
  [ -f "$src" ] || continue
  raw=$(wc -c < "$src")
  md=$(markitdown "$src" 2>/dev/null) || md=""
  mdb=$(printf '%s' "$md" | wc -c)
  pipes=$(printf '%s' "$md" | grep -c '|' || true)
  if [ "$pipes" -gt 0 ]; then tp="yes($pipes)"; else tp="no"; fi
  printf "%-6s %10d %10d %12d %9d%% %12s\n" "$ext" "$raw" "$mdb" "$((mdb/4))" "$(( raw ? mdb*100/raw : 0 ))" "$tp"
done
echo
echo "Takeaway: MarkItDown turns an unreadable binary into compact Markdown the"
echo "model can actually read -- and the table survives as | pipes |, so the agent"
echo "sees structure, not a flattened wall of cells. The PDF row is the same path"
echo "the Claude 'pdf' skill takes in-harness (structure-aware PDF -> Markdown)."
