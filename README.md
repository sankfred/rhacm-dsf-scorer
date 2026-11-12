# DSF Quota Scorer

Custom scoring plugin for the [OCM Dynamic Scoring Framework](https://github.com/open-cluster-management-io/dynamic-scoring-framework) (DSF) on Red Hat Advanced Cluster Management.

Scores managed clusters by **resourcequota headroom** (CPU/memory requests remaining vs a configured capacity budget). DSF publishes those scores as `AddOnPlacementScores` so Placement can prefer clusters with more available quota.

Based on the [augustrh/rhacm-dsf-scorer](https://github.com/augustrh/rhacm-dsf-scorer) demo layout, adapted to the **quota-scorer** implementation under `quota-scorer/`.

## How it works
                          Hub
                           │
                    DynamicScorer CR
                    (configURL → /config)
                           │
          ┌────────┬───────┼───────┬────────┐
          ▼        ▼       ▼       ▼        ▼
     ┌────────┐┌────────┐┌────────┐┌────────┐
     │tokyo   ││singapore││useast ││uswest  │
     │ap-ne-1 ││ap-se-1  ││us-e-1 ││us-w-2  │
     ├────────┤├────────┤├────────┤├────────┤
     │Prom─►Ag││Prom─►Ag││Prom─►Ag││Prom─►Ag│
     │   ↓    ││   ↓    ││   ↓    ││   ↓    │
     │ Scorer ││ Scorer ││ Scorer ││ Scorer │
     └───┬────┘└───┬────┘└───┬────┘└───┬────┘
         │         │         │         │
         ▼         ▼         ▼         ▼
     AddOnPlacementScore (per cluster on hub)
                           │
                    Placement Decision
                    (highest score wins)

1. The DSF agent on each managed cluster queries Prometheus with a resourcequota PromQL expression
2. Agent POSTs the time series to the scorer `/scoring` endpoint
3. Scorer returns a 0–100 score (`cpu_mem_quota_pct_score`) — higher means more quota headroom
4. Agent publishes an `AddOnPlacementScore` on the hub
5. Placement uses the scores to pick the best cluster

## Quick start

### Prerequisites

- RHACM with the [DSF addon](https://github.com/open-cluster-management-io/dynamic-scoring-framework) installed
- 2+ managed clusters with OpenShift monitoring
- `oc` logged into the hub
- Container registry you can push to (default: `quay.io/sfredenb/quota-scorer`)

### Configure

Edit `clusters.conf` — one line per managed cluster:

```
# name:region
cluster1:us-east-2
cluster2:us-west-2
```

### Deploy

```bash
bash scripts/setup-all.sh
```

Or step by step — see [`scripts/README.md`](scripts/README.md).

### Check scores

```bash
bash scripts/06-demo.sh scores
bash scripts/06-demo.sh watch
```

### Dashboard

```bash
bash scripts/dashboard.sh                    # Terminal 1
cd dashboard && python3 -m http.server 8080  # Terminal 2
# Open http://localhost:8080
```

## Structure

```
clusters.conf                 Managed cluster list (name:region)
quota-scorer/                 Scorer app + Dockerfile
  app/main.py                 /scoring, /config, /healthz (+ exporter mode)
manifests/                    DynamicScorer + ManifestWork template
scripts/                      Build, deploy, verify, demo helpers
dashboard/                    Live HTML score view
```

## Image

```bash
bash scripts/01-build-and-push.sh
# default: quay.io/sfredenb/quota-scorer:latest
```
