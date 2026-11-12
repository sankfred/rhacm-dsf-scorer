#!/bin/bash
# Step 6: Verify the full DSF scorer deployment
# Usage: bash scripts/05-verify.sh [cluster1 cluster2 ...]
# Default: all clusters from clusters.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLUSTERS="${@:-$(cluster_names)}"

echo "=== Step 5: Verify ==="

echo ""
echo "--- DSF Addon Status (hub) ---"
oc get managedclusteraddon -A | grep dynamic-scoring || echo "No dynamic-scoring addons found"

for cluster in $CLUSTERS; do
  KUBECONFIG_FILE="/tmp/${cluster}-kubeconfig.yaml"

  echo ""
  echo "--- $cluster ---"

  if [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "  SKIP: $KUBECONFIG_FILE not found"
    continue
  fi

  # Scorer pod
  echo "  Scorer pod:"
  KUBECONFIG="$KUBECONFIG_FILE" oc get pods -n dynamic-scoring 2>/dev/null | grep rhacm-scorer || echo "    Not found"

  # DSF agent pod
  echo "  DSF agent:"
  KUBECONFIG="$KUBECONFIG_FILE" oc get pods -n dynamic-scoring 2>/dev/null | grep dynamic-scoring-agent || echo "    Not found"

  # Route
  echo "  Route:"
  KUBECONFIG="$KUBECONFIG_FILE" oc get route -n dynamic-scoring 2>/dev/null || echo "    Not found"

  # ConfigMap
  echo "  ConfigMap:"
  KUBECONFIG="$KUBECONFIG_FILE" oc get configmap dynamic-scoring-config -n dynamic-scoring 2>/dev/null && echo "    Present" || echo "    Not found (may take ~1 min)"

  # Baseline example ResourceQuota (small quota should exist for non-zero scores;
  # score 0 often means no quotas present or quota is at full capacity)
  echo "  Example ResourceQuota:"
  KUBECONFIG="$KUBECONFIG_FILE" oc get resourcequota demo-compute-quota -n quota-demo 2>/dev/null \
    || echo "    Not found (apply manifests/example-resourcequota.yaml)"
done

echo ""
echo "--- AddOnPlacementScores (hub) ---"
label_aps_regions
oc get addonplacementscores -A -o custom-columns="CLUSTER:.metadata.namespace,REGION:.metadata.labels.region,NAME:.metadata.name,SCORE:.status.scores[0].value" 2>/dev/null \
  || oc get addonplacementscores -A 2>/dev/null \
  || echo "None found yet (agent fires every 60s)"

echo ""
echo "--- Placement (dynamic-scoring/quota-scorer-placement) ---"
if oc get placement quota-scorer-placement -n dynamic-scoring >/dev/null 2>&1; then
  oc get placement quota-scorer-placement -n dynamic-scoring
  oc get placementdecision -n dynamic-scoring \
    -l cluster.open-cluster-management.io/placement=quota-scorer-placement \
    -o jsonpath='{range .items[*].status.decisions[*]}{.clusterName}{"\n"}{end}' 2>/dev/null \
    | sed 's/^/  decided: /'
else
  echo "  Not found — run: oc apply -f manifests/placement-quota-scorer.yaml"
fi

echo ""
echo "=== Verification complete ==="
