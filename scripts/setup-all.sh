#!/bin/bash
# Full DSF demo setup — runs all steps in order
# Usage: bash scripts/setup-all.sh
#
# Assumes:
#   - You're logged into the hub cluster (oc whoami)
#   - podman is running (podman machine start)
#   - You're in the rhacm-dsf-scorer directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "========================================="
echo "  DSF Quota Scorer Setup"
echo "========================================="
echo ""
echo "Clusters from clusters.conf:"
for name in $(cluster_names); do
  echo "  $name  ($(get_region "$name"))"
done
echo ""
echo "Image default: quay.io/sfredenb/quota-scorer:latest"
echo ""

# Pre-flight
echo "Pre-flight checks..."
oc whoami &>/dev/null || { echo "ERROR: Not logged into hub cluster. Run: oc login ..."; exit 1; }
echo "  Hub: $(oc whoami --show-server)"
echo "  User: $(oc whoami)"
echo ""

# Step 0.5: Extract kubeconfigs
echo "Step 0.5: Extract kubeconfigs"
bash "$SCRIPT_DIR/extract-kubeconfigs.sh"
echo ""

# Step 1: Build and push
echo "Step 1: Build and push"
bash "$SCRIPT_DIR/01-build-and-push.sh"
echo ""

# Step 2: Install addon
echo "Step 2: Install DSF addon"
bash "$SCRIPT_DIR/02-install-addon.sh"
echo ""

# Wait for addon to be available
echo "Waiting 60s for addon to propagate..."
sleep 60

# Step 3+4: Deploy scorer
echo "Step 3+4: Deploy scorer"
bash "$SCRIPT_DIR/03-deploy-scorer.sh"
echo ""

# Step 5: Register scorer
echo "Step 5: Register scorer on hub"
bash "$SCRIPT_DIR/04-register-scorer.sh"
echo ""

# Wait for scores
echo "Waiting 90s for first scores..."
sleep 90

# Step 6: Verify
echo "Step 6: Verify"
bash "$SCRIPT_DIR/05-verify.sh"

echo ""
echo "========================================="
echo "  Setup complete!"
echo "  Run: bash scripts/06-demo.sh watch"
echo "========================================="
