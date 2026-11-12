# DSF Quota Scorer Demo

## The story

ACM Placement can prefer clusters with more capacity. This demo shows a custom DSF scorer that ranks managed clusters by **resourcequota headroom** — how much CPU/memory request quota remains — and publishes those scores for Placement.

## Setup

ACM hub with managed clusters listed in `clusters.conf` (`cluster1`, `cluster2`). Scorer + DSF addon already deployed (`bash scripts/setup-all.sh`).

```bash
# Terminal 1 — feed the dashboard
bash scripts/dashboard.sh

# Terminal 2 — serve the dashboard
cd dashboard && python3 -m http.server 8080
# Open http://localhost:8080

# Terminal 3 — demo commands
bash scripts/06-demo.sh scores
```

Scorer Route (from a managed cluster):

```bash
SCORER=$(KUBECONFIG="/tmp/$(head -1 clusters.conf | grep -v '^#' | cut -d: -f1)-kubeconfig.yaml" \
  oc get route rhacm-scorer -n dynamic-scoring -o jsonpath='http://{.spec.host}')
echo $SCORER
curl -s $SCORER/healthz
curl -s $SCORER/config | python3 -m json.tool
```

## Beat 1 — Quota scores are live

1. **ACM console → Clusters** — show `cluster1` / `cluster2` Ready
2. **Add-ons** — show `dynamic-scoring` installed
3. **Dashboard** — live `cpu_mem_quota_pct_score` bars

> "Both clusters publish quota headroom scores. Higher means more remaining request quota. Placement can prefer the cluster with greater capacity."

## Beat 2 — Load shifts relative capacity

```bash
bash scripts/06-demo.sh start cluster1
bash scripts/06-demo.sh scores
bash scripts/06-demo.sh watch
```

> "Drive load on a cluster and watch how fleet scores react. Cleanup:"

```bash
bash scripts/06-demo.sh stop cluster1
```

## Commands cheat sheet

```bash
bash scripts/06-demo.sh scores
bash scripts/06-demo.sh watch
bash scripts/06-demo.sh start cluster1
bash scripts/06-demo.sh stop cluster1
oc get addonplacementscores -A -o custom-columns="CLUSTER:.metadata.namespace,REGION:.status.scores[0].ame,SCORE:.status.scores[0].value"
```
