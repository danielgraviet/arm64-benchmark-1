#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["fpdf2>=2.8"]
# ///
"""Render the Ivan markdown share-out to PDF.

Same converter used for the original Vera vs 9575F Ivan PDF
(vera-final/scripts/ivan_doc_to_pdf.py).

Rerun after doc or chart updates:

    python3 daniel-focus-here/ivan_doc_to_pdf.py

Optional:

    python3 daniel-focus-here/ivan_doc_to_pdf.py --open
    python3 daniel-focus-here/ivan_doc_to_pdf.py path/to.md -o path/to.pdf
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

FOCUS = Path(__file__).resolve().parent
DEFAULT_MD = FOCUS / "docs" / "updated-ivan-doc-9755.md"
DEFAULT_PDF = FOCUS / "docs" / "updated-ivan-doc-9755.pdf"

GREEN = (118, 185, 0)
DARK = (32, 33, 36)
MUTED = (111, 113, 119)

IMAGE_RE = re.compile(r"^!\[([^\]]*)\]\(([^)]+)\)\s*$")
HEADING_RE = re.compile(r"^(#{1,3})\s+(.*)$")
OL_RE = re.compile(r"^(\d+)\.\s+(.*)$")
INLINE_RE = re.compile(r"(\*\*[^*]+?\*\*|`[^`]+`)")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$")


def ensure_fpdf() -> None:
    try:
        import fpdf  # noqa: F401
        return
    except ImportError:
        pass
    extra = [arg for arg in sys.argv[1:] if arg != "--bootstrap"]
    if shutil.which("uv"):
        os.execvp(
            "uv",
            ["uv", "run", "--with", "fpdf2", str(Path(__file__).resolve()), *extra],
        )
    subprocess.check_call([sys.executable, "-m", "pip", "install", "fpdf2"])


ensure_fpdf()

from fpdf import FPDF  # noqa: E402


FONT_REGULAR = [
    Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
    Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    Path("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"),
]
FONT_BOLD = [
    Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"),
    Path("/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"),
]


def first_existing(paths: list[Path]) -> Path | None:
    for path in paths:
        if path.is_file():
            return path
    return None


def image_size(path: Path) -> tuple[int, int]:
    try:
        from PIL import Image

        with Image.open(path) as image:
            return image.size
    except Exception:
        return (1600, 750)


class IvanPDF(FPDF):
    def footer(self) -> None:
        self.set_y(-14)
        self.set_font("Body", size=8)
        self.set_text_color(*MUTED)
        self.cell(0, 8, f"{self.page_no()}", align="C")


def write_fit(pdf: FPDF, text: str, leading: float) -> None:
    """Wrap before a fragment that would otherwise split mid-token."""
    if not text:
        return
    width = pdf.get_string_width(text)
    remaining = pdf.w - pdf.r_margin - pdf.get_x()
    if width > remaining and pdf.get_x() > pdf.l_margin + 0.5:
        pdf.ln(leading)
    pdf.write(leading, text)


def write_rich(pdf: FPDF, text: str, *, size: float, leading: float) -> None:
    pdf.set_font("Body", size=size)
    pdf.set_text_color(*DARK)
    for raw_line in text.split("\n"):
        parts = INLINE_RE.split(raw_line)
        if not parts:
            pdf.ln(leading)
            continue
        for part in parts:
            if not part:
                continue
            if part.startswith("**") and part.endswith("**"):
                pdf.set_font("Body", style="B", size=size)
                pdf.write(leading, part[2:-2])
                pdf.set_font("Body", size=size)
            elif part.startswith("`") and part.endswith("`"):
                pdf.set_font("Body", size=size)
                token = part[1:-1]
                # Write in pieces so a long path can wrap after / or _.
                pieces = re.split(r"([/_ ])", token)
                buf = ""
                for piece in pieces:
                    buf += piece
                    if piece in "/_ ":
                        write_fit(pdf, buf, leading)
                        buf = ""
                if buf:
                    write_fit(pdf, buf, leading)
            else:
                pdf.set_font("Body", size=size)
                pdf.write(leading, part)
        pdf.ln(leading)


def add_image(pdf: FPDF, path: Path) -> None:
    remaining = pdf.h - pdf.b_margin - pdf.get_y() - 4
    max_w = pdf.epw
    page_cap = min(78.0, pdf.eph * 0.36)
    if remaining < 48:
        pdf.add_page()
        remaining = pdf.h - pdf.b_margin - pdf.get_y() - 4
    max_h = min(page_cap, remaining)
    width_px, height_px = image_size(path)
    aspect = height_px / width_px if width_px else 0.5
    draw_w = max_w
    draw_h = draw_w * aspect
    if draw_h > max_h:
        draw_h = max_h
        draw_w = draw_h / aspect
    x = pdf.l_margin + (pdf.epw - draw_w) / 2
    y = pdf.get_y()
    pdf.image(str(path), x=x, y=y, w=draw_w, h=draw_h)
    pdf.set_xy(pdf.l_margin, y + draw_h + 3)


def split_table_row(line: str) -> list[str]:
    inner = line.strip()
    if inner.startswith("|"):
        inner = inner[1:]
    if inner.endswith("|"):
        inner = inner[:-1]
    return [cell.strip() for cell in inner.split("|")]


def iter_blocks(markdown: str) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []
    paragraph: list[str] = []
    list_items: list[str] = []
    table_rows: list[list[str]] = []

    def flush_paragraph() -> None:
        nonlocal paragraph
        if paragraph:
            blocks.append(("p", " ".join(paragraph)))
            paragraph = []

    def flush_list() -> None:
        nonlocal list_items
        if list_items:
            blocks.append(("ol", "\n".join(list_items)))
            list_items = []

    def flush_table() -> None:
        nonlocal table_rows
        if table_rows:
            blocks.append(("table", "\n".join("\t".join(cells) for cells in table_rows)))
            table_rows = []

    for raw in markdown.splitlines():
        hard_break = raw.endswith("  ")
        line = raw.rstrip()
        if not line:
            flush_paragraph()
            flush_list()
            flush_table()
            continue
        heading = HEADING_RE.match(line)
        image = IMAGE_RE.match(line)
        ordered = OL_RE.match(line)
        is_table = line.lstrip().startswith("|")
        if heading:
            flush_paragraph()
            flush_list()
            flush_table()
            blocks.append((f"h{len(heading.group(1))}", heading.group(2).strip()))
        elif image:
            flush_paragraph()
            flush_list()
            flush_table()
            blocks.append(("img", image.group(2).strip()))
        elif is_table:
            flush_paragraph()
            flush_list()
            if not TABLE_SEP_RE.match(line):
                table_rows.append(split_table_row(line))
        elif ordered:
            flush_paragraph()
            flush_table()
            list_items.append(ordered.group(2).strip())
        else:
            flush_list()
            flush_table()
            paragraph.append(line)
            if hard_break:
                flush_paragraph()
    flush_paragraph()
    flush_list()
    flush_table()
    return blocks


def first_h1(markdown: str) -> str:
    for raw in markdown.splitlines():
        heading = HEADING_RE.match(raw.strip())
        if heading and len(heading.group(1)) == 1:
            return heading.group(2).strip()
    return "Daytona"


def render(md_path: Path, pdf_path: Path) -> None:
    regular = first_existing(FONT_REGULAR)
    bold = first_existing(FONT_BOLD)
    if regular is None:
        raise SystemExit("No Unicode TTF found. Install Arial or DejaVu Sans.")

    markdown = md_path.read_text(encoding="utf-8")
    pdf = IvanPDF(format="Letter", unit="mm")
    pdf.set_auto_page_break(auto=True, margin=18)
    pdf.set_margins(18, 16, 18)
    pdf.add_font("Body", fname=str(regular))
    pdf.add_font("Body", style="B", fname=str(bold or regular))
    pdf.set_title(first_h1(markdown))
    pdf.set_author("Daytona")
    pdf.add_page()

    for kind, value in iter_blocks(markdown):
        if kind == "h1":
            pdf.set_font("Body", style="B", size=20)
            pdf.set_text_color(*GREEN)
            pdf.multi_cell(0, 8, value)
            pdf.ln(2)
        elif kind == "h2":
            pdf.ln(2)
            pdf.set_font("Body", style="B", size=13)
            pdf.set_text_color(*DARK)
            pdf.multi_cell(0, 7, value)
            pdf.ln(1)
        elif kind == "h3":
            pdf.ln(2)
            pdf.set_font("Body", style="B", size=11.5)
            pdf.set_text_color(*DARK)
            pdf.multi_cell(0, 6.5, value)
            pdf.ln(1)
        elif kind == "p":
            is_kicker = pdf.page_no() == 1 and pdf.get_y() < 42 and len(value) < 100
            if is_kicker:
                pdf.set_font("Body", size=10.5)
                pdf.set_text_color(*MUTED)
                pdf.multi_cell(0, 6, value)
                pdf.ln(0.6)
            else:
                write_rich(pdf, value, size=11, leading=6.2)
                pdf.ln(1.8)
        elif kind == "ol":
            for index, item in enumerate(value.split("\n"), start=1):
                x = pdf.l_margin
                y = pdf.get_y()
                pdf.set_font("Body", style="B", size=11)
                pdf.set_text_color(*GREEN)
                pdf.set_xy(x, y)
                pdf.cell(8, 6.2, f"{index}.")
                pdf.set_xy(x + 8, y)
                write_rich(pdf, item, size=11, leading=6.2)
            pdf.ln(2)
        elif kind == "table":
            rows = [line.split("\t") for line in value.split("\n")]
            width_count = max(len(row) for row in rows)
            padded = [row + [""] * (width_count - len(row)) for row in rows]
            first = 0.42 if width_count > 1 else 1.0
            rest = (1.0 - first) / (width_count - 1) if width_count > 1 else 0.0
            col_widths = (first, *([rest] * (width_count - 1)))
            pdf.set_font("Body", size=9)
            pdf.set_text_color(*DARK)
            with pdf.table(
                width=pdf.epw,
                col_widths=col_widths,
                text_align="LEFT",
                line_height=5.4,
                first_row_as_headings=True,
            ) as table:
                for data_row in padded:
                    row = table.row()
                    for datum in data_row:
                        row.cell(datum)
            pdf.ln(3)
        elif kind == "img":
            image_path = (md_path.parent / value).resolve()
            if not image_path.is_file():
                raise SystemExit(f"Missing image: {image_path}")
            add_image(pdf, image_path)

    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    pdf.output(str(pdf_path))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render the Ivan markdown doc to PDF.")
    parser.add_argument("markdown", nargs="?", type=Path, default=DEFAULT_MD)
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_PDF)
    parser.add_argument(
        "--open", action="store_true", help="Open the PDF after writing it."
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    md_path = args.markdown.resolve()
    pdf_path = args.output.resolve()
    if not md_path.is_file():
        raise SystemExit(f"Markdown not found: {md_path}")
    render(md_path, pdf_path)
    print(pdf_path)
    if args.open:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        subprocess.Popen([opener, str(pdf_path)])


if __name__ == "__main__":
    main()
