# Agent instructions

## Mission

Develop a production-grade IFRS 9 Retail ECL calculation engine using T-SQL on SQL Server 2016. Work in small, reviewable PRs. Every PR must have a separate implementation log under `docs/implementation-log/PR-NNN.md`.

## Non-negotiable boundaries

- The calculation runtime is SQL Server 2016 / T-SQL. Do not move calculation logic into Python.
- Existing upstream processes supply PD, LGD, EAD, pool assignment, and Stage/SICR. Do not recreate those models without explicit scope approval.
- PD is annual unconditional marginal PD on the original cohort.
- Downturn, Base, and Upturn scenario PDs already exist upstream. Do not derive scenario PD using `PD FWL ± 1 SE`.
- Scenario weights recorded so far: Downturn 15.68%, Base 68.64%, Upturn 15.68%. Identify and validate the authoritative source; do not hardcode weights into production calculation logic.
- LGD is currently assumed flat across scenarios. EAD is currently assumed flat across scenarios; validate its grain and semantics from source definitions.
- Stage mapping: Stage 1 -> 12-month ECL; Stage 2 -> lifetime ECL; Stage 3 -> `ECL_DEFAULT`, PD=1 with validated LGD/EAD curves and approved discounting.
- POCI is excluded from the initial scope.
- Reject a calculation run when PD inputs are invalid. Do not silently cap/floor bad PDs.
- One Stage per account per reporting date. Stage ECL output categories are mutually exclusive for portfolio aggregation; avoid double counting.
- SQL Server 2016 compatibility: avoid unsupported newer T-SQL features.
- Do not invent source schemas/table names/keys/types. First inspect actual definitions or ask the user to supply them.
- Public tests and fixtures must not contain customer-identifiable or confidential data.
- Do not publish partial/failed calculation runs. Make reruns deterministic and auditable.

## Methodology blockers

- Confirm whether annual EAD at default and LGD curves represent period-specific marginal loss inputs or point-in-time curves, to avoid double counting.
- Reconcile period-specific EIR discounting. The current note `DF(t)=1/(1+EIR(t))^t` is not generally equivalent to cumulative discounting when EIR varies over time. Do not change it silently or implement it as final policy without approval.
- Confirm lifetime horizon, POCI identification/exclusion, Stage 3 curve applicability, source keys/grains, EIR source grain, scenario-weight source, and acceptable LGD/EAD ranges.

## Workflow

1. Read README and the applicable methodology/open-question docs.
2. Inspect the current repository and follow existing conventions.
3. Make the smallest coherent change for the requested PR.
4. Add or update deterministic, privacy-safe tests for calculation changes.
5. Update the corresponding implementation log with files changed, decisions, validation performed, unresolved issues, and exact next steps.
6. Never claim tests ran unless you actually ran them. Never claim a PR was opened/merged unless verified from GitHub.
7. Prefer a feature branch and pull request. Do not merge without explicit authorization.

## PR #1 boundary

PR #1 is documentation only. It must not include executable ECL calculation SQL or presume physical source schemas.