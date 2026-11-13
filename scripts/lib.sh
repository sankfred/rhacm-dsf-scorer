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

# DSF hub sync sometimes sets scoringEndpoint to the Prometheus host
# (…thanos…/scoring) instead of the local scorer Service. Repair both the
# hub ManifestWork and the spoke ConfigMap, then bounce the agent.
SCORING_ENDPOINT_LOCAL="${SCORING_ENDPOINT_LOCAL:-http://rhacm-scorer.dynamic-scoring.svc:8000/scoring}"

_fix_scoring_endpoint_json() {
  # Usage: _fix_scoring_endpoint_json <in.json> <out.json> <mode:mw|cm>
  # Prints "patched" or "ok" to stdout.
  local infile="$1" outfile="$2" mode="$3"
  python3 - "$infile" "$outfile" "$mode" "$SCORING_ENDPOINT_LOCAL" <<'PY'
import json, sys
infile, outfile, mode, endpoint = sys.argv[1:5]
doc = json.load(open(infile))
changed = False

def fix_summaries(raw):
    global changed
    summaries = json.loads(raw or "[]")
    for s in summaries:
        if s.get("scoringEndpoint") != endpoint:
            s["scoringEndpoint"] = endpoint
            changed = True
    return json.dumps(summaries, separators=(",", ":"))

if mode == "mw":
    for m in doc.get("spec", {}).get("workload", {}).get("manifests", []):
        if m.get("kind") == "ConfigMap" and "summaries" in m.get("data", {}):
            m["data"]["summaries"] = fix_summaries(m["data"]["summaries"])
elif mode == "cm":
    if "summaries" in doc.get("data", {}):
        doc["data"]["summaries"] = fix_summaries(doc["data"]["summaries"])

if not changed:
    print("ok")
    raise SystemExit(0)

md = doc["metadata"]
doc["metadata"] = {k: md[k] for k in ("name", "namespace", "labels", "annotations") if k in md}
json.dump(doc, open(outfile, "w"))
print("patched")
PY
}

fix_scoring_endpoints() {
  _load
  local cluster tmp_in tmp_out kc status
  echo "Ensuring scoringEndpoint → $SCORING_ENDPOINT_LOCAL"
  for cluster in "${_CLUSTER_NAMES[@]}"; do
    tmp_in="$(mktemp)"
    tmp_out="$(mktemp)"
    local restarted=false
    if oc get manifestwork dynamic-scoring-config-manifestwork -n "$cluster" -o json >"$tmp_in" 2>/dev/null; then
      status="$(_fix_scoring_endpoint_json "$tmp_in" "$tmp_out" mw)"
      if [ "$status" = "patched" ]; then
        oc apply -f "$tmp_out" >/dev/null
        echo "  [$cluster] ManifestWork patched"
        restarted=true
      fi
    fi
    rm -f "$tmp_in" "$tmp_out"

    kc="/tmp/${cluster}-kubeconfig.yaml"
    [ -f "$kc" ] || continue
    tmp_in="$(mktemp)"
    tmp_out="$(mktemp)"
    if KUBECONFIG="$kc" oc get cm dynamic-scoring-config -n dynamic-scoring -o json >"$tmp_in" 2>/dev/null; then
      status="$(_fix_scoring_endpoint_json "$tmp_in" "$tmp_out" cm)"
      if [ "$status" = "patched" ]; then
        KUBECONFIG="$kc" oc apply -f "$tmp_out" >/dev/null
        echo "  [$cluster] ConfigMap patched"
        restarted=true
      fi
    fi
    rm -f "$tmp_in" "$tmp_out"

    if $restarted; then
      KUBECONFIG="$kc" oc -n dynamic-scoring delete pod -l app=dynamic-scoring-agent --wait=false >/dev/null 2>&1 || true
      echo "  [$cluster] agent restarting"
    fi
  done
}
