# Demo Scripts

This directory contains self-narrated demo scripts that automatically set up, run, and validate the Praxis llm-d demos.

## Directory Structure

```
scripts/
├── demo1/           # Static Model-Aware Routing
├── demo2/           # Load-Aware Routing  
├── demo3/           # InferencePool Discovery
├── demo4/           # Gateway API HTTPRoute Discovery
├── demo5/           # Prefix-Cache-Aware Routing
├── common.sh        # Shared utilities
└── *.sh             # Legacy individual scripts
```

## Self-Narrated Demo Scripts

Each demo directory contains a `run-*.sh` script that provides:

- **Automated setup** - Applies manifests and waits for pods
- **Self-narration** - Explains what each step is doing and why
- **Automatic validation** - Tests functionality and shows results
- **Verbose output** - Shows commands, responses, and validation
- **Clean teardown** - Handles port-forwarding cleanup

## Usage

From the demo directory, run:

```bash
# Demo 1: Static Model-Aware Routing
bash scripts/demo1/run-static-model-aware.sh

# Demo 2: Load-Aware Routing
bash scripts/demo2/run-load-aware.sh

# Demo 3: InferencePool Discovery  
bash scripts/demo3/run-inferencepool-discovery.sh

# Demo 4: Gateway API HTTPRoute Discovery
bash scripts/demo4/run-gateway-api.sh

# Demo 5: Prefix-Cache-Aware Routing
bash scripts/demo5/run-prefix-cache.sh
```

## Prerequisites

- KIND cluster running (`kind-praxis-llmd-router-poc`)
- Images built and loaded (see `../deploy.md`)
- `kubectl` configured for the cluster

## Script Features

### Self-Narration
Each script includes explanatory output:
```
[demo1] What this demo proves:
[demo1]   - Praxis extracts model field from request body
[demo1]   - Routes only to endpoints that serve the requested model
[demo1]   - Rejects requests for models not served by any endpoint
```

### Automatic Validation
Scripts test functionality and show results:
```
[demo1] testing model 'model-a' (expecting HTTP 200)
[demo1] ✓ model 'model-a' returned HTTP 200 as expected
[demo1]   response model: model-a
```

### Port-Forward Management
Each script:
- Uses a unique localhost port (8080-8083)
- Automatically starts kubectl port-forward
- Cleanly tears down port-forward on exit
- Handles port conflicts gracefully

### Log Validation
Scripts check simulator logs with verbose output:
```
[demo2] checking sim-a routing logs...
[demo2]   ✓ sim-a received 3 request events
[demo2] checking sim-b routing logs...
[demo2]   - sim-b received no requests
```

This proves that routing decisions are working correctly based on the configured metrics and policies.