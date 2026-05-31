# LiteLLM custom callback — appends one JSON line per call to /traces/litellm.jsonl.
# Loaded by config.yaml via:  callbacks: ["trace_to_file.handler", ...]
#
# Notes:
#   - TRACE_FILE env var is set by the start-litellm.sh script.
#   - File writes are best-effort; failures are logged but never raised.
#   - Thread-safe append via a module-level lock.
from litellm.integrations.custom_logger import CustomLogger
import json
import os
import time
import threading

TRACE_PATH = os.getenv("TRACE_FILE", "/traces/litellm.jsonl")
# Reviewer Y-18: rotate before unbounded growth becomes a day-90 disk pressure
# problem. 100MB chunks; rotated files keep an ISO-ish timestamp suffix.
ROTATE_BYTES = int(os.getenv("TRACE_ROTATE_BYTES", str(100 * 1024 * 1024)))
_lock = threading.Lock()


def _maybe_rotate():
    try:
        sz = os.path.getsize(TRACE_PATH)
    except OSError:
        return
    if sz < ROTATE_BYTES:
        return
    ts = time.strftime("%Y%m%d-%H%M%S")
    try:
        os.rename(TRACE_PATH, f"{TRACE_PATH}.{ts}")
    except OSError:
        # Couldn't rotate (race or perms); fall through — next write reopens.
        pass


def _write(rec):
    try:
        os.makedirs(os.path.dirname(TRACE_PATH), exist_ok=True)
        with _lock:
            _maybe_rotate()
            with open(TRACE_PATH, "a") as f:
                f.write(json.dumps(rec, default=str) + "\n")
    except Exception as e:
        print(f"trace_to_file: write failed: {e}")


class TraceToFile(CustomLogger):
    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        _write({
            "ts": time.time(),
            "kind": "success",
            "model": kwargs.get("model"),
            "user": kwargs.get("user"),
            "messages": kwargs.get("messages"),
            "response": getattr(response_obj, "model_dump", lambda: response_obj)(),
            "latency_ms": (end_time - start_time).total_seconds() * 1000,
            "cost": kwargs.get("response_cost", 0),
        })

    def log_failure_event(self, kwargs, response_obj, start_time, end_time):
        _write({
            "ts": time.time(),
            "kind": "failure",
            "model": kwargs.get("model"),
            "error": str(kwargs.get("exception")) or str(response_obj),
            "latency_ms": (end_time - start_time).total_seconds() * 1000,
        })

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        self.log_success_event(kwargs, response_obj, start_time, end_time)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        self.log_failure_event(kwargs, response_obj, start_time, end_time)


handler = TraceToFile()
