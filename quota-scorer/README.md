# Quota Scorer (Python)

This is the quota scoring API implementation for the Dynamic Scoring Framework. It demonstrates how to receive time series data, process it, and return scoring results.
Based on the upstream OCM add-on dynamic scoring project (sample-scorer): https://github.com/open-cluster-management-io/addon-contrib/tree/main/dynamic-scoring-framework/samples/sample-scorer

## Overview
The Quota Scorer is a reference Python implementation of a Dynamic Scoring Framework–compatible scoring API for Open Cluster Management (OCM).
It exposes a REST endpoint that accepts metrics collected by the DynamicScoringAgent and returns a numeric score that can be used by the Placement API.

This scorer demonstrates:

The expected HTTP contract for Dynamic Scorers
How scoring requests are parsed and validated
How a score is calculated and returned to OCM

This service is intentionally simple and stateless, making it suitable for learning, debugging, and prototyping custom scoring logic.

## Running the Scorer

**Local Execution:**
```bash
pip install -r requirements.txt
python app.py
```

The service will be available at:
```bash
http://localhost:8000/score
```

## Building

**Build container image:**

```bash
podman build -t quota-scorer:latest .
podman run quota-scorer:latest
```

> **Troubleshooting:** Scripts for troubleshooting are located in `/scripts` 

## Application Structure

### `app.py` Architecture

The application is implemented as a **FastAPI-based HTTP server** with a single scoring endpoint.

### Flask Application Initialization
```python
app = FastAPI()
```

- Initializes the web server
- Registers the scoring route
- Listens on 0.0.0.0:8000 by default

## Scoring API

### POST /score

This endpoint is invoked by the DynamicScoringAgent for each scoring cycle.

#### Handler Function
```python
@app.post("/scoring", response_model=ScoringResponse)
async def scoring_timeseries(payload: ScoringPayload, request: Request):
  # print(payload.data, flush=True)
  # Payload consists of values over the past hour
  # metric is empty, so supplement with cluster 

  data = payload.data
  results = []
  for series in data:
    # Compute a max over the range as the score
    results.append({"metric": series.metric, "score": 100*max(float(v[1]) for v in series.values)})
```

The scoring() function performs the following steps:

- Parses the incoming JSON payload
- Extracts cluster-level metrics
- Normalizes the score
- Returns the calculated score as a JSON response

Example quota score:
```json
INFO: 172.18.2.36:38856 - "POST /scoring HTTP/1.1" 200 OK
[{'metric': {}, 'score': 93.33333333333333}]
```

#### Request Payload
The scorer expects a JSON body with this structure:
```json
{
  "metric": {
    "__name__": "cpu_mem_quota_pct_score",
    "instance": "localhost:9090"
  },
  "values": [
    [
      1718600000,
      "0.933333"
    ],
    [
      1718600060,
      "0.933333"
    ],
    [
      1718600120,
      "0.933333"
    ]
  ]
}
```

Fields

- metric
Key/value pairs of metric names to numeric values
These metrics originate from Prometheus queries defined in the DynamicScorer CR

### Scoring Logic
Inside the scoring() function, a basic weighted calculation is applied:
```python
results.append({"metric": series.metric, "score": 100*max(float(v[1]) for v in series.values)})
```

##### Characteristics

- Higher resource usage results in a lower score
- Total score range: 0–100
- Missing metrics default to 0

This logic is intentionally minimal and is meant to be replaced with domain-specific heuristics in real deployments.

### Response Payload
```json
{
   "metric": {},
   "score": 93 
}  
```

- score = Numeric value published by OCM as a PlacementScore

The scorer is fully stateless; each request is evaluated independently.

Example quota score:
```json
INFO: 172.18.2.36:38856 - "POST /scoring HTTP/1.1" 200 OK
[{'metric': {}, 'score': 93.33333333333333}]
```

### Error Handling
If the request body is invalid or missing required fields, the service returns:
```json
{
  "error": "Invalid request payload"
}
```

With HTTP status:
```bash
400 Bad Request
```

## Integration with Dynamic Scoring Framework

Example DynamicScorer resource (hub):

```yaml
apiVersion: dynamic-scoring.open-cluster-management.io/v1alpha1
kind: DynamicScorer
metadata:
  annotations:
  name: quota-scorer
  namespace: open-cluster-management
spec:
  configSyncMode: None
  configURL: 'http://dummy.dynamic-scoring.svc.cluster.local:8000/config'
  description: A quota scorer for time series data
  location: Internal
  scoreDestination: AddOnPlacementScore
  scoreDimensionFormat: '${scoreName}'
  scoring:
    host: 'https://quota-scorer.dynamic-scoring.svc.cluster.local:8000'
    params:
      interval: 30
      name: cpu_mem_quota_pct_score
    path: /scoring
  source:
    auth:
      tokenSecretRef:
        key: token
        name: dynamic-scorer-token
    host: 'https://prometheus-k8s.openshift-monitoring.svc.cluster.local:9091'
    params:
      query: 'min(((20*24) - ((max(sum(kube_resourcequota{resource="requests.cpu", type="hard"}))) or on() vector(0))) / (20*24) or ((20*8.4e+10) - ((max(sum(kube_resourcequota{resource="requests.memory", type="hard"}))) or on() vector(0))) / (20*8.4e+10))'
      range: 3600
      step: 60
    path: /api/v1/query_range
    type: Prometheus
```

