#!/bin/bash
# Step 5: Register the scorer with DSF on the hub
# Updates configURL in dynamicscorer.yaml to point to the first cluster's Route
# Usage: bash scripts/04-register-scorer.sh [primary-cluster]
# Default: first cluster from clusters.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PRIMARY="${1:-$(first_cluster)}"
MANIFESTS_DIR="$REPO_ROOT/manifests"
KUBECONFIG_FILE="/tmp/${PRIMARY}-kubeconfig.yaml"

echo "=== Step 4: Register Scorer on Hub ==="
echo "Primary cluster for configURL: $PRIMARY"

# Get apps domain for configURL
if [ -f "$KUBECONFIG_FILE" ]; then
  APPS_DOMAIN=$(KUBECONFIG="$KUBECONFIG_FILE" \
    oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  CONFIG_URL="http://rhacm-scorer-dynamic-scoring.${APPS_DOMAIN}/config"
  echo "configURL: $CONFIG_URL"

  # Update dynamicscorer.yaml
  sed -i.bak "s|configURL: .*|configURL: ${CONFIG_URL}|g" "$MANIFESTS_DIR/dynamicscorer.yaml"
  rm -f "$MANIFESTS_DIR/dynamicscorer.yaml.bak"
else
  echo "WARNING: $KUBECONFIG_FILE not found, using existing configURL in dynamicscorer.yaml"
fi

oc apply -f "$MANIFESTS_DIR/dynamicscorer.yaml"
oc apply -f "$MANIFESTS_DIR/dynamicscoringconfig.yaml"

echo ""
echo "Applying quota-scorer Placement (excludes local-cluster)..."
oc apply -f "$MANIFESTS_DIR/placement-quota-scorer.yaml"

echo ""
echo "Done. DynamicScorer, DynamicScoringConfig, and Placement applied."
echo "Hub pulls /config from the primary cluster Route; /config must advertise"
echo "scoring.host=http://rhacm-scorer.dynamic-scoring.svc:8000 so each spoke scores locally."
