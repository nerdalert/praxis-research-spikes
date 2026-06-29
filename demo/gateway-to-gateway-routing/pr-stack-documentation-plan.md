# PR-stack documentation plan

This plan keeps the E2E validation branch useful after the demo passes. The
goal is to avoid reverse-engineering a large proof-of-concept branch when it is
time to create upstream Praxis PRs for
[praxis-proxy/praxis#664](https://github.com/praxis-proxy/praxis/issues/664).

## Plain-language summary

The E2E can move quickly, but every step must leave a clean trail:
what changed, what was proven, what belongs in production, what was only a demo
shortcut, and which future PR should own the work. A reviewer checks that trail
after each step before more code is added.

## Working agreement

| Role | Responsibility | Output |
| --- | --- | --- |
| Implementation agent | Implement the current E2E task and document the exact behavior validated. | Handoff report, updated demo docs, extraction notes, and local task drafts if needed. |
| Reviewer | Review changes for architecture fit, PR boundaries, security issues, and missing evidence. | Review notes, corrected follow-up tasks, decision on whether the next E2E step is ready. |
| Future upstream PR author | Use this tracked PR stack and validated evidence, not the monolithic E2E branch, as the source of truth. | Small Praxis PRs with tests, docs, and clear non-goals. |

## Required documentation after every E2E task

Each implementation pass must update the demo docs before review.

| Artifact | Required update | Why it matters later |
| --- | --- | --- |
| `implementation-notes.md` | Add actual files/functions touched, behavior added, and any design changes from the original plan. | Captures the real implementation path, not the guessed one. |
| `upstream-pr-stack.md` | Mark affected G2G targets with evidence, likely upstream files, and readiness status. | Keeps the future PR stack aligned with validated behavior. |
| `sample-output.md` | Add sanitized command output once a demo assertion passes. | Gives future PRs concrete acceptance evidence. |
| Handoff report | List changed files, validation commands, failed commands, blockers, and open questions. | Gives the reviewer enough context to review without rediscovering basics. |

`sample-output.md` can stay absent until there is passing demo output worth
preserving. Once created, it should contain only sanitized logs and responses.

## Extraction note format

Each meaningful E2E implementation area needs this note in
`implementation-notes.md` or the handoff report:

```text
Extraction target:
Validated behavior:
Files touched in E2E:
Likely upstream files:
POC-only shortcuts:
Required upstream tests:
Docs/examples impact:
Security or correctness pitfalls:
Open questions:
```

## Review checklist

The reviewer should not approve moving to the next E2E step until these checks
are answered.

| Check | Pass condition |
| --- | --- |
| Scope | The task stayed inside the current E2E step and did not implement later targets accidentally. |
| Trust boundary | Client-controlled data is not treated as gateway authority. |
| PR split clarity | Each new behavior maps to one or more G2G targets with a clear upstream owner. |
| POC shortcut labeling | Demo-only shortcuts are explicitly named and blocked from implementation tasks. |
| Tests | Positive and negative assertions are documented, not just happy-path output. |
| Docs | Task refinements include exact files/functions, commands, and pitfalls found. |
| Reproducibility | A future engineer can rerun or inspect the evidence without hidden state. |

## Test expectations for implementation passes

Every implementation task must run tests before handoff. The minimum
depends on what changed.

| Change type | Required validation |
| --- | --- |
| Demo docs/scripts/configs only | Run the relevant demo scripts, `git diff --check`, and any shell/config validation available. Explain why Rust tests are not applicable. |
| Praxis Rust code | Run focused unit tests for touched modules, full package tests for touched crates, `make lint`, `cargo clippy --workspace --all-targets -- -D warnings`, and `git diff --check`. |
| Praxis config examples/docs generated from code | Run the relevant example integration test, generated-doc sync/lint command, `make lint`, and `git diff --check`. |
| Protocol, TLS, trust, routing, or concurrency changes | Run positive and negative tests, including adversarial/failure-mode tests. Add or update integration tests unless the reviewer explicitly accepts a narrower reason. |

Skipping tests is allowed only when the task is genuinely docs/demo-only or an
environmental blocker prevents execution. In either case, the implementer must provide
the exact command, output, and reason. “No code changed” is sufficient only for
Rust tests when the diff contains no Praxis Rust code.

## Strict review standard

Use this standard when reviewing each handoff and when creating local task
drafts for self-checking work before handoff.

```text
Review this PR like a strict GitHub code-review bot and senior maintainer.

Repo:
<repo path>

Branch/PR:
<branch or PR URL>

Task requirements:
<paste original requirements>

Instructions:
1. Read docs/developing/conventions.md and any relevant docs/developing files
   before reviewing.
2. Inspect the full diff line by line. Do not rely only on summaries.
3. Compare the implementation against the original task requirements and
   clearly separate:
   - fully satisfied requirements
   - partially satisfied requirements
   - not covered / future work
4. Look for subtle issues:
   - false-positive tests
   - tests that do not prove the stated behavior
   - stale docs or generated docs drift
   - scope creep
   - missing example config or missing example integration test
   - lint convention violations
   - ordering/state-machine bugs
   - async/concurrency deadlocks
   - failure-mode bypasses
   - security regressions such as trusting client-controlled routing input
5. Fix any in-scope issues yourself. Do not make unrelated refactors.
6. Always run:
   - make lint
   - cargo clippy --workspace --all-targets -- -D warnings
   - git diff --check
7. Run the relevant focused tests and any full package tests touched by the PR.
8. If any validation failure is outside PR scope, prove that with file/output
   evidence instead of guessing.
9. Final response must list findings first with file/line references, then
   fixes made, then exact validation results, then remaining scope gaps.
```

For the E2E worktree, the conventions document is expected at:

```text
/home/ubuntu/praxxis/ai-grid/prs/gateway-to-gateway-e2e/praxis/docs/developing/conventions.md
```

## Implementation task quality bar

Every upstream task created from the E2E must be small enough to become one
reviewable PR. If the task naturally asks for multiple behaviors, split it.

Each implementation task must include:

1. the exact upstream behavior to implement;
2. the E2E assertion that validated the behavior;
3. likely files/modules to inspect first;
4. explicit non-goals;
5. POC shortcuts that must not be copied;
6. required unit, integration, and negative tests;
7. docs or examples that must change;
8. validation commands, including focused tests and `make lint`/`make test`
   expectations when practical; and
9. a handoff format requiring changed files, commands run, blocked commands,
   and open questions.

## PR-stack gates

| Gate | Requirement | Result |
| --- | --- | --- |
| After G2G-E2E-01 | Harness, configs, mocks, cert generation, cleanup, and current expected failures are documented. | Ready to implement POC trust behavior. |
| After G2G-E2E-02 | Peer identity and header-protection behavior have evidence and split cleanly into G2G-01/G2G-02. | Ready to implement route-state and inference routing. |
| After G2G-E2E-03 | Static site descriptors, route selection, and forwarding metadata have evidence and split cleanly into G2G-03/G2G-04/G2G-05. | Ready to add scoring and agent-shaped routing. |
| After G2G-E2E-04 | Freshness/locality scoring and MCP routing have evidence and split cleanly into G2G-06/G2G-07; A2A remains explicitly deferred pending route-key semantics and gateway tests. | Ready for final demo cleanup. |
| After G2G-E2E-05 | Final sample output, upstream PR stack, and local task drafts are complete. | Ready to start upstream PR stack. |

## Rules for avoiding PR-stack drift

- Do not use the E2E branch as the upstream implementation plan by itself.
- Do not let a passing demo hide missing negative tests.
- Do not carry demo scripts or mock servers into Praxis unless they are
  converted into normal examples or tests.
- Do not mix peer identity, ingress trust, route selection, scoring, and
  agent protocol support in one upstream PR unless the reviewer explicitly approves a
  combined boundary.
- Do not write implementation tasks that ask an implementer to "make it like the E2E";
  name the specific behavior, files, tests, and non-goals.
