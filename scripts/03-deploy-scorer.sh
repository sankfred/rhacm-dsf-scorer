#!/bin/bash
# Step 3+4: Deploy scorer to managed clusters via ManifestWork
# Generates ManifestWorks from template at runtime, discovers apps domains,
# creates tokens, and applies everything.
# Usage: bash scripts/03-deploy-scorer.sh [cluster1 cluster2 ...]
# Default: all clusters from clusters.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MANIFESTS_DIR="$REPO_ROOT/manifests"
GENERATED_DIR="$MANIFESTS_DIR/generated"
TEMPLATE="$MANIFESTS_DIR/manifestwork.yaml.example"

CLUSTERS="${@:-$(cluster_names)}"
IMAGE="${IMAGE:-quay.io/sfredenb/quota-scorer:latest}"

mkdir -p "$GENERATED_DIR"

echo "=== Step 3+4: Deploy Quota Scorer ==="
echo "IMAGE: $IMAGE"

for cluster in $CLUSTERS; do
  echo ""
  echo "--- $cluster ---"

  KUBECONFIG_FILE="/tmp/${cluster}-kubeconfig.yaml"
  MANIFEST="$GENERATED_DIR/manifestwork-${cluster}.yaml"
  REGION=$(get_region "$cluster")

  if [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "ERROR: $KUBECONFIG_FILE not found. Run: bash scripts/extract-kubeconfigs.sh"
    continue
  fi

  echo "Getting apps domain..."
  APPS_DOMAIN=$(KUBECONFIG="$KUBECONFIG_FILE" \
    oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

  if [ -z "$APPS_DOMAIN" ]; then
    echo "ERROR: Could not get apps domain for $cluster"
    continue
  fi
  echo "Apps domain: $APPS_DOMAIN (region: $REGION)"

  # Generate manifest from template
  echo "Generating ManifestWork from template..."
  cp "$TEMPLATE" "$MANIFEST"

  sed -i.bak "s|<YOUR_MANAGED_CLUSTER_NAME>|${cluster}|g" "$MANIFEST"
  sed -i.bak "s|apps.<YOUR_CLUSTER_DOMAIN>|${APPS_DOMAIN}|g" "$MANIFEST"
  sed -i.bak "s|quay.io/sfredenb/quota-scorer:latest|${IMAGE}|g" "$MANIFEST"
  rm -f "$MANIFEST.bak"

  # First apply — creates SA, service, route (token placeholder is fine)
  echo "Applying ManifestWork (first pass — creates SA)..."
  oc apply -f "$MANIFEST"

  # Wait for SA to be created on managed cluster
  echo "Waiting for ServiceAccount on managed cluster..."
  for i in $(seq 1 30); do
    if KUBECONFIG="$KUBECONFIG_FILE" oc get sa rhacm-scorer -n dynamic-scoring &>/dev/null; then
      echo "ServiceAccount ready."
      break
    fi
    sleep 2
  done

  # Generate token
  echo "Generating Prometheus token..."
  TOKEN=$(KUBECONFIG="$KUBECONFIG_FILE" \
    oc create token rhacm-scorer -n dynamic-scoring --duration=8760h 2>/dev/null || true)

  if [ -z "$TOKEN" ]; then
    echo "WARNING: Could not generate token. SA may not be ready yet."
    echo "  Re-run this script after the ManifestWork propagates."
    continue
  fi

  # Update manifest with token and re-apply
  sed -i.bak "s|<YOUR_PROMETHEUS_SERVICE_ACCOUNT_TOKEN>|${TOKEN}|g" "$MANIFEST"
  rm -f "$MANIFEST.bak"

  echo "Re-applying ManifestWork with token..."
  oc apply -f "$MANIFEST"

  # A small baseline ResourceQuota should exist so the scorer has something to
  # measure. A score of 0 often means no ResourceQuotas are present (or quota
  # hard limits already fill the configured capacity budget).
  echo "Applying example ResourceQuota (baseline headroom for scoring)..."
  KUBECONFIG="$KUBECONFIG_FILE" oc apply -f "$MANIFESTS_DIR/example-resourcequota.yaml"

  echo "[$cluster] Done — domain: $APPS_DOMAIN"
done

echo ""
echo "=== Scorer deployment complete ==="
echo "Generated manifests are in $GENERATED_DIR (not committed to git)."
echo "Baseline ResourceQuota applied from manifests/example-resourcequota.yaml on each cluster."
echo "Note: score 0 usually means no quotas present, or quota is at full capacity vs the scorer budget."
