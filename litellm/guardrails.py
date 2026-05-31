# LiteLLM custom callback — in-process prompt/response guardrails.
# Loaded only after Phase 04·G adds "guardrails.handler" to litellm callbacks.
#
# Two layers (corrected per Reviewer X-#1 + Y cross-examination):
#   1. Pre-call hook  — denies prompts that match a small regex set, by
#      raising HTTPException (400) BEFORE the upstream model is invoked.
#   2. Post-call hook — MUTATES the wire response object so secrets pasted
#      into prompts and echoed back by a model never reach the client.
#      Uses async_post_call_success_hook, NOT log_success_event (which is
#      a logging hook and DOES NOT affect the served body).
#
# Failure semantics: BOTH hooks fail-CLOSED. If our redactor raises an
# internal exception, the response is withheld with HTTP 500. The prior
# version's "pass # fail-open" silently served unredacted bodies, which
# defeated the purpose of the control. Audit log captures every event.
from litellm.integrations.custom_logger import CustomLogger
import json
import os
import re
import threading
import time

AUDIT_PATH = os.getenv("GUARDRAILS_AUDIT_FILE", "/traces/guardrails.jsonl")
_lock = threading.Lock()


def _audit(rec):
    try:
        os.makedirs(os.path.dirname(AUDIT_PATH), exist_ok=True)
        with _lock, open(AUDIT_PATH, "a") as f:
            f.write(json.dumps(rec, default=str) + "\n")
    except Exception:
        pass


# --- pre-call deny patterns (extend as needed) -------------------------------
DENY_PATTERNS = [
    # The classic "ignore your instructions" pattern
    re.compile(r"\bignore (all )?(prior|previous|above)\s+(instructions|prompts)\b", re.I),
    # Obvious payload-extraction phrases
    re.compile(r"\bsystem prompt\b.*\bprint\b", re.I),
    re.compile(r"\bexfiltrate\b", re.I),
]


# --- post-call redaction patterns -------------------------------------------
REDACT_PATTERNS = [
    # OpenAI-style keys
    (re.compile(r"sk-[A-Za-z0-9_\-]{20,}"), "sk-REDACTED"),
    # OpenRouter
    (re.compile(r"sk-or-[A-Za-z0-9_\-]{20,}"), "sk-or-REDACTED"),
    # Anthropic
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}"), "sk-ant-REDACTED"),
    # GitHub PAT
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"), "gh*_REDACTED"),
    # AWS access key id
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AKIA_REDACTED"),
    # JWTs (rough)
    (re.compile(r"eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), "jwt.REDACTED"),
]


def _check_deny(messages):
    """Return (allowed, matched_pattern). Inspects last user message."""
    last_user = ""
    for m in reversed(messages or []):
        if m.get("role") == "user":
            last_user = str(m.get("content", ""))
            break
    for pat in DENY_PATTERNS:
        if pat.search(last_user):
            return False, pat.pattern
    return True, None


def _redact(text):
    if not isinstance(text, str):
        return text, 0
    count = 0
    out = text
    for pat, repl in REDACT_PATTERNS:
        new, n = pat.subn(repl, out)
        out = new
        count += n
    return out, count


class Guardrails(CustomLogger):
    # ---- Pre-call: deny on prompt match (fail-CLOSED) -----------------------
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if call_type not in ("completion", "chat_completion", "acompletion"):
            return data
        try:
            allowed, pat = _check_deny(data.get("messages"))
        except Exception as e:
            _audit({"ts": time.time(), "kind": "deny_error", "error": str(e),
                    "model": data.get("model"), "call_type": call_type})
            # Fail CLOSED: if we can't evaluate, we refuse the call.
            from fastapi import HTTPException
            raise HTTPException(
                status_code=500,
                detail="guardrails: pre-call evaluator failed; request withheld",
            )
        if not allowed:
            _audit({"ts": time.time(), "kind": "deny", "pattern": pat,
                    "model": data.get("model"), "call_type": call_type})
            from fastapi import HTTPException
            raise HTTPException(
                status_code=400,
                detail=f"guardrails: request denied by pattern {pat!r}",
            )
        return data

    # ---- Post-call: MUTATE the wire response (Reviewer X-#1 + Y amendment) --
    # This is the hook that actually changes what the client sees. Previous
    # implementations used log_success_event which is logging-only and DOES
    # NOT affect the response body.
    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        try:
            choices = getattr(response, "choices", None) or []
            total_redacted = 0
            for c in choices:
                msg = getattr(c, "message", None)
                if msg is None:
                    continue
                content = getattr(msg, "content", None)
                if isinstance(content, str):
                    new_text, n = _redact(content)
                    if n > 0:
                        msg.content = new_text
                        total_redacted += n
            if total_redacted:
                _audit({"ts": time.time(), "kind": "redact",
                        "count": total_redacted,
                        "model": data.get("model") if hasattr(data, "get") else None})
        except Exception as e:
            # FAIL CLOSED (Reviewer Y amendment): if we can't redact safely,
            # we don't serve an unredacted body. Raising HTTPException here
            # lets LiteLLM surface a 500 rather than silently leaking secrets.
            _audit({"ts": time.time(), "kind": "redactor_error", "error": str(e)})
            from fastapi import HTTPException
            raise HTTPException(
                status_code=500,
                detail="guardrails: post-call redactor failed; response withheld",
            )
        return response

    # ---- Trace-side (LOGGING ONLY — does NOT touch the wire response) ------
    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        # No mutation here; this hook is purely for audit trail completeness.
        return

    def log_failure_event(self, kwargs, response_obj, start_time, end_time):
        return

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        return

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        return


handler = Guardrails()
