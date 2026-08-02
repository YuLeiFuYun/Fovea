# GitHub Actions Budget Policy

Fovea treats hosted runner minutes as a scarce release-evidence resource, not as an exploratory development loop.

## Private publication phase

- Repository workflows are manually dispatched only. Push, pull-request, and schedule triggers are forbidden.
- Every dispatch defaults to `budget_approved: false`; no runner job may start without an explicit approval.
- `identity` is the default verification profile. It runs only the native arm64 and Rosetta-backed x86_64 identity vectors, with a combined hard ceiling of 30 hosted runner-minutes.
- `full` is mutually exclusive with `identity` and is reserved for one locally qualified, immutable release candidate. It includes the complete product, Workbench, mutation, rollback, privacy, and evidence gates, with a 60-minute hard ceiling.
- Live-network verification has no schedule and runs only after explicit budget approval.
- Exploratory diagnostics, test isolation, mutation application checks, documentation checks, and repeated failure triage run locally or on a separately provisioned self-hosted runner.
- When the hosted budget is exhausted, all Fovea workflows remain disabled and publication remains blocked. A skipped or absent hosted run is never reported as green evidence.

## Candidate admission

A full hosted run may be requested only after the exact candidate passes locally:

1. project memory, workload, privacy, supply-chain, formatting, and Actions-budget governance gates;
2. all 101 mutation applications;
3. component exact-pin resolution and clean-copy checks;
4. Workbench static and locally available Simulator verification;
5. a clean sanitized source-tree comparison with no generated or ignored artifacts;
6. a documented estimate of the maximum hosted minutes and confirmation that the account budget has sufficient headroom.

Do not push a sequence of speculative root commits to discover failures. Consolidate fixes locally, publish one candidate, run `identity`, and run `full` only after the identity result and remaining budget are reviewed.

## Re-enabling hosted workflows

The repository owner must confirm budget restoration. Then:

1. re-enable only `Fovea Verification`;
2. dispatch `identity` with `budget_approved: true`; its two jobs may consume at most 30 runner-minutes;
3. review the result, confirm the candidate SHA is unchanged, and review remaining budget;
4. dispatch `full` once, with an exact `base_commit` when rollback evidence is required; it may consume at most 60 runner-minutes and does not repeat identity;
5. re-enable Live Network only for a separately approved evidence run.

Automatic triggers must not be restored during the private publication phase.
