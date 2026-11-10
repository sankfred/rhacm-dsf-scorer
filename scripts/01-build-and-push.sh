#!/bin/bash
# Step 1: Build and push the scorer image
# Usage: bash scripts/01-build-and-push.sh [registry/image:tag]

set -euo pipefail

IMAGE="${1:-quay.io/sfredenb/quota-scorer:latest}"

echo "=== Step 1: Build and Push ==="
echo "Image: $IMAGE"

cd "$(dirname "$0")/.."

podman build --platform linux/amd64 -t "$IMAGE" -f quota-scorer/Dockerfile quota-scorer
echo ""
echo "Built. Pushing..."
podman push "$IMAGE"

echo ""
echo "Done. Make sure the repository is PUBLIC on quay.io:"
echo "  Settings → Repository Visibility → Public"
