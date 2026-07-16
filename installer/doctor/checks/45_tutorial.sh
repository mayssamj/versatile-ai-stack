# Tutorial + Diagrams integrity — both HTML pages are generated from their .md sources
# and must never drift. Guards:
#   doc/TUTORIAL.html: the 7-act self-contained tutorial page (installer/lib/build_tutorial_html.py)
#   doc/DIAGRAMS.html: the mermaid diagram viewer (installer/lib/build_diagrams_html.py)
#
# Tutorial checks (with NO network):
#   - exactly 7 in-page <section id="act-…"> sections
#   - zero external "TUTORIAL.md#…" anchored nav links (they 404 under serve)
#   - every in-page #anchor resolves to an element id; no duplicate ids
#   - the HTML is in sync with a fresh build of doc/TUTORIAL.md (no drift)
# Diagrams check:
#   - doc/DIAGRAMS.html is in sync with a fresh build of doc/DIAGRAMS.md (no drift)
CHECKS+=(tutorial)
CHECK_TITLE[tutorial]="Tutorial + Diagrams pages in sync with their .md sources (doc/TUTORIAL.html, doc/DIAGRAMS.html)"
FIX_CAPABLE[tutorial]=1   # <name>_fix MUTATES state (see doctor.sh FIX_CAPABLE)

tutorial_diagnose() {
  local html="$AI_STACK/doc/TUTORIAL.html"
  local gen="$AI_STACK/installer/lib/build_tutorial_html.py"
  local diag_html="$AI_STACK/doc/DIAGRAMS.html"
  local diag_gen="$AI_STACK/installer/lib/build_diagrams_html.py"
  [[ -f "$html" ]] || { echo "doc/TUTORIAL.html missing — generate it: python3 installer/lib/build_tutorial_html.py"; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 not found — cannot validate the tutorial page"; return 1; }
  python3 - "$html" "$gen" "$diag_gen" <<'PY'
import subprocess, sys
from html.parser import HTMLParser
html_path, gen = sys.argv[1], sys.argv[2]
h = open(html_path, encoding="utf-8").read()

# Parse REAL element attributes (not regex over the text) so id="…" inside code
# examples (e.g. workspace_id="tutorial") and attrs like *_id are never counted.
class Scan(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []          # real element ids, in document order
        self.in_anchors = []   # href targets that start with '#'
        self.ext_anchors = []  # hrefs that point at TUTORIAL.md#…
        self.act_sections = 0
    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        i = d.get("id")
        if i:
            self.ids.append(i)
            if tag == "section" and i.startswith("act-"):
                self.act_sections += 1
        if tag == "a":
            href = d.get("href") or ""
            if href.startswith("#") and len(href) > 1:
                self.in_anchors.append(href[1:])
            elif href.startswith("TUTORIAL.md#"):
                self.ext_anchors.append(href)

s = Scan(); s.feed(h)
issues = []
if s.act_sections != 7:
    issues.append(f"expected 7 in-page act sections, found {s.act_sections} (page not self-contained)")
if s.ext_anchors:
    issues.append('external "TUTORIAL.md#…" nav link(s) present — they 404 under tutorial-serve; nav must be in-page (#act-…): ' + ", ".join(sorted(set(s.ext_anchors))))
dupes = sorted({x for x in s.ids if s.ids.count(x) > 1})
if dupes:
    issues.append("duplicate element id(s): " + ", ".join(dupes))
idset = set(s.ids)
missing = sorted({a for a in s.in_anchors if a not in idset})
if missing:
    issues.append("in-page anchor(s) with no matching id: " + ", ".join(missing))
try:
    if subprocess.run([sys.executable, gen, "--check"], capture_output=True, text=True, timeout=30).returncode != 0:
        issues.append("HTML out of sync with doc/TUTORIAL.md — run: python3 installer/lib/build_tutorial_html.py")
except Exception as e:
    issues.append(f"could not run converter --check: {e}")
# Diagrams drift check (skip cleanly if the generator is absent — partial checkout)
import os
diag_gen = sys.argv[3]
if os.path.exists(diag_gen):
    try:
        r = subprocess.run([sys.executable, diag_gen, "--check"], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            issues.append("doc/DIAGRAMS.html out of sync with doc/DIAGRAMS.md — run: python3 installer/lib/build_diagrams_html.py")
    except Exception as e:
        issues.append(f"could not run diagrams converter --check: {e}")
if issues:
    for i in issues:
        print("  - " + i)
    print("  Fix: python3 installer/lib/build_tutorial_html.py && python3 installer/lib/build_diagrams_html.py")
    sys.exit(1)
print(f"({s.act_sections} acts in-page, {len(set(s.in_anchors))} anchors all resolve, no dupes, tutorial in sync, diagrams in sync)")
sys.exit(0)
PY
}

tutorial_fix() {
  # Safe + idempotent: regenerate both HTML pages from their .md sources.
  local ok=0
  warn "Regenerating doc/TUTORIAL.html from doc/TUTORIAL.md…"
  if python3 "$AI_STACK/installer/lib/build_tutorial_html.py" >/dev/null 2>&1; then
    warn "doc/TUTORIAL.html regenerated"
  else
    warn "tutorial regeneration failed — run manually: python3 $AI_STACK/installer/lib/build_tutorial_html.py"
    ok=1
  fi
  warn "Regenerating doc/DIAGRAMS.html from doc/DIAGRAMS.md…"
  if python3 "$AI_STACK/installer/lib/build_diagrams_html.py" >/dev/null 2>&1; then
    warn "doc/DIAGRAMS.html regenerated"
  else
    warn "diagrams regeneration failed — run manually: python3 $AI_STACK/installer/lib/build_diagrams_html.py"
    ok=1
  fi
  [[ $ok -eq 0 ]] && warn "both pages regenerated — re-run doctor to confirm"
  return $ok
}
