# Track B Demo Scripts

## Prerequisites

Run `check-prereqs.sh` first:

```bash
bash scripts/check-prereqs.sh
```

## Scripts

| Script | Purpose |
|---|---|
| `check-prereqs.sh` | Verify required tools are installed |
| `common.sh` | Shared variables and helpers |
| `run-local-smoke.sh` | Local process smoke: Praxis -> Go EPP -> simulator |
| `run-kind-smoke.sh` | KIND deployment smoke: 200, 503, recovery |
| `cleanup.sh` | Delete the KIND cluster |

## Running

```bash
# Local smoke
bash scripts/run-local-smoke.sh

# KIND smoke (builds images, creates cluster)
bash scripts/run-kind-smoke.sh

# KIND smoke with auto-cleanup
CLEANUP=delete bash scripts/run-kind-smoke.sh

# Clean up KIND cluster
bash scripts/cleanup.sh
```
