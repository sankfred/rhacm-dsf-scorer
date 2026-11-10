#!/bin/bash
# Step 7: Demo helpers — generate load and watch scores
# Usage: bash scripts/06-demo.sh [start|stop|watch|scores] [cluster]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MANIFESTS_DIR="$REPO_ROOT/manifests"
ACTION="${1:-watch}"
WATCH_INTERVAL="${WATCH_INTERVAL:-10}"

print_scores() {
  local timestamp
  timestamp=$(date +%H:%M:%S)
  echo "=== Scores @ ${timestamp} ==="
  for cluster in $(cluster_names); do
    local score_output
    score_output=$(oc get addonplacementscores cpu-mem-quota-pct-score -n "$cluster" \
      -o jsonpath='{range .status.scores[*]}{.name}={.value}{" "}{end}' 2>/dev/null || true)
    if [ -z "$score_output" ]; then
      score_output=$(oc get addonplacementscores -n "$cluster" \
        -o jsonpath='{range .items[*].status.scores[*]}{.name}={.value}{" "}{end}' 2>/dev/null || true)
    fi
    if [ -n "$score_output" ]; then
      echo "  $cluster  ${score_output}"
    else
      echo "  $cluster  (no scores yet)"
    fi
  done
}

case "$ACTION" in
  start)
    LOAD_CLUSTER="${2:-$(first_cluster)}"
    LOAD_KUBECONFIG="/tmp/${LOAD_CLUSTER}-kubeconfig.yaml"
    if [ ! -f "$LOAD_KUBECONFIG" ]; then
      echo "ERROR: $LOAD_KUBECONFIG not found. Run scripts/extract-kubeconfigs.sh first."
      exit 1
    fi
    echo "=== Starting load generator on $LOAD_CLUSTER ==="
    echo "This will drive CPU usage up, lowering ${LOAD_CLUSTER}'s score."
    KUBECONFIG="$LOAD_KUBECONFIG" oc apply -f "$MANIFESTS_DIR/load-generator.yaml"
    echo "Load generator applied. Watch scores shift with: bash scripts/06-demo.sh watch"
    ;;
  stop)
    LOAD_CLUSTER="${2:-$(first_cluster)}"
    LOAD_KUBECONFIG="/tmp/${LOAD_CLUSTER}-kubeconfig.yaml"
    echo "=== Stopping load generator on $LOAD_CLUSTER ==="
    KUBECONFIG="$LOAD_KUBECONFIG" oc delete -f "$MANIFESTS_DIR/load-generator.yaml" --ignore-not-found
    echo "Load generator removed. Scores will recover within ~60s."
    ;;
  watch)
    echo "=== Watching placement scores every ${WATCH_INTERVAL}s (Ctrl+C to stop) ==="
    echo ""
    while true; do
      print_scores
      echo ""
      sleep "$WATCH_INTERVAL"
    done
    ;;
  scores)
    print_scores
    ;;
  *)
    echo "Usage: bash scripts/06-demo.sh [start|stop|watch|scores] [cluster]"
    echo "  start [cluster]  — apply load generator (default: $(first_cluster))"
    echo "  stop  [cluster]  — remove load generator"
    echo "  watch            — refresh score values every ${WATCH_INTERVAL}s"
    echo "  scores           — snapshot current scores"
    ;;
esac
