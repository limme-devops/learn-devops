# syntax=docker/dockerfile:1.7
#
# Multi-stage, distroless, non-root, no shell in the final image.
# The base images are digest-pinned to internal mirrors — a tag on a base image
# means your "reproducible" build silently changes underneath you.

# ---------- builder ----------
FROM harbor.bank.internal/mirror/python:3.12-slim AS builder

WORKDIR /build

# Install into a venv so exactly one directory needs copying to the runtime.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
# BuildKit cache mount: fast rebuilds without baking a pip cache into a layer.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --require-hashes --no-deps -r requirements.txt

COPY src/ ./src/

# Byte-compile now so the read-only root filesystem at runtime does not have to.
RUN python -m compileall -q ./src

# ---------- runtime ----------
FROM harbor.bank.internal/mirror/gcr.io/distroless/python3-debian12:nonroot

# OCI labels: these are what make an image traceable back to a commit during an
# incident, and they feed the SBOM and the registry UI.
ARG VERSION=dev
ARG GIT_SHA=unknown
ARG BUILD_DATE
LABEL org.opencontainers.image.title="payment-service" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://gitlab.bank.internal/apps/payment-service" \
      org.opencontainers.image.vendor="Bank Platform Engineering" \
      bank.internal/data-class="restricted" \
      bank.internal/owner="payments-team"

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /build/src /app/src

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION="${VERSION}" \
    APP_GIT_SHA="${GIT_SHA}"

# UID 10001, matching the pod securityContext and the systemd unit on the VM
# track. Distroless "nonroot" is 65532; we set it explicitly so the same number
# appears in every place a human might check.
USER 10001:10001

EXPOSE 8080 9090

# No HEALTHCHECK instruction: Kubernetes probes and the systemd unit own health
# checking, and a container-level healthcheck here would just be a third,
# divergent definition of "healthy".

ENTRYPOINT ["python", "-m", "src.main"]
