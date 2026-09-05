"""Print a Markdown brief to PDF via Chrome (charts as embedded images).

Requires the ``markdown`` package (not a project dep). Chrome or Chromium
must be installed.

Examples::

    uv run --with markdown python scripts/md_to_pdf.py
    uv run --with markdown python scripts/md_to_pdf.py --input final.md --output final.pdf
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.paths import ROOT

try:
    import markdown
except ImportError as exc:
    raise SystemExit(
        "This script needs the markdown package. Run:\n"
        "  uv run --with markdown python scripts/md_to_pdf.py"
    ) from exc

CHROME_CANDIDATES = (
    Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
    Path("/usr/bin/google-chrome"),
    Path("/usr/bin/chromium"),
    Path("/usr/bin/chromium-browser"),
)

CSS = """
@page { size: letter; margin: 0.62in 0.7in 0.62in 0.7in; }
html, body {
  margin: 0; padding: 0; color: #1a1a1a; background: #fff;
  font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
  font-size: 10.4pt; line-height: 1.42;
}
h1 {
  margin: 0 0 0.2em; color: #3D6B00; font-size: 21pt; font-weight: 700;
  letter-spacing: -0.02em; line-height: 1.12;
}
h1 + p { margin-top: 0; color: #5c5c5c; font-size: 11pt; }
h2 {
  margin: 1.15em 0 0.38em; color: #1a1a1a; font-size: 13pt; font-weight: 700;
  letter-spacing: -0.01em; page-break-after: avoid;
}
p { margin: 0 0 0.65em; }
strong { font-weight: 650; }
ul, ol { margin: 0 0 0.75em; padding-left: 1.2em; }
li { margin: 0.15em 0; }
code {
  font-family: "SF Mono", Menlo, Consolas, monospace;
  font-size: 7.7pt;
  background: #f4f4f4;
  padding: 0.05em 0.22em;
  font-variant-ligatures: none;
  font-feature-settings: "liga" 0, "calt" 0;
  word-break: break-all;
}
figure {
  margin: 0.7em 0 0.85em;
  page-break-inside: avoid;
  break-inside: avoid;
}
img {
  display: block; width: 100%; height: auto;
  max-height: 3.2in;
  object-fit: contain;
  object-position: left center;
}
table {
  border-collapse: collapse;
  width: 100%;
  margin: 0.45em 0 0.85em;
  font-size: 8.2pt;
  line-height: 1.32;
  table-layout: fixed;
  page-break-inside: avoid;
  break-inside: avoid;
}
thead th {
  background: #f0f0f0;
  font-weight: 650;
  vertical-align: bottom;
}
th, td {
  border: 1px solid #bbb;
  padding: 0.32em 0.4em;
  vertical-align: top;
  text-align: left;
  word-wrap: break-word;
  overflow-wrap: anywhere;
  hyphens: auto;
}
/* Narrow first column for numbered / workload labels */
table th:first-child,
table td:first-child {
  width: 14%;
}
"""


def find_chrome() -> Path:
    for path in CHROME_CANDIDATES:
        if path.is_file():
            return path
    raise SystemExit(
        "Chrome/Chromium not found. Install Google Chrome or pass --chrome."
    )


def abs_img(match: re.Match[str], md_dir: Path, root: Path) -> str:
    alt, src = match.group(1), match.group(2)
    path = Path(src)
    if not path.is_absolute():
        candidates = [(md_dir / src).resolve(), (root / src).resolve()]
        path = next((p for p in candidates if p.is_file()), None)
        if path is None:
            tried = ", ".join(str(p) for p in candidates)
            raise SystemExit(f"Image not found: {src} (tried {tried})")
    elif not path.is_file():
        raise SystemExit(f"Image not found: {path}")
    return f"![{alt}]({path.as_uri()})"


def markdown_to_html(md_text: str, *, md_dir: Path, root: Path) -> str:
    md_text = re.sub(
        r"!\[([^\]]*)\]\(([^)]+)\)",
        lambda m: abs_img(m, md_dir, root),
        md_text,
    )
    body = markdown.markdown(md_text, extensions=["extra", "sane_lists"])
    body = re.sub(r"<p>(<img[^>]+>)</p>", r"<figure>\1</figure>", body)
    body = re.sub(
        r"<code>(.*?)</code>",
        lambda m: "<code>"
        + m.group(1).replace("\u2013", "--").replace("\u2014", "--")
        + "</code>",
        body,
        flags=re.S,
    )
    return (
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
        '<meta charset="utf-8"/>\n'
        "<title>Daytona Sandbox Compute — Chip Evaluation Summary</title>\n"
        f"<style>{CSS}</style>\n</head>\n<body>\n{body}\n</body>\n</html>\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a Markdown brief (with relative images) to PDF"
    )
    parser.add_argument(
        "--input",
        default="final.md",
        help="Markdown path relative to the repo root (default: final.md)",
    )
    parser.add_argument(
        "--output",
        default="final.pdf",
        help="PDF path relative to the repo root (default: final.pdf)",
    )
    parser.add_argument(
        "--chrome",
        default=None,
        help="Path to Google Chrome or Chromium (auto-detected if omitted)",
    )
    args = parser.parse_args()

    md_path = Path(args.input)
    pdf_path = Path(args.output)
    if not md_path.is_absolute():
        md_path = ROOT / md_path
    if not pdf_path.is_absolute():
        pdf_path = ROOT / pdf_path
    if not md_path.is_file():
        raise SystemExit(f"Markdown not found: {md_path}")

    html_doc = markdown_to_html(
        md_path.read_text(encoding="utf-8"), md_dir=md_path.parent, root=ROOT
    )
    html_path = Path("/tmp/vera-zen5-brief.html")
    html_path.write_text(html_doc, encoding="utf-8")

    chrome = Path(args.chrome) if args.chrome else find_chrome()
    tmp_pdf = pdf_path.with_suffix(pdf_path.suffix + ".tmp")
    subprocess.run(
        [
            str(chrome),
            "--headless=new",
            "--disable-gpu",
            "--no-pdf-header-footer",
            f"--print-to-pdf={tmp_pdf}",
            "--virtual-time-budget=15000",
            html_path.as_uri(),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    tmp_pdf.replace(pdf_path)
    print(f"wrote {pdf_path} ({pdf_path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
