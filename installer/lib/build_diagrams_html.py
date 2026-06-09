#!/usr/bin/env python3
"""build_diagrams_html.py — generate doc/DIAGRAMS.html from doc/DIAGRAMS.md.

Single source of truth = doc/DIAGRAMS.md. Edit the .md and re-run to update.

Usage:
    python3 installer/lib/build_diagrams_html.py         # write doc/DIAGRAMS.html
    python3 installer/lib/build_diagrams_html.py --check # exit 1 if on-disk HTML differs

Parser strategy (tuned to the actual structure of DIAGRAMS.md):
  - Splits the document into: preamble + top-level ## sections.
  - Within each section, content is a sequence of "chunks":
      * PROSE chunk   — one or more non-mermaid lines (headings, paragraphs, lists …)
      * MERMAID chunk — a ```mermaid … ``` fence (verbatim)
  - Each MERMAID chunk becomes a diagram-card; the prose chunks before/between/after
    it render as HTML.
  - Sub-section headings (## 5a / ## 5b …) within a section get id="sec-5a" etc.
    so the old in-page anchor convention is preserved.
  - Bold-text "sub-titles" like **7.1 Allowed write …** in section 7 are rendered
    as normal prose (bold paragraph); they introduce a diagram card visually.
  - Diagram IDs are assigned sequentially (diag-1 … diag-N) across the page.
"""
from __future__ import annotations
import html as _html_mod
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MD = REPO / "doc" / "DIAGRAMS.md"
HTML_OUT = REPO / "doc" / "DIAGRAMS.html"


# ---------------------------------------------------------------------------
# Inline markdown → HTML
# ---------------------------------------------------------------------------

def inline(text: str) -> str:
    esc = _html_mod.escape(text, quote=False)
    spans: list[str] = []

    def stash(m: re.Match) -> str:
        spans.append("<code>" + m.group(1) + "</code>")
        return "\x00PH{}\x00".format(len(spans) - 1)

    esc = re.sub(r"`([^`]+)`", stash, esc)
    esc = re.sub(
        r"\[([^\]]+)\]\(([^)\s]+)\)",
        lambda m: '<a href="{}">{}</a>'.format(
            _html_mod.escape(m.group(2), quote=True), m.group(1)
        ),
        esc,
    )
    esc = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", esc)
    esc = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", esc)
    for i, span in enumerate(spans):
        esc = esc.replace("\x00PH{}\x00".format(i), span)
    return esc


def gh_slug(text: str) -> str:
    s = text.strip().lower()
    s = re.sub(r"[^a-z0-9 \-]", "", s)
    return s.replace(" ", "-")


# ---------------------------------------------------------------------------
# Block renderer — converts prose lines to HTML (no mermaid fences here)
# ---------------------------------------------------------------------------

def render_blocks(lines: list[str]) -> str:
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

        # non-mermaid fenced code block
        if re.match(r"^```", stripped):
            flush_para()
            lang = stripped[3:].strip()
            i += 1
            code: list[str] = []
            while i < n and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            cls = ' class="language-{}"'.format(_html_mod.escape(lang)) if lang else ""
            body = _html_mod.escape("\n".join(code), quote=False)
            out.append("<pre><code{}>{}</code></pre>".format(cls, body))
            continue

        if not stripped:
            flush_para()
            i += 1
            continue

        # headings (## or ### inside a section body)
        hm = re.match(r"^(#{2,6})\s+(.+)$", stripped)
        if hm:
            flush_para()
            level = len(hm.group(1))
            text = hm.group(2)
            # detect sub-section label like "5a.", "5b." → assign stable id
            sub_m = re.match(r"^(\d+[a-z]+)[.\s]", text, re.IGNORECASE)
            if sub_m:
                sub_id = "sec-" + sub_m.group(1).lower()
                out.append('<h3 id="{}">{}</h3>'.format(sub_id, inline(text)))
            else:
                tag = "h{}".format(min(level + 1, 6))
                out.append("<{0}>{1}</{0}>".format(tag, inline(text)))
            i += 1
            continue

        # horizontal rule — drop (sections already separated visually)
        if re.match(r"^-{3,}$", stripped) or re.match(r"^={3,}$", stripped):
            flush_para()
            i += 1
            continue

        # blockquote
        if stripped.startswith(">"):
            flush_para()
            bq: list[str] = []
            while i < n and lines[i].strip().startswith(">"):
                bq.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append("<blockquote>{}</blockquote>".format(render_blocks(bq)))
            continue

        # list
        if re.match(r"^\s*([-*+]|\d+\.)\s+", line):
            flush_para()
            result, consumed = render_list(lines, i, n)
            out.append(result)
            i = consumed
            continue

        para.append(stripped)
        i += 1

    flush_para()
    return "\n".join(out)


