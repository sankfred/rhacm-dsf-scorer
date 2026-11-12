#!/bin/bash
# Shared helpers — sourced by all DSF scorer scripts.
# Reads cluster config from clusters.conf at the repo root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF_FILE="${CONF_FILE:-$REPO_ROOT/clusters.conf}"

_CLUSTER_NAMES=()
_CLUSTER_REGIONS=()
_LOADED=false

_load() {
  $_LOADED && return
  if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: $CONF_FILE not found" >&2
    exit 1
  fi
  while IFS=: read -r name region _rest; do
    [ -z "$name" ] && continue
    [[ "$name" == \#* ]] && continue
    _CLUSTER_NAMES+=("$name")
    _CLUSTER_REGIONS+=("$region")
  done < "$CONF_FILE"
  if [ ${#_CLUSTER_NAMES[@]} -eq 0 ]; then
    echo "ERROR: No clusters defined in $CONF_FILE" >&2
    exit 1
  fi
  _LOADED=true
}

cluster_names() {
  _load
  echo "${_CLUSTER_NAMES[@]}"
}

get_region() {
  _load
  local target="$1"
  for i in "${!_CLUSTER_NAMES[@]}"; do
    if [ "${_CLUSTER_NAMES[$i]}" = "$target" ]; then
      echo "${_CLUSTER_REGIONS[$i]}"
      return
    fi
  done
  echo "unknown"
}

first_cluster() {
  _load
  echo "${_CLUSTER_NAMES[0]}"
}

# Stamp region from clusters.conf onto AddOnPlacementScore objects so
# `oc get ... -o custom-columns=...REGION:.metadata.labels.region` works.
label_aps_regions() {
  _load
  local cluster region
  for cluster in "${_CLUSTER_NAMES[@]}"; do
    region="$(get_region "$cluster")"
    [ -z "$region" ] || [ "$region" = "unknown" ] && continue
    oc label addonplacementscores -n "$cluster" --all \
      "region=${region}" --overwrite >/dev/null 2>&1 || true
  done
}