Once configured:

- Metrics are collected by the DynamicScoringAgent
- Requests are sent to /scoring
- Returned scores are published to the Placement API for scheduling decisions

# AddOnPlacementScore Prometheus Exporter

## 🧭 Overview

This project provides a lightweight Prometheus exporter that exposes  
ACM (Advanced Cluster Management) `AddOnPlacementScore` resources as metrics.

It enables visibility into placement scoring decisions for:

- Grafana dashboards  
- Prometheus alerting  
- Multi-cluster scheduling debugging  

## ⚙️ How It Works

1. The exporter runs inside the hub cluster.
2. It queries the Kubernetes API for AddOnPlacementScore resources.
3. It filters namespaces using label:
   cluster.open-cluster-management.io/managedCluster
4. It extracts values from status.scores[].
5. It exposes metrics at /metrics on port 9000.

## 📊 Exported Metric

Metric name:
cpe_addonplacementscore_value

Labels:
- namespace
- placement
- metric

Example:
cpe_addonplacementscore_value{namespace="cluster1",placement="cpu-mem-quota-pct-score",metric="cpu_mem_quota_pct_score"} 99

## 🚀 Installation

Build and push image:

```bash
podman build -t quota-scorer:latest .
podman run quota-scorer:latest
```

## Running the Scorer
Local Execution:

_NOTE: ensure context is correct_
```
kubectl config current-context
python exporter.py
```

The service will be available at:

```
http://localhost:9000/metrics
```

## ✅ Verification

Check pods:
```
kubectl get pods -n addonplacementscore-exporter
```

Check logs:
```
kubectl logs deployment/addonplacementscore-exporter -n addonplacementscore-exporter
```

Test metrics:
```
kubectl port-forward svc/addonplacementscore-exporter -n addonplacementscore-exporter 9000
curl localhost:9000/metrics
```

## 🛠️ Troubleshooting

List labeled namespaces:
```
kubectl get ns -l cluster.open-cluster-management.io/managedCluster
```

Check addonplacementscore:
```
kubectl get addonplacementscores -A
```


## PromQL capacity model (`20 × ?`)

The default Prometheus query is **not** calculated from live node inventory. The `20` is a **hardcoded assumed node count**; `24` and `~84Gi` are **hardcoded per-node sizes**. Together they form a fixed cluster capacity budget.

### Formula (intended meaning)

**CPU budget** = `20 × 24` = **480 cores**  
**Memory budget** = `20 × 8.4e10` bytes ≈ **20 × ~78–84 Gi** ≈ **~1.5–1.6 Ti**

For each dimension:

```text
ratio = (budget − sum of ResourceQuota hard limits) / budget
```

- Prometheus reads `kube_resourcequota{resource="requests.cpu|memory", type="hard"}` (quota **hard** caps, not live pod usage).
- Missing quota → treated as `0` claimed (`or on() vector(0)`).
- The scorer then does `score = 100 × max(ratio over the time window)` → 0–100.

So with the example quota (`48` CPU / `96Gi`):

- CPU headroom ≈ `(480 − 48) / 480` ≈ **0.90** → score **~90**

### What `20` is

| Piece | Meaning |
|--------|--------|
| `20` | Assumed number of worker/capacity units (nodes) |
| `24` | Assumed CPU cores **per** unit |
| `8.4e10` | Assumed memory bytes **per** unit (~78 Gi; docs often round to ~84 Gi) |

There is **no** `count(kube_node_info)` (or similar) in the query. On single-node OpenShift clusters the budget is still “as if” there were **20** nodes × those sizes.

Override via the `PROMETHEUS_QUERY` env var (see Deployment / ManifestWork) if you want the model to match real cluster size.

### Default query

```promql
min(
  ((20*24) - ((max(sum(kube_resourcequota{resource="requests.cpu", type="hard"}))) or on() vector(0))) / (20*24)
  or
  ((20*8.4e+10) - ((max(sum(kube_resourcequota{resource="requests.memory", type="hard"}))) or on() vector(0))) / (20*8.4e+10)
)
```

A score of **0** usually means no ResourceQuotas are present, or hard limits already fill the configured capacity budget.


### Query window

`/config` advertises a short Prometheus \`query_range\` window (default **120s**, step **15s**, scoring interval **15s**) so quota changes show up quickly. Override with \`PROM_RANGE_SEC\`, \`PROM_STEP_SEC\`, and \`SCORING_INTERVAL_SEC\`.