def render_list(lines: list[str], start: int, n: int) -> tuple[str, int]:
    i = start
    base_indent = len(lines[i]) - len(lines[i].lstrip())
    ordered = bool(re.match(r"^\s*\d+\.\s+", lines[i]))
    items: list[str] = []
    cur: str | None = None
    sub: list[str] = []

    def emit_sub() -> str:
        if not sub:
            return ""
        inner = "".join("<li>{}</li>".format(inline(s)) for s in sub)
        sub.clear()
        return "<ul>{}</ul>".format(inner)

    while i < n:
        line = lines[i]
        if not line.strip():
            if i + 1 < n and re.match(r"^\s*([-*+]|\d+\.)\s+", lines[i + 1]):
                i += 1
                continue
            break
        m = re.match(r"^(\s*)([-*+]|\d+\.)\s+(.*)$", line)
        if not m:
            break
        indent = len(m.group(1))
        text = m.group(3)
        if indent > base_indent:
            sub.append(text)
        else:
            if cur is not None:
                items.append("<li>{}{}</li>".format(inline(cur), emit_sub()))
            cur = text
        i += 1
    if cur is not None:
        items.append("<li>{}{}</li>".format(inline(cur), emit_sub()))

    tag = "ol" if ordered else "ul"
    return "<{0}>{1}</{0}>".format(tag, "".join(items)), i


# ---------------------------------------------------------------------------
# Document parser
# ---------------------------------------------------------------------------
# The document is a sequence of:
#   - preamble: lines before the first ## heading
#   - sections: each starts with ## N. Title and runs until the next ## N.
#
# Within a section, we split content into interleaved PROSE and MERMAID tokens.
# This is the simplest correct approach: no nested state machine needed.

class _Token:
    pass

class ProseToken(_Token):
    def __init__(self, lines: list[str]):
        self.lines = lines

class MermaidToken(_Token):
    def __init__(self, source: str):
        self.source = source


def tokenize_section_body(lines: list[str]) -> list[_Token]:
    """Split section body lines into alternating prose/mermaid tokens."""
    tokens: list[_Token] = []
    i, n = 0, len(lines)
    prose: list[str] = []

    while i < n:
        if lines[i].strip().startswith("```mermaid"):
            if prose:
                tokens.append(ProseToken(list(prose)))
                prose.clear()
            i += 1
            src: list[str] = []
            while i < n and not lines[i].strip().startswith("```"):
                src.append(lines[i])
                i += 1
            i += 1  # closing ```
            tokens.append(MermaidToken("\n".join(src)))
        else:
            prose.append(lines[i])
            i += 1

    if prose:
        tokens.append(ProseToken(list(prose)))

    return tokens


