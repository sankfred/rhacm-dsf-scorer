#!/bin/bash
# Live dashboard: polls AddOnPlacementScores and serves a static HTML page.
# Usage:
#   bash scripts/dashboard.sh              # poll + http.server :8080
#   bash scripts/dashboard.sh --no-serve   # poll only
#   DASHBOARD_PORT=9000 bash scripts/dashboard.sh
#
# Open: http://127.0.0.1:8080

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

DASHBOARD_DIR="$REPO_ROOT/dashboard"
TEMPLATE="${TEMPLATE:-$REPO_ROOT/dashboard-src/app.html}"
DATA_FILE="$DASHBOARD_DIR/scores.json"
INDEX_FILE="$DASHBOARD_DIR/index.html"
DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"
START_SERVER=true
HTTP_PID=""

for arg in "$@"; do
  case "$arg" in
    --no-serve) START_SERVER=false ;;
    -h|--help)
      echo "Usage: bash scripts/dashboard.sh [--no-serve]"
      exit 0
      ;;
  esac
done

mkdir -p "$DASHBOARD_DIR"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: missing template $TEMPLATE" >&2
  exit 1
fi

port_in_use() {
  ss -tln 2>/dev/null | grep -qE ":${DASHBOARD_PORT}\s" || \
    netstat -tln 2>/dev/null | grep -qE ":${DASHBOARD_PORT}\s"
}

start_http() {
  # Bind all interfaces so Cursor port-forward / remote browse works
  python3 -m http.server "$DASHBOARD_PORT" --bind 0.0.0.0 --directory "$DASHBOARD_DIR" \
    >/tmp/dsf-dashboard-http.log 2>&1 &
  HTTP_PID=$!
  sleep 0.4
  if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "ERROR: HTTP server failed to start — see /tmp/dsf-dashboard-http.log" >&2
    HTTP_PID=""
    return 1
  fi
  echo "HTTP server started (pid $HTTP_PID) → http://127.0.0.1:${DASHBOARD_PORT}"
}

ensure_http() {
  $START_SERVER || return 0
  if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
    return 0
  fi
  HTTP_PID=""
  if port_in_use; then
    # Adopt existing listener if it serves our directory content
    if curl -fsS "http://127.0.0.1:${DASHBOARD_PORT}/scores.json" >/dev/null 2>&1; then
      return 0
    fi
    echo "WARNING: port ${DASHBOARD_PORT} in use but not serving scores.json" >&2
    return 0
  fi
  start_http || true
}

write_dashboard() {
  local json="$1"
  printf '%s\n' "$json" > "${DATA_FILE}.tmp"
  mv -f "${DATA_FILE}.tmp" "$DATA_FILE"

  python3 - "$TEMPLATE" "$INDEX_FILE" "$json" <<'PY'
import html as h, json, pathlib, sys
from datetime import datetime

tpl = pathlib.Path(sys.argv[1]).read_text()
out_path = pathlib.Path(sys.argv[2])
data = json.loads(sys.argv[3])

def color(score, is_winner):
    if is_winner:
        return "#00ff88"
    if score >= 80:
        return "#4CAF50"
    if score >= 60:
        return "#FFC107"
    if score >= 40:
        return "#FF9800"
    return "#F44336"

by = {}
for d in data:
    try:
        score = float(d["score"])
    except (KeyError, TypeError, ValueError):
        continue
    name = d.get("cluster")
    if not name:
        continue
    by[name] = {"score": score, "dimension": d.get("dimension") or ""}

names = list(by.keys())
if not names:
    clusters = '<div class="status" style="color:#FF9800">No scores yet</div>'
    status = "Waiting for AddOnPlacementScore data from the hub…"
else:
    winner = max(names, key=lambda n: by[n]["score"])
    parts = []
    for name in names:
        info = by[name]
        is_winner = name == winner
        c = color(info["score"], is_winner)
        pct = max(0, min(100, info["score"]))
        cls = "cluster winner" if is_winner else "cluster"
        parts.append(
            f'<div class="{cls}" id="c-{h.escape(name)}">'
            f'<div class="score-value" style="color:{c}">{int(round(info["score"]))}</div>'
            f'<div class="bar-container"><div class="bar" style="height:{pct}%;background:{c}"></div></div>'
            f'<div class="cluster-name">{h.escape(name)}</div>'
            f'<div class="region">{h.escape(info["dimension"])}</div>'
            f"</div>"
        )
    clusters = "\n".join(parts)
    status = f"Last update: {datetime.now().strftime('%H:%M:%S')} — auto-refreshes via dashboard.sh"

html_out = (
    tpl.replace("__CLUSTERS_HTML__", clusters)
       .replace("__STATUS_HTML__", h.escape(status))
)
out_path.write_text(html_out)
PY
}

cleanup() {
  if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    echo "Stopped HTTP server (pid $HTTP_PID)"
  fi
}
trap cleanup EXIT INT TERM

# Seed so the first browser hit isn't empty
write_dashboard '[]'
ensure_http

if $START_SERVER; then
  echo "Open http://127.0.0.1:${DASHBOARD_PORT}"
else
  echo "HTTP server not started (--no-serve)."
  echo "  python3 -m http.server ${DASHBOARD_PORT} --directory $DASHBOARD_DIR"
fi

echo "Writing scores every 10s (Ctrl+C to stop)"
echo "Clusters: $(cluster_names)"
echo ""

while true; do
  ensure_http

  JSON='['
  FIRST=true
  for cluster in $(cluster_names); do
    SCORES=$(oc get addonplacementscores cpu-mem-quota-pct-score -n "$cluster" \
      -o jsonpath='{range .status.scores[*]}{.name}:{.value},{end}' 2>/dev/null || echo "")
    if [ -z "$SCORES" ]; then
      SCORES=$(oc get addonplacementscores -n "$cluster" \
        -o jsonpath='{range .items[*].status.scores[*]}{.name}:{.value},{end}' 2>/dev/null || echo "")
    fi
    if [ -n "$SCORES" ]; then
      IFS=',' read -ra PAIRS <<< "$SCORES"
      for pair in "${PAIRS[@]}"; do
        [ -z "$pair" ] && continue
        NAME="${pair%%:*}"
        VALUE="${pair##*:}"
        if ! [[ "$VALUE" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
          continue
        fi
        if [ "$FIRST" = true ]; then FIRST=false; else JSON+=','; fi
        JSON+="{\"cluster\":\"$cluster\",\"dimension\":\"$NAME\",\"score\":$VALUE}"
      done
    fi
  done
  JSON+=']'

  write_dashboard "$JSON"
  echo "[$(date +%H:%M:%S)] Updated scores → http://127.0.0.1:${DASHBOARD_PORT}"
  sleep 10
done
