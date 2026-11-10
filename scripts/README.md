# Scripts

All scripts read from `clusters.conf` at the repo root. No cluster names are hardcoded.

Run in order, or use `setup-all.sh` for the full sequence.

| Script | What it does |
|--------|-------------|
| `extract-kubeconfigs.sh` | Pulls kubeconfigs from Hive secrets to `/tmp/<cluster>-kubeconfig.yaml` |
| `01-build-and-push.sh` | Builds the quota-scorer image and pushes to Quay |
| `02-install-addon.sh` | Helm-installs the DSF addon on the hub |
| `03-deploy-scorer.sh` | Generates ManifestWorks and deploys quota-scorer to managed clusters |
| `04-register-scorer.sh` | Applies DynamicScorer + DynamicScoringConfig on the hub |
| `05-verify.sh` | Checks pods, routes, configs, and scores across all clusters |
| `06-demo.sh` | Demo helpers: `start`/`stop` load generator, `watch`/`scores` |
| `dashboard.sh` | Polls scores and writes JSON for the HTML dashboard |
| `setup-all.sh` | Runs everything end-to-end |

## Configure clusters

Edit `clusters.conf` — one line per managed cluster:

```
# name:region
cluster1:us-east-2
cluster2:us-west-2
```

Default image: `quay.io/sfredenb/quota-scorer:latest` (override with `IMAGE=...` or script arg).
