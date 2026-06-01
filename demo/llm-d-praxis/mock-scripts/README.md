# Mock Scripts

## Which Examples Use Mocks and Why

Most examples in this demo use the real `llm-d-inference-sim` as the
backend. Mocks are used only when the simulator cannot expose the
evidence needed to prove the behavior.

### Examples Using Real llm-d-inference-sim

| Example | Why Real Sim Works |
|---------|-------------------|
| 1. Static model-aware baseline | Sim serves `fake-model` and returns real OpenAI responses |
| 2. Load-aware routing | Sim exposes `vllm:*` Prometheus metrics with configurable fake values |
| 3. InferencePool discovery | Sim pods are discovered via K8s label selector |
| 4. Gateway API HTTPRoute | Same as Example 3, discovered through HTTPRoute chain |
| 6. Saturation/admission gate | Sim metrics drive saturation scoring |
| 8. InferenceModelRewrite | Sim accepts the rewritten model name |

### Examples Using Mocks

| Example | Mock Type | Why a Mock Is Needed |
|---------|-----------|---------------------|
| 5. Prefix-cache-aware routing | Echo backend | The prefix-cache index is an in-memory approximation inside Praxis. It uses block hashing to track which prompts went to which endpoints. The real sim has no way to expose its KV-cache block hashes for external verification. An echo backend with a distinct response signature per backend lets the demo prove that repeated prompts route to the same endpoint (prefix hit) without relying on internal vLLM state. |

Note: Example 7 (P/D disaggregation) previously used header-echo nginx mocks but now uses the real llm-d-inference-sim. Header injection is verified via Praxis debug logs instead of response body echo.

### Examples Using Real llm-d-inference-sim (with CRD)

| Example | Why Real Sim Works |
|---------|-------------------|
| 9. InferenceObjective | Praxis reads the InferenceObjective CRD, resolves the request header to a priority value, and routes successfully. The sim serves the request as normal; priority is internal metadata. Objective-aware admission is covered by Praxis integration tests. |

## Mock Implementation Notes

The mock backends used in this demo are minimal. They are deployed as
K8s pods using simple container images (e.g., nginx echo, Python HTTP
servers, or small Go binaries). They do not simulate vLLM inference --
they exist solely to make the Praxis routing decision visible in the
response.

For the prefix-cache example, the two echo backends return different
static responses so the demo script can identify which backend handled
each request.
