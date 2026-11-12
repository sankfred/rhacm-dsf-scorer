#!/bin/bash
# Step 7: Demo helpers — apply load quota and watch scores
# Usage: bash scripts/06-demo.sh [start|stop|watch|scores|placement] [cluster]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MANIFESTS_DIR="$REPO_ROOT/manifests"
LOAD_QUOTA_MANIFEST="$MANIFESTS_DIR/load-quota.yaml"
ACTION="${1:-watch}"
WATCH_INTERVAL="${WATCH_INTERVAL:-10}"

print_scores() {
  local timestamp cluster region score_output
  timestamp=$(date +%H:%M:%S)
  label_aps_regions
  echo "=== Scores @ ${timestamp} ==="
  for cluster in $(cluster_names); do
    region="$(get_region "$cluster")"
    score_output=$(oc get addonplacementscores cpu-mem-quota-pct-score -n "$cluster" \
      -o jsonpath='{range .status.scores[*]}{.name}={.value}{" "}{end}' 2>/dev/null || true)
    if [ -z "$score_output" ]; then
      score_output=$(oc get addonplacementscores -n "$cluster" \
        -o jsonpath='{range .items[*].status.scores[*]}{.name}={.value}{" "}{end}' 2>/dev/null || true)
    fi
    if [ -n "$score_output" ]; then
      echo "  $cluster ($region)  ${score_output}"
    else
      echo "  $cluster ($region)  (no scores yet)"
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
    echo "=== Applying large load-quota on $LOAD_CLUSTER ==="
    echo "This claims substantial requests.cpu/memory quota, lowering ${LOAD_CLUSTER}'s score."
    KUBECONFIG="$LOAD_KUBECONFIG" oc apply -f "$LOAD_QUOTA_MANIFEST"
    echo "load-quota applied. Watch scores shift with: bash scripts/06-demo.sh watch"
    ;;
  stop)
    LOAD_CLUSTER="${2:-$(first_cluster)}"
    LOAD_KUBECONFIG="/tmp/${LOAD_CLUSTER}-kubeconfig.yaml"
    if [ ! -f "$LOAD_KUBECONFIG" ]; then
      echo "ERROR: $LOAD_KUBECONFIG not found. Run scripts/extract-kubeconfigs.sh first."
      exit 1
    fi
    echo "=== Removing load-quota from $LOAD_CLUSTER ==="
    KUBECONFIG="$LOAD_KUBECONFIG" oc delete -f "$LOAD_QUOTA_MANIFEST" --ignore-not-found
    echo "load-quota removed. Scores will recover within ~60s."
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
  placement)
    echo "=== Applying manifests/placement-quota-scorer.yaml ==="
    oc apply -f "$MANIFESTS_DIR/placement-quota-scorer.yaml"
    echo ""
    oc get placement quota-scorer-placement -n dynamic-scoring
    oc get placementdecision -n dynamic-scoring \
      -l cluster.open-cluster-management.io/placement=quota-scorer-placement \
      -o jsonpath='{range .items[*].status.decisions[*]}{.clusterName}{"\n"}{end}' \
      | sed 's/^/  decided: /'
    ;;
  *)
    echo "Usage: bash scripts/06-demo.sh [start|stop|watch|scores|placement] [cluster]"
    echo "  start [cluster]  — apply large load-quota ResourceQuota (default: $(first_cluster))"
    echo "  stop  [cluster]  — remove load-quota"
    echo "  watch            — refresh score values every ${WATCH_INTERVAL}s"
    echo "  scores           — snapshot current scores"
    echo "  placement        — apply quota-scorer Placement (excludes local-cluster)"
    ;;
esac