def parse_markdown(md: str) -> tuple[list[str], list[tuple[str, str, list[_Token]]]]:
    """
    Returns:
      preamble: lines before first ## heading
      sections: list of (title, sec_id, tokens)
    """
    lines = md.splitlines()
    n = len(lines)

    # ---- split into preamble + raw sections ----
    preamble: list[str] = []
    raw_sections: list[tuple[str, list[str]]] = []  # (title, body_lines)

    def is_main_section(line: str) -> bool:
        """True for ## N. headings where N is a pure integer (1, 2 … 12).
        Returns False for sub-sections like ## 5a., ## 5b. etc."""
        s = line.strip()
        return bool(re.match(r"^## \d+[.\s]", s) and not re.match(r"^## \d+[a-zA-Z]", s))

    i = 0
    while i < n:
        if is_main_section(lines[i]):
            break
        preamble.append(lines[i])
        i += 1

    while i < n:
        if is_main_section(lines[i]):
            title = re.sub(r"^## ", "", lines[i].strip())
            i += 1
            body: list[str] = []
            while i < n and not is_main_section(lines[i]):
                body.append(lines[i])
                i += 1
            raw_sections.append((title, body))
        else:
            i += 1

    # ---- build section ids and tokenize bodies ----
    sections: list[tuple[str, str, list[_Token]]] = []
    for title, body in raw_sections:
        sec_num_m = re.match(r"^(\d+)[.\s]", title)
        sec_num = sec_num_m.group(1) if sec_num_m else str(len(sections) + 1)
        # slug from title, strip leading "N. " prefix
        title_for_slug = re.sub(r"^\d+[a-z]*[.\s]+", "", title).strip()
        sec_id = "sec-{}-{}".format(sec_num, gh_slug(title_for_slug))
        tokens = tokenize_section_body(body)
        sections.append((title, sec_id, tokens))

    return preamble, sections


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

