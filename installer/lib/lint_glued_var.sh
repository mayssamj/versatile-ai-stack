#!/usr/bin/env bash
# lint_glued_var.sh — shared scanner for the "$var<multibyte>" crash class.
#
# A BARE $name written immediately before a multibyte UTF-8 glyph (→ … · ✓ ⚠ ─ …)
# makes bash, in a UTF-8 locale, try to extend the identifier into the glyph — it
# absorbs the lead byte into the variable name, yielding an unset name; under
# `set -u` it aborts with "name<byte>: unbound variable". This shipped once
# (upgrade.sh: verdisp="$VER_BEFORE→$VER_AFTER") and only detonated on a real
# version MOVE in a UTF-8 locale, so every offline/C-locale test missed it. The fix
# is always to brace-delimit: "${name}→...". This scanner is the single source of
# truth used by BOTH installer/tests/test_no_glued_multibyte_var.sh (standalone
# regression test) AND installer/doctor/checks/72_no_glued_multibyte_var.sh (so it
# runs on every `doctor`, not only when someone remembers the test's filename).
#
# perl, not grep: BSD/macOS `grep -P` silently NO-OPS on [\x80-\xFF] byte classes,
# which would make the scan pass vacuously — the exact failure this guards against.

# _glued_var_detect — reads a NUL-delimited list of file paths on stdin and prints
# "path:line: <trimmed line>" for every SHELL file (by .sh extension OR a shell
# shebang) that contains an unescaped, bare $name glued to a >=0x80 byte. What is
# deliberately NOT flagged, because none of it can hit the crash class:
#   - binary files (-T) and non-shell files (docs, python, JSON) — skipped wholesale;
#   - full-line comments (first non-blank char is '#') — inert, so a comment INSIDE a
#     shell file may document the pattern (e.g. this repo's own guard files);
#   - an escaped \$name — a literal '$' in bash, never an expansion ((?<!\\) below);
#   - special/positional params ($1, $@, …) — they read a fixed token and never
#     extend into a following byte.
_glued_var_detect() {
  perl -e '
    my $data; { local $/; $data = <STDIN>; }         # slurp the NUL-delimited path list
    for my $f (split /\0/, $data) {
      next unless length $f && -f $f && -T $f;        # -T skips binaries (e.g. *.tgz)
      open my $fh, "<:raw", $f or next;
      my $first = <$fh>;                              # peek the shebang
      my $is_sh = ($f =~ /\.sh$/) || (defined $first && $first =~ /^#!.*sh\b/);
      unless ($is_sh) { close $fh; next; }            # shell files only
      seek($fh, 0, 0); my $ln = 0;
      while (my $l = <$fh>) { $ln++;
        next if $l =~ /^\s*#/;                         # full-line comments are inert — never execute, so they
                                                        # cannot crash; this lets docs describe the pattern freely.
        # (?<!\\): an ESCAPED \$name is a literal dollar in bash (no expansion), so it
        # cannot hit the crash class — skip it. A real bug is an UNescaped $name→ .
        if ($l =~ /(?<!\\)\$[A-Za-z_]\w*[\x80-\xFF]/) { $l =~ s/\s+$//; print "$f:$ln: $l\n"; }
      }
      close $fh;
    }
  '
}

# scan_glued_multibyte_var [root] — scan every TRACKED file under the given git repo
# root (default: cwd). Prints offenders (path:line: text) and returns 1 if any exist,
# 0 if clean. Scanning all tracked files (then filtering to shell in perl) means a
# future extensionless shell script anywhere in the tree is covered without updating
# a curated pathspec.
scan_glued_multibyte_var() {
  local root="${1:-.}" hits
  hits="$(git -C "$root" ls-files -z | _glued_var_detect)"
  if [[ -n "$hits" ]]; then printf '%s\n' "$hits"; return 1; fi
  return 0
}
