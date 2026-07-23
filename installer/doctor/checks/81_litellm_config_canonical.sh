# litellm/config.yaml committed in its yq-canonical (render-stable) form (drift guard).
#
# litellm/config.yaml is a DERIVED artifact: installer/phases/01_inference.sh (:111) seeds it
# from prompts/config.yaml ONLY if absent, then installer/lib/models.sh (register_model_list)
# rewrites `.model_list` via `yq -i`, which RE-EMITS the whole document through yq's serializer
# and NORMALIZES comment indentation. Because the file is ALSO git-tracked, if the committed
# form is not already what yq emits, every `install`/`model sync` re-serializes it and dirties
# the tree with a pure whitespace/comment-reindent diff (zero model_list change).
#
# This was fixed once (bfc6944, "commit rendered config.yaml so model sync stops dirtying git")
# and REGRESSED five days later when fb41ce3 hand-edited the tracked artifact back to a
# non-canonical (4-space) indent. Re-commit-alone cannot survive that class of change, so this
# guard makes it CAUGHT instead of silent: assert the committed file is a yq FIXED POINT — i.e.
# re-emitting it through yq produces byte-identical output (which is exactly what the model
# renderer would write). Verified live: `yq '.'` output == register_model_list's actual output.
#
# Requires `yq` (a hard host dep; deps.sh installs it). Read-only; no stack, no cold-start.
CHECKS+=(config_canonical)
CHECK_TITLE[config_canonical]="litellm/config.yaml committed in yq-canonical form (no model-render dirt)"

config_canonical_diagnose() {
  local cfg="$AI_STACK/litellm/config.yaml"
  [[ -f "$cfg" ]] || { echo "litellm/config.yaml absent — nothing to check (install 01 seeds it). [skip]"; return 0; }
  command -v yq >/dev/null 2>&1 || { echo "yq not on PATH — cannot verify canonical form (run 'mayssam-ai-stack.sh deps'). [skip]"; return 0; }

  # Must be VALID yaml first (a malformed file would make `yq '.'` error, not "drift").
  if ! yq -e '.model_list[0]' "$cfg" >/dev/null 2>&1; then
    echo "litellm/config.yaml is not valid or has no model_list — 'yq -e .model_list[0]' failed."
    return 1
  fi

  # FIXED-POINT assertion: re-emitting through yq must change nothing. A non-empty diff means
  # the committed form is off-canonical → the next model render re-serializes it → git dirt.
  local d
  d="$(diff <(yq '.' "$cfg" 2>/dev/null) "$cfg" 2>/dev/null)"
  if [[ -n "$d" ]]; then
    echo "litellm/config.yaml is NOT in yq-canonical form — a 'model sync' / 'install' would"
    echo "re-serialize it and dirty git with a comment/whitespace-only diff (no model change):"
    printf '%s\n' "$d" | head -12 | sed 's/^/    /'
    return 1
  fi
  echo "  (litellm/config.yaml is a yq fixed point — model render leaves it byte-identical)"
  return 0
}

config_canonical_fix() {
  warn "litellm/config.yaml is off-canonical, so every model render re-dirties git. Re-commit the"
  warn "  canonical form (behavior-neutral — comments/whitespace only):"
  warn "    yq -i '.' \"\$AI_STACK/litellm/config.yaml\" && git add litellm/config.yaml && git commit"
  warn "  (Edit the SOURCE prompts/config.yaml for real changes; config.yaml is a derived artifact.)"
  return 1
}
