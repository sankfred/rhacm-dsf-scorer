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

# Scorer capacity model: 20*24 CPU, ~20*84Gi memory.
BUDGET_CPU=480
BUDGET_MEM_GI=1680

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

# Build a load-quota manifest that claims (40% ± 10pp) of budget.
# +10 score points → claim 30%; -10 score points → claim 50%.
render_load_quota_manifest() {
  local out="$1" jitter_score="$2"
  local pct cpu mem limits_cpu limits_mem
  # 40% baseline; jitter_score is +10 or -10 applied to resulting headroom score
  pct=$((40 - jitter_score))
  cpu=$((BUDGET_CPU * pct / 100))
  mem=$((BUDGET_MEM_GI * pct / 100))
  limits_cpu=$((cpu * 2))
  limits_mem=$((mem * 2))
  cat >"$out" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: load-quota
  labels:
    app.kubernetes.io/part-of: rhacm-dsf-scorer
    app.kubernetes.io/name: load-quota
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: load-quota
  namespace: load-quota
  labels:
    app.kubernetes.io/part-of: rhacm-dsf-scorer
    app.kubernetes.io/name: load-quota
  annotations:
    demo.rhacm-dsf-scorer/score-jitter: "${jitter_score}"
spec:
  hard:
    requests.cpu: "${cpu}"
    requests.memory: ${mem}Gi
    limits.cpu: "${limits_cpu}"
    limits.memory: ${limits_mem}Gi
    pods: "200"
EOF
  echo "Rendered load-quota at ${pct}% of budget (cpu=${cpu}, mem=${mem}Gi) for score jitter ${jitter_score:+}${jitter_score}"
}

apply_load_quota() {
  local cluster="$1" jitter="$2"
  local kubeconfig="/tmp/${cluster}-kubeconfig.yaml"
  local tmp
  if [ ! -f "$kubeconfig" ]; then
    echo "ERROR: $kubeconfig not found. Run scripts/extract-kubeconfigs.sh first."
    return 1
  fi
  tmp="$(mktemp)"
  render_load_quota_manifest "$tmp" "$jitter"
  echo "=== Applying load-quota on $cluster (40% budget, score jitter ${jitter:+}${jitter}) ==="
  KUBECONFIG="$kubeconfig" oc apply -f "$tmp"
  rm -f "$tmp"
}

remove_load_quota() {
  local cluster="$1"
  local kubeconfig="/tmp/${cluster}-kubeconfig.yaml"
  if [ ! -f "$kubeconfig" ]; then
    echo "ERROR: $kubeconfig not found. Run scripts/extract-kubeconfigs.sh first."
    return 1
  fi
  echo "=== Removing load-quota from $cluster ==="
  KUBECONFIG="$kubeconfig" oc delete -f "$LOAD_QUOTA_MANIFEST" --ignore-not-found
  # Also delete by name in case a rendered manifest differed from the template
  KUBECONFIG="$kubeconfig" oc delete resourcequota load-quota -n load-quota --ignore-not-found >/dev/null 2>&1 || true
  KUBECONFIG="$kubeconfig" oc delete ns load-quota --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

case "$ACTION" in
  start)
    TARGET="${2:-all}"
    fix_scoring_endpoints
    if [ "$TARGET" = "all" ]; then
      # Opposite ±10 on successive clusters so scores always diverge.
      if [ "$((RANDOM % 2))" -eq 0 ]; then
        JITTER=10
      else
        JITTER=-10
      fi
      for cluster in $(cluster_names); do
        apply_load_quota "$cluster" "$JITTER"
        JITTER=$((-JITTER))
      done
    else
      if [ "$((RANDOM % 2))" -eq 0 ]; then
        JITTER=10
      else
        JITTER=-10
      fi
      apply_load_quota "$TARGET" "$JITTER"
    fi
    echo "load-quota applied. Watch scores shift with: bash scripts/06-demo.sh watch"
    ;;
  stop)
    TARGET="${2:-all}"
    if [ "$TARGET" = "all" ]; then
      for cluster in $(cluster_names); do
        remove_load_quota "$cluster"
      done
    else
      remove_load_quota "$TARGET"
    fi
    echo "load-quota removed. Scores update within ~30s."
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
    echo "Usage: bash scripts/06-demo.sh [start|stop|watch|scores|placement] [cluster|all]"
    echo "  start [cluster|all]  — apply load-quota at 40%±10 score points (default: all; opposite jitter per cluster)"
    echo "  stop  [cluster|all]  — remove load-quota (default: all)"
    echo "  watch            — refresh score values every ${WATCH_INTERVAL}s"
    echo "  scores           — snapshot current scores"
    echo "  placement        — apply quota-scorer Placement (excludes local-cluster)"
    ;;
esac
