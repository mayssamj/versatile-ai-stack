#!/usr/bin/env python3
"""build_tutorial_html.py — inject the 7-act lesson content from doc/TUTORIAL.md
into doc/TUTORIAL.html as self-contained, in-page sections.

WHY: the HTML tutorial is the first interface a new user touches. It must work
end-to-end in a browser with NO external link that the tutorial-serve proxy can
404. Earlier the act cards linked to `TUTORIAL.md#act-*`, which the loopback
proxy does not serve -> every "Act" click dead-ended on a JSON error. The robust
fix is a self-contained page: the acts live IN the page as `<section id="act-…">`
and the cards/nav point to same-page anchors.

Single source of truth = doc/TUTORIAL.md. This script regenerates the act
sections deterministically, so the prose never drifts between the .md and .html.

Usage:  python3 installer/lib/build_tutorial_html.py
        (run from the repo root; edits doc/TUTORIAL.html in place between the
         <!-- ACTS:START --> / <!-- ACTS:END --> markers)

The converter is intentionally small and tuned to the constructs TUTORIAL.md
actually uses (headings, fenced code, tables, blockquotes, hr, ordered/unordered
lists, inline code/bold/italic/links). It is NOT a general Markdown engine.
"""
from __future__ import annotations
import html
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MD = REPO / "doc" / "TUTORIAL.md"
HTML = REPO / "doc" / "TUTORIAL.html"
START = "<!-- ACTS:START -->"
END = "<!-- ACTS:END -->"


def gh_slug(text: str) -> str:
    """GitHub-style heading slug: lowercase, drop non [a-z0-9 -], spaces->'-'.
    'Act I — Arrival' -> 'act-i--arrival' (the em-dash is dropped, leaving the
    two surrounding spaces -> two hyphens), matching the existing card hrefs."""
    s = text.strip().lower()
    s = re.sub(r"[^a-z0-9 -]", "", s)
    return s.replace(" ", "-")


# ---------------------------------------------------------------------------
# Inline conversion: escape first, then code-spans (protected via placeholders),
# then links, bold, italic. Placeholders keep code-span content away from the
# emphasis regexes so `a*b` inside `code` is never mangled.
# ---------------------------------------------------------------------------
_PH = "\x00{}\x00"


def inline(text: str) -> str:
    esc = html.escape(text, quote=False)
    spans: list[str] = []

    def stash(m: re.Match) -> str:
        spans.append("<code>" + m.group(1) + "</code>")
        return _PH.format(len(spans) - 1)

    esc = re.sub(r"`([^`]+)`", stash, esc)
    # links [text](url) — text already escaped; guard the url's quotes
    esc = re.sub(
        r"\[([^\]]+)\]\(([^)\s]+)\)",
        lambda m: '<a href="{}">{}</a>'.format(html.escape(m.group(2), quote=True), m.group(1)),
        esc,
    )
    esc = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", esc)
    esc = re.sub(r"(?<!\w)\*([^*\n]+)\*(?!\w)", r"<em>\1</em>", esc)
    # restore code spans
    for i, span in enumerate(spans):
        esc = esc.replace(_PH.format(i), span)
    return esc


def tier_for(heading: str) -> str | None:
    if "🔴" in heading:
        return "adv"
    if "🟡" in heading:
        return "inter"
    if "🟢" in heading:
        return "basic"
    return None


def render_blocks(lines: list[str]) -> str:
    """Convert a list of markdown body lines to an HTML fragment."""
    out: list[str] = []
    i, n = 0, len(lines)
    para: list[str] = []

    def flush_para() -> None:
        if para:
            out.append("<p>" + inline(" ".join(para).strip()) + "</p>")
            para.clear()

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # fenced code block — opaque, escape-only
        if stripped.startswith("```"):
            flush_para()
            fence = stripped[:3]
            i += 1
            code: list[str] = []
            while i < n and lines[i].strip()[:3] != fence:
                code.append(lines[i])
                i += 1
            i += 1  # consume closing fence
            body = html.escape("\n".join(code), quote=False)
            out.append(
                '<pre><button class="copy-btn" data-copy>copy</button>'
                "<code>" + body + "</code></pre>"
            )
            continue

        # blank line — paragraph break
        if not stripped:
            flush_para()
            i += 1
            continue

        # headings (#### / ### / ## inside a body) — ## act heads handled by caller
        m = re.match(r"^(#{3,6})\s+(.*)$", stripped)
        if m:
            flush_para()
            level = len(m.group(1))
            text = m.group(2)
            if level == 3:
                lm = re.search(r"\bL(\d+)\b", text)
                hid = "l" + lm.group(1) if lm else gh_slug(text)
                badge = ""
                t = tier_for(text)
                if t:
                    label = {"basic": "basic", "inter": "intermediate", "adv": "advanced"}[t]
                    badge = ' <span class="tier {}">{}</span>'.format(t, label)
                out.append('<h3 id="{}">{}{}</h3>'.format(hid, inline(text), badge))
            else:
                tag = "h{}".format(min(level, 6))
                out.append("<{0}>{1}</{0}>".format(tag, inline(text)))
            i += 1
            continue

        # horizontal rule / lesson separator — drop (headings already separate)
        if re.match(r"^-{3,}$", stripped):
            flush_para()
            i += 1
            continue

        # table — header row, separator, then body rows
        if stripped.startswith("|") and i + 1 < n and re.match(r"^\s*\|?[\s:|-]+\|?\s*$", lines[i + 1]) and "-" in lines[i + 1]:
            flush_para()
            def cells(row: str) -> list[str]:
                row = row.strip().strip("|")
                return [c.strip() for c in row.split("|")]
            header = cells(stripped)
            i += 2  # skip header + separator
            rows: list[list[str]] = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append(cells(lines[i].strip()))
                i += 1
            thead = "".join("<th>" + inline(c) + "</th>" for c in header)
            tbody = ""
            for r in rows:
                tbody += "<tr>" + "".join("<td>" + inline(c) + "</td>" for c in r) + "</tr>"
            out.append("<table><thead><tr>" + thead + "</tr></thead><tbody>" + tbody + "</tbody></table>")
            continue

        # blockquote — render as a callout. Recurse on the inner (de-quoted) lines
        # so a blockquote that contains a fenced code block, list, or multiple
        # paragraphs renders correctly instead of being flattened into one <p>.
        if stripped.startswith(">"):
            flush_para()
            quote: list[str] = []
            while i < n and lines[i].strip().startswith(">"):
                quote.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            joined = " ".join(q.strip() for q in quote if q.strip())
            cls = "callout"
            low = joined.lower()
            if any(k in joined for k in ("⚠", "❗")) or low.startswith(("warning", "caution", "note:")):
                cls = "callout warn"
            out.append('<div class="{}">{}</div>'.format(cls, render_blocks(quote)))
            continue

        # lists (ordered / unordered, one level of nesting via indent)
        if re.match(r"^\s*([-*]|\d+\.)\s+", line):
            flush_para()
            out.append(render_list(lines, i, n))
            # advance past the consumed list
            i = render_list.last_index  # type: ignore[attr-defined]
            continue

        # default — accumulate paragraph text
        para.append(stripped)
        i += 1

    flush_para()
    return "\n".join(out)


