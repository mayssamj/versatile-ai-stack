#!/usr/bin/env python3
"""Regression test for the 2026-07-05 takeover fix: the claw3d bridge must never
return a secret (PI_LITELLM_KEY / sk-.../ Bearer token) to the browser client, and
a Pi subprocess timeout must not leak the argv-embedded key.

Hermetic: imports bridge.py (stdlib-only, no import-time side effects) and exercises
_redact plus a simulated subprocess.TimeoutExpired string. No network, no sandbox.
Run: python3 claw3d-bridge/test_bridge_redact.py
"""
import os, sys, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bridge  # noqa: E402

PASS = 0
FAIL = 0
def ok(m):  global PASS; PASS += 1; print(f"  ok   {m}")
def bad(m): global FAIL; FAIL += 1; print(f"  FAIL {m}")

KEY = "sk-local-deadbeefcafef00d1234567890abcdef"

# 1) A raw PI_LITELLM_KEY=... assignment (as embedded in the pi argv) is scrubbed.
s = f"env PI_LITELLM_KEY={KEY} HOME=/sandbox /sandbox/node_modules/.bin/pi"
r = bridge._redact(s)
if KEY not in r and "PI_LITELLM_KEY=***" in r: ok("PI_LITELLM_KEY=... assignment redacted")
else: bad(f"PI_LITELLM_KEY assignment not redacted: {r!r}")

# 2) A bare sk-... token anywhere is scrubbed.
r2 = bridge._redact(f"auth failed with token {KEY} rejected")
if KEY not in r2: ok("bare sk-... token redacted")
else: bad(f"bare sk-... token leaked: {r2!r}")

# 3) A Bearer header value is scrubbed.
r3 = bridge._redact("Authorization: Bearer sk-abc123XYZ._-def")
if "sk-abc123" not in r3 and "Bearer ***" in r3: ok("Bearer token redacted")
else: bad(f"Bearer token leaked: {r3!r}")

# 4) The EXACT leak vector: str(subprocess.TimeoutExpired) embeds the full argv
#    including PI_LITELLM_KEY=<key>. The redactor must scrub it. This is what the
#    old do_POST returned verbatim to the browser on a Pi timeout.
cmd = ["openshell", "sandbox", "exec", "-n", "pi-v1", "--",
       "env", f"PI_LITELLM_KEY={KEY}", "HOME=/sandbox", "/sandbox/node_modules/.bin/pi"]
te = subprocess.TimeoutExpired(cmd, 615)
leak = bridge._redact(f"[Pi unavailable] {te}")
if KEY not in leak: ok("simulated TimeoutExpired string is scrubbed of the key")
else: bad(f"TimeoutExpired string LEAKED the key: {leak!r}")

# 5) run_pi converts a real subprocess timeout into a clean, key-free RuntimeError
#    (root-cause fix — the argv never enters the exception). Stub subprocess.run to
#    raise TimeoutExpired, and stub the helpers run_pi calls before it.
orig_run = subprocess.run
bridge.subprocess.run = lambda *a, **k: (_ for _ in ()).throw(subprocess.TimeoutExpired(cmd, 615))
bridge._sandbox_ready = lambda s: True   # skip the pre-check so we exercise the timeout path
bridge._safe_model = lambda m: "local"
bridge._prewarm_lmstudio = lambda m: None
bridge._openshell = lambda: "openshell"
bridge._get_env = lambda k, *a: KEY if k == "PI_LITELLM_KEY" else (a[0] if a else "")
try:
    bridge.run_pi("hello", "local")
    bad("run_pi did not raise on timeout")
except RuntimeError as e:
    if KEY not in str(e) and "timed out" in str(e): ok("run_pi timeout raises a clean, key-free error")
    else: bad(f"run_pi timeout error leaked the key: {e!r}")
except Exception as e:  # noqa: BLE001
    bad(f"run_pi raised unexpected {type(e).__name__}: {e!r}")
finally:
    bridge.subprocess.run = orig_run

print(f"\nRESULT: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
