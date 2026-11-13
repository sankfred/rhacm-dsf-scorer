# Fast Api - Scorer
from fastapi import FastAPI, Request
from schemas.scoring import ScoringPayload, ScoringResponse
from schemas.config import ConfigResponse
import uvicorn
# Prometheus Exporter - Metrics
from kubernetes import client, config
from prometheus_client import start_http_server, Gauge
import time
import logging
import os

# -----------------------------
# Logging setup
# -----------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

# -----------------------------
# Kubernetes config
# -----------------------------
try:
    config.load_incluster_config()
    logging.info("Loaded in-cluster Kubernetes config")
except config.ConfigException:
    config.load_kube_config()
    logging.info("Loaded local kubeconfig")

core_api = client.CoreV1Api()
custom_api = client.CustomObjectsApi()

# -----------------------------
# Prometheus metric
# -----------------------------
gauge = Gauge(
    "cpe_addonplacementscore_value",
    "Addon Placement Score",
    ["namespace", "datacenter", "faultdomain", "lob", "sdlc", "placement", "metric"]
)

# -----------------------------
# Namespace discovery
# -----------------------------
def discover_namespaces():
    namespaces = []

    try:
        logging.info("Discovering namespaces with managedCluster label")

        ns_list = core_api.list_namespace(
            label_selector="cluster.open-cluster-management.io/managedCluster"
        ).items

        for ns in ns_list:
            name = ns.metadata.name
            labels = ns.metadata.labels or {}

            datacenter = labels.get("datacenter", "unknown")
            faultdomain = labels.get("faultdomain", "unknown")
            lob = labels.get("lob", "unknown")
            sdlc = labels.get("sdlc", "unknown")

            namespaces.append((name, datacenter, faultdomain, lob, sdlc))

        logging.info(f"Discovered {len(namespaces)} managed cluster namespaces")

    except Exception as e:
        logging.error(f"Failed to discover namespaces: {e}")
        return []

    return namespaces

# -----------------------------
# Metrics collection
# -----------------------------
def collect():
    namespaces = discover_namespaces()

    if not namespaces:
        logging.warning("No namespaces matched label selector")
        return

    for ns_data in namespaces:
        try:
            ns, datacenter, faultdomain, lob, sdlc = ns_data
        except ValueError:
            logging.error(f"Invalid namespace tuple: {ns_data}")
            continue

        logging.debug(f"Scanning namespace: {ns}")

        try:
            resp = custom_api.list_namespaced_custom_object(
                group="cluster.open-cluster-management.io",
                version="v1alpha1",
                namespace=ns,
                plural="addonplacementscores",
            )
        except Exception as e:
            logging.exception(f"API error while processing namespace {ns}: {e}")
            continue

        items = resp.get("items", [])

        if not items:
            logging.debug(f"No AddOnPlacementScore found in {ns}")
            continue

        logging.info(f"Found {len(items)} AddOnPlacementScore in {ns}")

        for item in items:
            try:
                metadata = item.get("metadata", {})
                placement = metadata.get("name", "unknown")

                scores = item.get("status", {}).get("scores", [])
                if not scores:
                    logging.debug(f"No scores in {ns}/{placement}")
                    continue

                for s in scores:
                    metric = s.get("name", "unknown")

                    try:
                        value = float(s.get("value", 0))
                    except (TypeError, ValueError):
                        logging.warning(
                            f"Invalid value for metric '{metric}' in {ns}/{placement}: {s.get('value')}"
                        )
                        continue

                    logging.info(
                        f"Metric collected: ns={ns}, datacenter={datacenter}, faultdomain={faultdomain}, lob={lob}, sdlc={sdlc}, "
                        f"placement={placement}, metric={metric}, value={value}"
                    )

                    gauge.labels(ns, datacenter, faultdomain, lob, sdlc, placement, metric).set(value)

            except Exception:
                logging.exception(f"Error processing item in namespace {ns}")
                continue