def render_list(lines: list[str], start: int, n: int) -> str:
    """Render a (possibly one-level-nested) list starting at `start`.
    Sets render_list.last_index to the first non-list line index."""
    i = start
    base_indent = len(lines[i]) - len(lines[i].lstrip())
    ordered = bool(re.match(r"^\s*\d+\.\s+", lines[i]))
    items: list[str] = []
    cur: str | None = None
    sub: list[str] = []

    def emit_sub() -> str:
        if not sub:
            return ""
        inner = "".join("<li>" + inline(s) + "</li>" for s in sub)
        sub.clear()
        return "<ul>" + inner + "</ul>"

    while i < n:
        line = lines[i]
        if not line.strip():
            # blank: peek — if next is still a list item, treat as loose; else stop
            if i + 1 < n and re.match(r"^\s*([-*]|\d+\.)\s+", lines[i + 1]):
                i += 1
                continue
            break
        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if not m:
            break
        indent = len(m.group(1))
        text = m.group(3)
        if indent > base_indent:
            sub.append(text)
        else:
            if cur is not None:
                items.append("<li>" + inline(cur) + emit_sub() + "</li>")
            cur = text
        i += 1
    if cur is not None:
        items.append("<li>" + inline(cur) + emit_sub() + "</li>")
    render_list.last_index = i  # type: ignore[attr-defined]
    tag = "ol" if ordered else "ul"
    return "<{0}>{1}</{0}>".format(tag, "".join(items))


def build_sections(md: str) -> str:
    lines = md.splitlines()
    # find the ## Act headings
    acts: list[tuple[str, int]] = []
    for idx, ln in enumerate(lines):
        m = re.match(r"^##\s+(Act\s+.*)$", ln)
        if m:
            acts.append((m.group(1).strip(), idx))
    if not acts:
        raise SystemExit("no '## Act' headings found in TUTORIAL.md")

    sections: list[str] = []
    for j, (title, idx) in enumerate(acts):
        end = acts[j + 1][1] if j + 1 < len(acts) else len(lines)
        body = lines[idx + 1:end]
        slug = gh_slug(title)
        frag = render_blocks(body)
        sections.append(
            '<section id="{slug}">\n<h2>{title}</h2>\n{frag}\n</section>'.format(
                slug=slug, title=inline(title), frag=frag
            )
        )
    return "\n\n".join(sections)


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    check_only = "--check" in argv
    md = MD.read_text(encoding="utf-8")
    page = HTML.read_text(encoding="utf-8")
    if START not in page or END not in page:
        msg = ("markers {} / {} not found in TUTORIAL.html — add an empty\n"
               "  {}\n  {}\nregion where the act sections should be injected.").format(START, END, START, END)
        if check_only:
            print("OUT-OF-SYNC: " + msg); return 1
        raise SystemExit(msg)
    sections = build_sections(md)
    pre, rest = page.split(START, 1)
    _, post = rest.split(END, 1)
    new = pre + START + "\n" + sections + "\n" + END + post
    if check_only:
        # Read-only: report whether the on-disk HTML already matches a fresh build.
        if new == page:
            print("in sync ({} act sections)".format(new.count('<section id="act-')))
            return 0
        print("OUT-OF-SYNC: doc/TUTORIAL.html differs from a fresh build of doc/TUTORIAL.md — "
              "run: python3 installer/lib/build_tutorial_html.py")
        return 1
    HTML.write_text(new, encoding="utf-8")
    n = new.count('<section id="act-')
    print("✓ injected {} act sections into {}".format(n, HTML.relative_to(REPO)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
