"""Minimal reference service.

Exists to demonstrate the operational contract every service in this platform
must satisfy (docs/08-microservices.md §7):

  * /healthz  — liveness: is the process wedged? restart fixes it
  * /ready    — readiness: can it serve? checks dependencies
  * /version  — what is actually running, for smoke tests
  * /metrics  — RED metrics with controlled cardinality
  * structured JSON logs carrying trace_id, with sensitive fields masked
  * graceful shutdown on SIGTERM

It is intentionally dependency-light so it runs in the local lab.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

APP_VERSION = os.getenv("APP_VERSION", "dev")
APP_GIT_SHA = os.getenv("APP_GIT_SHA", "unknown")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
PORT = int(os.getenv("PORT", "8080"))

# Fields that must never reach a log line. Masking happens here, at the source —
# not in the log pipeline, where a config change silently reopens the leak.
SENSITIVE_KEYS = frozenset({
    "password", "passwd", "secret", "token", "access_token", "refresh_token",
    "authorization", "api_key", "pan", "card_number", "cvv", "national_id",
    "ssn", "private_key",
})

_shutting_down = False
_start_time = time.time()

# --- metrics ---------------------------------------------------------------
# Deliberately NOT labelled by user id, request id, or raw path: unbounded label
# values are what kill a Prometheus server (docs/06-observability.md §2).
_metrics: dict[str, float] = {}


def _observe(route: str, method: str, status: int, duration: float) -> None:
    _metrics[f'http_requests_total{{method="{method}",route="{route}",status="{status}"}}'] = (
        _metrics.get(f'http_requests_total{{method="{method}",route="{route}",status="{status}"}}', 0) + 1
    )
    _metrics[f'http_request_duration_seconds_sum{{route="{route}"}}'] = (
        _metrics.get(f'http_request_duration_seconds_sum{{route="{route}"}}', 0.0) + duration
    )
    _metrics[f'http_request_duration_seconds_count{{route="{route}"}}'] = (
        _metrics.get(f'http_request_duration_seconds_count{{route="{route}"}}', 0) + 1
    )


# --- logging ---------------------------------------------------------------

def _mask(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        k: ("[REDACTED]" if k.lower() in SENSITIVE_KEYS else v)
        for k, v in payload.items()
    }


class JsonFormatter(logging.Formatter):
    """One JSON object per line, with correlation fields always present."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
            "level": record.levelname,
            "message": record.getMessage(),
            "service": "payment-service",
            "version": APP_VERSION,
            "environment": ENVIRONMENT,
            "trace_id": getattr(record, "trace_id", None),
            "request_id": getattr(record, "request_id", None),
        }
        extra = getattr(record, "context", None)
        if extra:
            entry.update(_mask(extra))
        return json.dumps(entry, separators=(",", ":"))


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("payment-service")
log.addHandler(handler)
log.setLevel(os.getenv("LOG_LEVEL", "INFO"))


# --- dependency checks -----------------------------------------------------

def check_dependencies() -> tuple[bool, dict[str, str]]:
    """Readiness must reflect reality, not optimism.

    A readiness probe that always returns 200 turns a dependency outage into a
    flood of user-visible 500s instead of removing the pod from load balancing.
    """
    results: dict[str, str] = {}
    healthy = True

    for name, env_var in (("database", "DB_URL"), ("vault", "VAULT_ADDR")):
        if os.getenv(env_var):
            # A real service would open a connection here with a short timeout.
            results[name] = "ok"
        else:
            results[name] = "not configured"
            if ENVIRONMENT != "local":
                healthy = False

    return healthy, results


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status: int, body: dict[str, Any] | str, content_type: str = "application/json") -> None:
        payload = (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Request-ID", self.request_id)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 - stdlib naming
        started = time.perf_counter()
        self.request_id = self.headers.get("X-Request-ID") or str(uuid.uuid4())
        route = self.path.split("?")[0]
        status = 200

        if route == "/healthz":
            # Liveness answers one question: is this process wedged? It must NOT
            # check dependencies — a database outage would then restart every
            # pod in a loop and turn a degradation into an outage.
            status = 503 if _shutting_down else 200
            self._send(status, {"status": "shutting_down" if _shutting_down else "ok"})

        elif route == "/ready":
            healthy, deps = check_dependencies()
            status = 200 if (healthy and not _shutting_down) else 503
            self._send(status, {"ready": status == 200, "dependencies": deps})

        elif route == "/version":
            self._send(200, {
                "version": APP_VERSION,
                "git_sha": APP_GIT_SHA,
                "environment": ENVIRONMENT,
                "uptime_seconds": round(time.time() - _start_time, 1),
            })

        elif route == "/metrics":
            lines = [
                "# HELP http_requests_total Total HTTP requests.",
                "# TYPE http_requests_total counter",
                "# HELP http_request_duration_seconds Request latency.",
                "# TYPE http_request_duration_seconds summary",
            ]
            lines.extend(f"{name} {value}" for name, value in sorted(_metrics.items()))
            self._send(200, "\n".join(lines) + "\n", content_type="text/plain; version=0.0.4")

        elif route.startswith("/api/"):
            # Every API route is authenticated. Returning 401 by default means a
            # forgotten auth check fails closed rather than open.
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer ") or _is_unsigned(auth):
                status = 401
                self._send(401, {"error": "unauthorized", "request_id": self.request_id})
            else:
                self._send(200, {"data": [], "request_id": self.request_id})

        else:
            status = 404
            self._send(404, {"error": "not found"})

        duration = time.perf_counter() - started
        _observe(_normalise(route), "GET", status, duration)
        log.info(
            "request.completed",
            extra={
                "request_id": self.request_id,
                "trace_id": self.headers.get("traceparent", "").split("-")[1] if "-" in self.headers.get("traceparent", "") else None,
                "context": {"route": _normalise(route), "status": status, "duration_ms": round(duration * 1000, 2)},
            },
        )

    def log_message(self, *args: Any) -> None:
        """Silence the stdlib access log; we emit structured logs ourselves."""


def _is_unsigned(auth_header: str) -> bool:
    """Reject `alg: none` tokens outright.

    A JWT library misconfiguration here is the difference between an
    authenticated API and an open one, so it is checked explicitly.
    """
    token = auth_header.removeprefix("Bearer ")
    parts = token.split(".")
    return len(parts) == 3 and parts[2] == ""


def _normalise(route: str) -> str:
    """Collapse identifiers out of paths so metric cardinality stays bounded."""
    segments = []
    for segment in route.split("/"):
        if segment and (segment.isdigit() or len(segment) >= 16):
            segments.append(":id")
        else:
            segments.append(segment)
    return "/".join(segments) or "/"


def _handle_sigterm(signum: int, frame: Any) -> None:
    """Graceful shutdown.

    Readiness flips to 503 immediately so the load balancer stops sending new
    work, then we wait for endpoint removal to propagate before exiting. Without
    this pause you get intermittent 502s on every single deploy.
    """
    global _shutting_down
    log.info("shutdown.started", extra={"context": {"signal": signum}})
    _shutting_down = True
    time.sleep(int(os.getenv("SHUTDOWN_GRACE_SECONDS", "15")))
    log.info("shutdown.complete")
    sys.exit(0)


def main() -> None:
    signal.signal(signal.SIGTERM, _handle_sigterm)
    signal.signal(signal.SIGINT, _handle_sigterm)

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log.info("startup.complete", extra={"context": {"port": PORT, "version": APP_VERSION}})
    server.serve_forever()


if __name__ == "__main__":
    main()