HEAD = """\
<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ai-stack — Diagrams</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script>
<!-- svg-pan-zoom removed: zoom + pan are now pure CSS transform on a wrapping
     layer. No CDN dependency for zoom, no race with mermaid's SVG injection. -->
<style>
  :root {
    --bg:#0c1117; --bg-elev:#161b22; --bg-soft:#21262d; --bg-code:#0d1117;
    --fg:#e6edf3; --fg-soft:#8b949e; --fg-dim:#6e7681;
    --accent:#58a6ff; --accent-soft:rgba(88,166,255,.12);
    --border:#30363d; --border-soft:#21262d;
    --radius:8px; --mono:ui-monospace,"SF Mono",Menlo,monospace;
    --sans:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",Roboto,sans-serif;
  }
  [data-theme="light"] {
    --bg:#fff; --bg-elev:#f6f8fa; --bg-soft:#eaeef2; --bg-code:#f6f8fa;
    --fg:#1f2328; --fg-soft:#59636e; --fg-dim:#818b97;
    --accent:#0969da; --accent-soft:rgba(9,105,218,.10);
    --border:#d0d7de; --border-soft:#eaeef2;
  }
  * { box-sizing:border-box; }
  html,body { margin:0; padding:0; }
  body { font-family:var(--sans); background:var(--bg); color:var(--fg); line-height:1.55; -webkit-font-smoothing:antialiased; }
  a { color:var(--accent); text-decoration:none; }
  a:hover { text-decoration:underline; }
  code { font-family:var(--mono); background:var(--bg-soft); padding:2px 6px; border-radius:4px; font-size:13.5px; color:var(--accent); }
  blockquote { border-left:3px solid var(--accent); background:var(--accent-soft); padding:8px 14px; border-radius:0 var(--radius) var(--radius) 0; margin:12px 0; color:var(--fg); }
  hr { border:none; border-top:1px solid var(--border); margin:32px 0; }

  header {
    position:sticky; top:0; z-index:10;
    background:rgba(12,17,23,0.92); backdrop-filter:blur(10px);
    border-bottom:1px solid var(--border);
    padding:12px 24px;
    display:flex; align-items:center; gap:16px;
  }
  [data-theme="light"] header { background:rgba(255,255,255,0.92); }
  header .logo { font-family:var(--mono); font-weight:700; font-size:16px; color:var(--fg); text-decoration:none; }
  header .logo .accent { color:var(--accent); }
  header .spacer { flex:1; }
  .icon-btn { background:transparent; border:1px solid var(--border); color:var(--fg-soft); border-radius:4px; padding:6px 10px; cursor:pointer; font-size:13px; }
  .icon-btn:hover { color:var(--fg); border-color:var(--accent); background:var(--accent-soft); }

  .layout { display:grid; grid-template-columns:260px 1fr; gap:0; min-height:calc(100vh - 56px); }
  @media (max-width:900px) { .layout { grid-template-columns:1fr; } aside { display:none; } }
  aside {
    border-right:1px solid var(--border);
    padding:24px 16px;
    position:sticky; top:56px; height:calc(100vh - 56px); overflow-y:auto;
    background:var(--bg);
  }
  aside h3 { margin:0 0 8px; font-size:12px; text-transform:uppercase; letter-spacing:0.08em; color:var(--fg-dim); }
  aside ul { list-style:none; padding:0; margin:0; }
  aside li { margin:2px 0; }
  aside a { display:block; padding:6px 10px; border-radius:4px; color:var(--fg-soft); font-size:13.5px; line-height:1.3; }
  aside a:hover { background:var(--bg-soft); color:var(--fg); text-decoration:none; }
  aside a.active { background:var(--accent-soft); color:var(--accent); }

  main { padding:32px 32px 80px; max-width:1200px; overflow-x:hidden; }
  h1 { font-size:36px; margin:0 0 12px; letter-spacing:-0.02em; }
  h2 { font-size:24px; margin:48px 0 12px; scroll-margin-top:80px; padding-bottom:6px; border-bottom:1px solid var(--border-soft); }
  h3 { font-size:18px; margin:24px 0 8px; color:var(--fg-soft); }
  p { margin:8px 0; }
  ul { padding-left:24px; }

  .diagram-card {
    border:1px solid var(--border); border-radius:var(--radius);
    margin:24px 0; background:var(--bg-elev); overflow:hidden;
  }
  .diagram-controls {
    display:flex; gap:6px; padding:10px 14px;
    border-bottom:1px solid var(--border-soft); background:var(--bg-soft);
  }
  .zoom-btn {
    background:var(--bg); border:1px solid var(--border); color:var(--fg); cursor:pointer;
    width:32px; height:32px; border-radius:4px; font-size:15px; font-family:var(--sans);
    display:flex; align-items:center; justify-content:center;
  }
  .zoom-btn:hover { background:var(--accent-soft); border-color:var(--accent); }
  .zoom-btn.copied { background:rgba(63,185,80,0.2); border-color:#3fb950; color:#3fb950; }
  .diagram-viewport {
    height: 70vh; padding: 0; background: #fff;
    position: relative; overflow: hidden;
    cursor: grab; user-select: none;
  }
  .diagram-viewport.is-panning { cursor: grabbing; }
  [data-theme="dark"] .diagram-viewport { background: #fafbfc; }
  .diagram-viewport .diag-pan-layer {
    position: absolute; inset: 0;
    transform-origin: 0 0;
    transition: transform 0.12s cubic-bezier(.2,.7,.3,1.1);
    will-change: transform;
  }
  .diagram-viewport.is-panning .diag-pan-layer { transition: none; }
  .diagram-viewport .mermaid,
  .diagram-viewport .mermaid > svg {
    width: 100%; height: 100%; display: block;
    max-width: none; max-height: none;
  }
  /* True fullscreen API. Use :fullscreen rather than a CSS class hack. */
  .diagram-card:fullscreen { background: var(--bg-elev); padding: 0; border-radius: 0; }
  .diagram-card:fullscreen .diagram-viewport { height: calc(100vh - 54px); }
  [data-theme="dark"] .diagram-card:fullscreen .diagram-viewport { background: #fafbfc; }
  .diagram-card:fullscreen .diagram-controls { border-radius: 0; }
  /* Cursor hint on the SVG itself — the viewport already does grab/grabbing. */
  .diagram-viewport svg { cursor: inherit; pointer-events: none; }
  /* Re-enable pointer events on inner anchors so clickable nodes still work,
     but the SVG surface itself is transparent to mousedown so our pan handler
     on .diagram-viewport always wins. */
  .diagram-viewport svg a { pointer-events: auto; }

  footer { border-top:1px solid var(--border); padding:32px 24px; text-align:center; color:var(--fg-dim); font-size:13px; margin-top:48px; }
</style>
</head>
<body>

<header>
  <a href="#top" class="logo">ai<span class="accent">-stack</span> · diagrams</a>
  <div class="spacer"></div>
  <button class="icon-btn" id="themeToggle" title="Toggle theme">◐</button>
  <a class="icon-btn" href="DIAGRAMS.md" title="View source">.md</a>
  <a class="icon-btn" href="USER-GUIDE.html" title="User guide">User guide</a>
</header>"""

