#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="${ROOT}/compose"
BASE="${COMPOSE_DIR}/docker-compose.base.yml"

usage() {
  cat <<'EOF'
Usage: ./scripts/stack.sh <up|down|logs|ps|pull> [local|staging|prod]

  up local    — build sibling repos and start with tls internal on localhost
  up staging  — pull ghcr.io images tagged FRONTEND_TAG / PANEL_TAG (env/stack.env)
  up prod     — pull SHA-pinned images; host-based TLS (SITE_DOMAIN, PANEL_DOMAIN)
  pull        — docker compose pull (staging/prod). Does not build.
  down        — stop stack (same overlay as last up if passed)

Image tags come from env/stack.env if that file exists (FRONTEND_TAG, PANEL_TAG).
Prod must pin a git SHA, never the moving staging tag.
EOF
}

cmd="${1:-}"
overlay="${2:-local}"

if [[ -z "$cmd" ]]; then
  usage
  exit 1
fi

if [[ -f "${ROOT}/env/stack.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/env/stack.env"
  set +a
fi

case "$overlay" in
  local)   OVERLAY="${COMPOSE_DIR}/docker-compose.local.yml" ;;
  staging) OVERLAY="${COMPOSE_DIR}/staging.yml" ;;
  prod)    OVERLAY="${COMPOSE_DIR}/prod.yml" ;;
  *)
    echo "Unknown overlay: $overlay (expected local, staging, or prod)" >&2
    exit 1
    ;;
esac

compose() {
  docker compose -f "$BASE" -f "$OVERLAY" "$@"
}

case "$cmd" in
  up)
    if [[ "$overlay" == "local" ]]; then
      compose up -d --build --remove-orphans
    else
      compose up -d --pull always --remove-orphans
    fi
    ;;
  down)
    compose down --remove-orphans
    ;;
  logs)
    compose logs -f "${@:3}"
    ;;
  ps)
    compose ps
    ;;
  pull)
    compose pull
    ;;
  *)
    usage
    exit 1
    ;;
esac
