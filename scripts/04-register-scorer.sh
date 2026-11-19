#!/bin/bash
# Step 5: Register the scorer with DSF on the hub
# PromQL / scoring: manifests/dynamicscorer.yaml (source.params, scoring.*).
# With configSyncMode: None, configURL may be a dummy placeholder — do not rewrite it.
# Usage: bash scripts/04-register-scorer.sh [primary-cluster]
# Default: first cluster from clusters.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PRIMARY="${1:-$(first_cluster)}"
MANIFESTS_DIR="$REPO_ROOT/manifests"

echo "=== Step 4: Register Scorer on Hub ==="
echo "Primary cluster (reference): $PRIMARY"
echo "Applying DynamicScorer from manifests/dynamicscorer.yaml (no configURL rewrite)."

oc apply -f "$MANIFESTS_DIR/dynamicscorer.yaml"
oc apply -f "$MANIFESTS_DIR/dynamicscoringconfig.yaml"

echo ""
echo "Applying quota-scorer Placement (excludes local-cluster)..."
oc apply -f "$MANIFESTS_DIR/placement-quota-scorer.yaml"

echo ""
echo "Deploying hub AddOnPlacementScore exporter (MODE=exporter on :9000/metrics)..."
oc apply -f "$MANIFESTS_DIR/exporter-hub.yaml"

if oc get mco observability >/dev/null 2>&1; then
  echo "Allowlisting exporter metric for ACM Observability Thanos..."
  oc apply -f "$MANIFESTS_DIR/observability-metrics-custom-allowlist.yaml"
fi

echo ""
echo "Repairing per-cluster scoringEndpoint (DSF may point agents at Thanos)..."
sleep 15
fix_scoring_endpoints

echo ""
echo "Done. DynamicScorer, DynamicScoringConfig, Placement, and exporter applied."
echo "PromQL: DynamicScorer.spec.source.params.query"
echo "scoring.host=http://rhacm-scorer.dynamic-scoring.svc:8000 so each spoke scores locally."
echo "Exporter metrics: oc -n addonplacementscore-exporter port-forward svc/addonplacementscore-exporter 9000"