# -----------------------------
# Scoring app
# -----------------------------
PROMETHEUS_HOST = os.getenv(
    "PROMETHEUS_HOST",
    "https://thanos-querier.openshift-monitoring.svc:9091",
)
# or vector(0) must wrap only the *usage* term. If it wraps (budget - usage),
# an empty kube_resourcequota result becomes 0/budget → score 0 instead of 100.
PROMETHEUS_QUERY = os.getenv(
    "PROMETHEUS_QUERY",
    'min('
    '((20*24) - ((max(sum(kube_resourcequota{resource="requests.cpu", type="hard"}))) or on() vector(0))) / (20*24)'
    ' or '
    '((20*8.4e+10) - ((max(sum(kube_resourcequota{resource="requests.memory", type="hard"}))) or on() vector(0))) / (20*8.4e+10)'
    ')',
)
SCORE_NAME = os.getenv("SCORE_NAME", "cpu_mem_quota_pct_score")
# Agents on every managed cluster must call the local Service — if this is
# omitted, DSF derives scoringEndpoint from configURL and all spokes hit one Route.
SCORING_HOST = os.getenv(
    "SCORING_HOST",
    "http://rhacm-scorer.dynamic-scoring.svc:8000",
)
# Short window so quota add/remove shows up quickly (agent still uses query_range).
PROM_RANGE_SEC = int(os.getenv("PROM_RANGE_SEC", "120"))
PROM_STEP_SEC = int(os.getenv("PROM_STEP_SEC", "15"))
SCORING_INTERVAL_SEC = int(os.getenv("SCORING_INTERVAL_SEC", "15"))

app = FastAPI()

@app.post("/scoring", response_model=ScoringResponse)
async def scoring_timeseries(payload: ScoringPayload, request: Request):
  # print(payload.data, flush=True)
  # Payload consists of values over the past hour
  # metric is empty, so supplement with cluster

  data = payload.data
  results = []
  for series in data:
      # Use the latest sample — max() over the hour kept scores sticky after
      # quota changes (old high headroom samples dominated for up to `range`).
      try:
          if not series.values:
              continue
          latest = float(series.values[-1][1])
          results.append({"metric": series.metric, "score": 100 * latest})

      except Exception as e:
          logging.error(f"Error processing series: {e}")

  print(results, flush=True)

  return {"results": results}

@app.get("/healthz")
async def healthcheck():
    return {"status": "ok"}

@app.get("/config", response_model=ConfigResponse)
async def get_config():
    return {
        "name": SCORE_NAME,
        "description": "CPU/memory resourcequota headroom score (higher = more quota remaining)",
        "source": {
            "type": "Prometheus",
            "host": PROMETHEUS_HOST,
            "path": "/api/v1/query_range",
            "params": {
                "query": PROMETHEUS_QUERY,
                "range": PROM_RANGE_SEC,
                "step": PROM_STEP_SEC,
            },
        },
        "scoring": {
            "host": SCORING_HOST,
            "path": "/scoring",
            "params": {
                "name": SCORE_NAME,
                "interval": SCORING_INTERVAL_SEC,
            },
        },
    }

# -----------------------------
# Main loop
# -----------------------------
if __name__ == "__main__":
    MODE = os.getenv("MODE")

    if MODE == "exporter":
        # Start Prometheus metrics server
        port = int(os.getenv("PORT", "9000"))
        logging.info(f"Starting AddOnPlacementScore exporter on :{port}")
        start_http_server(port)

        while True:
            collect()
            time.sleep(30)
    else:
    # Start FastAPI server
        port = int(os.getenv("PORT", "8000"))
        ssl_certfile = os.getenv("SSL_CERT", None)
        ssl_keyfile = os.getenv("SSL_KEY", None)

        logging.info(f"Starting FastAPI server on :{port}")
        uvicorn.run(
            app,
            host="0.0.0.0",
            port=port,
            ssl_certfile=ssl_certfile if ssl_certfile else None,
            ssl_keyfile=ssl_keyfile if ssl_keyfile else None,
        )
