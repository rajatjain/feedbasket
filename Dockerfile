FROM node:22-bookworm-slim AS readability
WORKDIR /opt/readability
COPY backend/package.json backend/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

FROM ghcr.io/astral-sh/uv:0.8.4 AS uv

FROM python:3.13-slim-bookworm AS build
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy
WORKDIR /app
COPY backend/pyproject.toml backend/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project
COPY backend/feedbasket ./feedbasket
COPY backend/migrations ./migrations
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-editable

FROM python:3.13-slim-bookworm
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FEEDBASKET_CONFIG=/app/feedbasket.toml \
    FEEDBASKET_NODE_DIR=/opt/readability
WORKDIR /app
COPY --from=build /app/.venv /app/.venv
COPY --from=readability /usr/local/bin/node /usr/local/bin/node
COPY --from=readability /opt/readability /opt/readability
COPY backend/feedbasket.docker.toml /app/feedbasket.toml
RUN mkdir /data /backups && chown 1000:1000 /data /backups
USER 1000:1000
EXPOSE 12000
CMD ["feedbasket"]