FOOTER = """\
<footer>
  Generated from <a href="DIAGRAMS.md">DIAGRAMS.md</a> by installer/lib/build_diagrams_html.py. Mermaid v11.4.1 + pure CSS-transform zoom/pan (no svg-pan-zoom dependency).
  Companions: <a href="USER-GUIDE.html">USER-GUIDE.html</a> · <a href="USER-GUIDE.md">USER-GUIDE.md</a> · <a href="STACK-GUIDE.md">STACK-GUIDE.md</a>
</footer>"""

SCRIPT = """\
<script>
// Theme
document.getElementById('themeToggle').addEventListener('click', () => {
  const cur = document.documentElement.getAttribute('data-theme');
  const next = cur === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next);
  try { localStorage.setItem('ai-stack-diag-theme', next); } catch(e){}
});
try { const t = localStorage.getItem('ai-stack-diag-theme'); if (t) document.documentElement.setAttribute('data-theme', t); } catch(e){}

// Capture original mermaid source BEFORE mermaid mutates the DOM (for copy button).
document.querySelectorAll('.mermaid').forEach(d => { d.dataset.originalSrc = d.textContent; });

// Mermaid init — startOnLoad:false so we wrap each diagram in a transform layer
// FIRST, then render mermaid into the wrapper. No CDN dependency for zoom.
mermaid.initialize({
  startOnLoad: false, theme: 'default',
  themeVariables: { fontSize: '16px' },
  securityLevel: 'loose', maxTextSize: 50000,
});

// Per-diagram CSS-transform state. Each entry: { scale, x, y, layer, viewport }.
// We zoom/pan the wrapping .diag-pan-layer, not the SVG directly, so mermaid
// never has to re-render and svg internals stay untouched.
const diagState = new Map();

function applyTransform(id) {
  const s = diagState.get(id); if (!s) return;
  s.layer.style.transform = 'translate(' + s.x + 'px, ' + s.y + 'px) scale(' + s.scale + ')';
}

function resetDiagram(id) {
  const s = diagState.get(id); if (!s) return;
  s.scale = 1; s.x = 0; s.y = 0;
  applyTransform(id);
}

// Zoom around a focal point (cx, cy) expressed in viewport-local coords.
// Math: after scaling by `ratio` we want the same world-point that was under
// the cursor (cx, cy) to remain under the cursor. That gives:
//   newOffset = focal − ratio × (focal − oldOffset)
function zoomAround(id, factor, cx, cy) {
  const s = diagState.get(id); if (!s) return;
  const newScale = Math.max(0.15, Math.min(40, s.scale * factor));
  const ratio = newScale / s.scale;
  s.x = cx - ratio * (cx - s.x);
  s.y = cy - ratio * (cy - s.y);
  s.scale = newScale;
  applyTransform(id);
}

// Wrap each diagram in a transform layer + wire wheel/drag.
document.querySelectorAll('.diagram-card').forEach(card => {
  const viewport = card.querySelector('.diagram-viewport');
  const mermaidDiv = card.querySelector('.mermaid');
  if (!viewport || !mermaidDiv) return;
  const id = mermaidDiv.id;
  const layer = document.createElement('div');
  layer.className = 'diag-pan-layer';
  viewport.appendChild(layer);
  layer.appendChild(mermaidDiv);
  diagState.set(id, { scale: 1, x: 0, y: 0, layer, viewport });

  // Wheel zoom — cursor-centered.
  viewport.addEventListener('wheel', (e) => {
    e.preventDefault();
    const rect = viewport.getBoundingClientRect();
    const cx = e.clientX - rect.left;
    const cy = e.clientY - rect.top;
    zoomAround(id, e.deltaY < 0 ? 1.15 : 1 / 1.15, cx, cy);
  }, { passive: false });

  // Drag-pan. Listen on window for move/up so cursor leaving the viewport
  // mid-drag doesn't cancel the gesture.
  let dragging = false, startX = 0, startY = 0, origX = 0, origY = 0;
  viewport.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    if (e.target.closest('.zoom-btn')) return;
    dragging = true; viewport.classList.add('is-panning');
    startX = e.clientX; startY = e.clientY;
    const s = diagState.get(id); origX = s.x; origY = s.y;
    e.preventDefault();
  });
  window.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    const s = diagState.get(id); if (!s) return;
    s.x = origX + (e.clientX - startX);
    s.y = origY + (e.clientY - startY);
    applyTransform(id);
  });
  window.addEventListener('mouseup', () => {
    if (!dragging) return;
    dragging = false; viewport.classList.remove('is-panning');
  });
});

// Render mermaid, then strip the SVG's fixed sizing so it fills the layer.
mermaid.run({ querySelector: '.mermaid' }).then(() => {
  document.querySelectorAll('.mermaid > svg').forEach(svg => {
    svg.removeAttribute('height');
    svg.removeAttribute('style');
    svg.style.width = '100%';
    svg.style.height = '100%';
    svg.style.maxWidth = 'none';
    svg.style.maxHeight = 'none';
  });
}).catch(err => {
  console.error('[DIAGRAMS] mermaid.run failed:', err);
});

// Button handlers — viewport-center as zoom focal for +/− buttons.
document.addEventListener('click', (e) => {
  const btn = e.target.closest('.zoom-btn');
  if (!btn) return;
  const id = btn.dataset.target;
  const action = btn.dataset.action;
  const card = btn.closest('.diagram-card');
  if (!card || !diagState.has(id)) return;
  const viewport = card.querySelector('.diagram-viewport');
  const rect = viewport.getBoundingClientRect();
  const cx = rect.width / 2, cy = rect.height / 2;
  if (action === 'in')        zoomAround(id, 1.4, cx, cy);
  else if (action === 'out')  zoomAround(id, 1 / 1.4, cx, cy);
  else if (action === 'reset') resetDiagram(id);
  else if (action === 'fullscreen') {
    if (document.fullscreenElement) document.exitFullscreen();
    else card.requestFullscreen?.();
  }
  else if (action === 'copy') {
    const mermaidDiv = document.getElementById(id);
    const src = mermaidDiv?.dataset.originalSrc || '';
    navigator.clipboard.writeText(src).then(() => {
      btn.classList.add('copied');
      const orig = btn.textContent;
      btn.textContent = '✓';
      setTimeout(() => { btn.textContent = orig; btn.classList.remove('copied'); }, 1500);
    });
  }
});

// Reset transform on fullscreen change so the diagram refits the new viewport.
document.addEventListener('fullscreenchange', () => {
  const el = document.fullscreenElement;
  const id = el?.querySelector?.('.mermaid')?.id;
  if (id) setTimeout(() => resetDiagram(id), 50);
});

// Keyboard +/-/0 on the focused (or hovered) diagram card.
document.querySelectorAll('.diagram-card').forEach(c => { c.tabIndex = 0; });
document.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  const card = document.activeElement?.closest?.('.diagram-card') ||
               document.querySelector('.diagram-card:hover');
  if (!card) return;
  const id = card.querySelector('.mermaid')?.id;
  if (!id || !diagState.has(id)) return;
  const viewport = card.querySelector('.diagram-viewport');
  const rect = viewport.getBoundingClientRect();
  const cx = rect.width / 2, cy = rect.height / 2;
  if (e.key === '+' || e.key === '=') { zoomAround(id, 1.4, cx, cy); e.preventDefault(); }
  else if (e.key === '-' || e.key === '_') { zoomAround(id, 1 / 1.4, cx, cy); e.preventDefault(); }
  else if (e.key === '0') { resetDiagram(id); e.preventDefault(); }
});

// Sidebar active section highlighting
const sectionIds = Array.from(document.querySelectorAll('section')).map(s => s.id);
function updateActive() {
  let active = sectionIds[0];
  for (const id of sectionIds) {
    const el = document.getElementById(id);
    if (el && el.getBoundingClientRect().top < 100) active = id;
  }
  document.querySelectorAll('aside a').forEach(a => {
    a.classList.toggle('active', a.getAttribute('href') === '#' + active);
  });
}
window.addEventListener('scroll', updateActive, {passive: true});
updateActive();
</script>
</body>
</html>"""


