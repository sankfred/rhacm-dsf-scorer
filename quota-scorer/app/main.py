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
# Prometheus metric (hub MODE=exporter)
# -----------------------------
# Use "managedcluster" — ACM Observability adds its own "cluster" label
# (hub/local-cluster). Reusing "cluster" collapses all spoke scores into one
# series when the UWL metrics-collector forwards into Thanos.
gauge = Gauge(
    "cpe_addonplacementscore_value",
    "Addon Placement Score",
    ["managedcluster", "datacenter", "faultdomain", "lob", "sdlc", "placement", "metric"]
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

            # Hub local-cluster is not a demo spoke — skip it.
            if name == "local-cluster" or "local-cluster" in labels:
                logging.debug(f"Skipping local-cluster namespace {name}")
                continue

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

    # Drop stale labelsets (e.g. local-cluster, renamed labels) so /metrics
    # only exposes the current scrape set — avoids duplicate Grafana rows.
    gauge.clear()

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
                        f"Metric collected: managedcluster={ns}, datacenter={datacenter}, faultdomain={faultdomain}, lob={lob}, sdlc={sdlc}, "
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

# ---------------------------------------------------------------------------
# Spoke-side /metrics (DISABLED on SNO demos — prefer hub MODE=exporter)
# ---------------------------------------------------------------------------
# Publishing cpe_addonplacementscore_value from each managed-cluster scorer
# needs OpenShift user-workload monitoring + ACM uwl-metrics-collector on the
# spoke. That extra memory tipped these SNOs into etcd/API failures. Keep the
# hub AddOnPlacementScore exporter (manifests/exporter-hub.yaml) as the
# Observability source. Uncomment below only on clusters with spare RAM.
#
# from fastapi import Response
# from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
#
# CLUSTER_NAME = os.getenv("CLUSTER_NAME", os.getenv("HOSTNAME", "unknown"))
# spoke_registry = CollectorRegistry()
# spoke_score = Gauge(
#     "cpe_addonplacementscore_value",
#     "Remaining quota score computed by the local scorer",
#     ["managedcluster", "placement", "metric"],
#     registry=spoke_registry,
# )
#
# def _record_spoke_score(score: float) -> None:
#     placement = os.getenv("SCORE_PLACEMENT", "cpu-mem-quota-pct-score")
#     spoke_score.labels(CLUSTER_NAME, placement, SCORE_NAME).set(score)
#
# @app.get("/metrics")
# async def metrics():
#     return Response(generate_latest(spoke_registry), media_type=CONTENT_TYPE_LATEST)
# ---------------------------------------------------------------------------

@app.post("/scoring", response_model=ScoringResponse)
async def scoring_timeseries(payload: ScoringPayload, request: Request):
  # print(payload.data, flush=True)
  # Payload consists of values over the past hour
  # metric is empty, so supplement with cluster

  data = payload.data
  results = []
  for series in data:
      # Use the latest sample — max() over the hour kept scores sticky after
      # quota changes (old high remaining quota samples dominated for up to `range`).
      try:
          if not series.values:
              continue
          latest = float(series.values[-1][1])
          score = 100 * latest
          results.append({"metric": series.metric, "score": score})
          # _record_spoke_score(score)  # spoke /metrics — see comment block above

      except Exception as e:
          logging.error(f"Error processing series: {e}")

  logging.info("Scoring result: %s", results)
  print(results, flush=True)

  return {"results": results}

@app.get("/healthz")
async def healthcheck():
    return {"status": "ok"}

@app.get("/config", response_model=ConfigResponse)
async def get_config():
    return {
        "name": SCORE_NAME,
        "description": "CPU/memory remaining resourcequota score (higher = more available capacity)",
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
def resolve_mode() -> str:
    """Return 'exporter' or 'scorer'.

    Helm charts often set MODE from {{ .Values.mode }}. If that template is left
    unrendered in the image or Deployment, treat it as unset and default to scorer.
    """
    raw = os.getenv("MODE", "scorer")
    if "{{" in raw or "}}" in raw:
        logging.warning(
            "MODE=%r looks like an unrendered Helm template; defaulting to scorer",
            raw,
        )
        return "scorer"
    mode = raw.strip().lower()
    return mode if mode in ("exporter", "scorer") else "scorer"


if __name__ == "__main__":
    MODE = resolve_mode()
    logging.info(f"Starting quota-scorer in MODE={MODE}")

    if MODE == "exporter":
        # Hub-side AddOnPlacementScore → Prometheus metrics (/metrics).
        port = int(os.getenv("PORT", "9000"))
        logging.info(f"Starting AddOnPlacementScore exporter on :{port}")
        start_http_server(port)

        while True:
            collect()
            time.sleep(30)
    else:
        # Spoke-side FastAPI scoring API (/scoring, /config, /healthz).
        # Metrics for Grafana come from the hub exporter, not this process.
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