def diagram_card(did: str, source: str) -> str:
    return (
        '<div class="diagram-card">\n'
        '  <div class="diagram-controls">\n'
        '    <button class="zoom-btn" data-target="{did}" data-action="out" title="Zoom out">−</button>\n'
        '    <button class="zoom-btn" data-target="{did}" data-action="reset" title="Reset">⟲</button>\n'
        '    <button class="zoom-btn" data-target="{did}" data-action="in" title="Zoom in">+</button>\n'
        '    <button class="zoom-btn" data-target="{did}" data-action="fullscreen" title="Full screen">⛶</button>\n'
        '    <button class="zoom-btn" data-target="{did}" data-action="copy" title="Copy mermaid source">\U0001f4cb</button>\n'
        '  </div>\n'
        '  <div class="diagram-viewport" id="{did}-viewport">\n'
        '    <div class="mermaid" id="{did}">{src}</div>\n'
        '  </div>\n'
        '</div>'
    ).format(did=did, src=source)


def generate(md_text: str) -> str:
    preamble, sections = parse_markdown(md_text)

    # assign sequential diagram ids across all sections
    diag_counter = [0]

    def next_id() -> str:
        diag_counter[0] += 1
        return "diag-{}".format(diag_counter[0])

    # --- render preamble (strip the # title line — it becomes <h1>) ---
    preamble_body = [l for l in preamble if not re.match(r"^# (?!#)", l.strip())]
    preamble_html = render_blocks(preamble_body)

    # --- TOC (top-level sections only) ---
    toc_items = "\n".join(
        '<li><a href="#{}">{}</a></li>'.format(sec_id, _html_mod.escape(title))
        for title, sec_id, _ in sections
    )

    # total diagram count
    total_diags = sum(
        sum(1 for t in tokens if isinstance(t, MermaidToken))
        for _, _, tokens in sections
    )

    # --- render each section ---
    section_parts: list[str] = []
    for title, sec_id, tokens in sections:
        inner_parts: list[str] = []
        for tok in tokens:
            if isinstance(tok, ProseToken):
                html_frag = render_blocks(tok.lines)
                if html_frag.strip():
                    inner_parts.append(html_frag)
            else:
                did = next_id()
                inner_parts.append(diagram_card(did, tok.source))

        inner = "\n".join(inner_parts)
        section_parts.append(
            '<section id="{sid}"><h2>{title}</h2>\n{inner}\n</section>'.format(
                sid=sec_id,
                title=inline(title),
                inner=inner,
            )
        )

    sections_html = "\n\n<hr>\n".join(section_parts)

    page = "\n".join([
        HEAD,
        "",
        '<div class="layout">',
        "  <aside>",
        '    <h3>Sections ({} diagrams)</h3>'.format(total_diags),
        '    <ul id="toc">',
        "      " + toc_items,
        "    </ul>",
        "  </aside>",
        "",
        '  <main id="top">',
        "    <h1>Diagrams</h1>",
        preamble_html,
        "",
        sections_html,
        "  </main>",
        "</div>",
        "",
        FOOTER,
        "",
        SCRIPT,
    ])
    return page


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    check_only = "--check" in argv

    if not MD.exists():
        print("ERROR: {} not found".format(MD))
        return 1

    md_text = MD.read_text(encoding="utf-8")
    generated = generate(md_text)
    mermaid_count = generated.count('<div class="mermaid"')

    if check_only:
        if not HTML_OUT.exists():
            print("OUT-OF-SYNC: {} does not exist — run: python3 installer/lib/build_diagrams_html.py".format(HTML_OUT))
            return 1
        on_disk = HTML_OUT.read_text(encoding="utf-8")
        if generated == on_disk:
            print("in sync ({} mermaid diagrams)".format(mermaid_count))
            return 0
        print(
            "OUT-OF-SYNC: doc/DIAGRAMS.html differs from a fresh build of doc/DIAGRAMS.md — "
            "run: python3 installer/lib/build_diagrams_html.py"
        )
        return 1

    HTML_OUT.write_text(generated, encoding="utf-8")
    print("wrote {} ({} mermaid diagrams)".format(HTML_OUT.relative_to(REPO), mermaid_count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
