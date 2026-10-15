# Open questions and methodology blockers

These items must be resolved or explicitly accepted by the accountable methodology owner before affected calculation SQL is implemented. Do not infer answers from table names alone.

| ID | Question / blocker | Why it matters | Evidence / decision required |
|---|---|---|---|
| OQ-001 | Do annual EAD-at-default and LGD records describe each period's incremental/defaulted exposure loss, or are they point-in-time curves? | Repeatedly applying PD=1 in Stage 3 or combining survival/marginal PD with point-in-time EAD may double count loss. | Source data dictionary, sample synthetic records, approved formula for each Stage |
| OQ-002 | What is the approved discount factor definition when EIR differs by forecast period? | `1/(1+EIR(t))^t` is not generally a cumulative term-structure discount factor. | Approved accounting methodology and rate convention; explicit worked example |
| OQ-003 | What are actual source table/view names, schemas, key columns, and data types? | Prevents guessed physical mappings and key collisions. | DDL or metadata extract for each input source |
| OQ-004 | What is the authoritative scenario-weight table and versioning/effective-date logic? | Weights must be traceable and total 100%. | Table/view definition, approval/version columns, example effective date |
| OQ-005 | What is the approved lifetime horizon and treatment of missing curve periods? | Prevents truncating lifetime or silently filling missing periods. | Product-level horizon convention and source coverage rules |
| OQ-006 | How is POCI identified and proven excluded? | POCI is out of initial scope and may require separate impairment treatment. | Flag/source logic and population reconciliation |
| OQ-007 | What is the physical grain of the period EIR source? | Common across pools is an assumption, not a physical key definition. | DDL, uniqueness profile, rate basis, compounding/time basis |
| OQ-008 | Is the Stage 3 PD=1 rule intended per lifetime period, or as a defaulted-exposure calculation with a one-time default event? | PD=1 for every year can double count a defaulted account. | Approved Stage 3 methodology with numeric worked example |
| OQ-009 | What are valid LGD/EAD ranges, scales, currencies, and exceptional-value rules? | Validation requires explicit units and domains. | Data dictionary and handling rules |
| OQ-010 | What are the exact input keys/grains and relationships among account, pool, PD, LGD, EAD, Stage, and reporting date? | Prevents fan-out joins and duplicated ECL. | Join map, expected uniqueness constraints, duplicate checks |
| OQ-011 | What is the safe rerun/concurrency/publication contract? | Needed to prevent partial output, double publish, and overlapping selective runs. | Operational SLA, concurrency policy, retention policy |
| OQ-012 | What deployment and CI mechanisms are available for SQL Server 2016? | DDL/deployment/test strategy depends on target environment and permissions. | Target environment details, tooling/runner, permission boundaries |
| OQ-013 | Are scenario PD inputs account-level or pool-level, and how are they mapped to account results? | Aggregating a pool-level PD incorrectly at account level can distort ECL. | Physical grain, mapping keys, approved allocation rules |
| OQ-014 | How are Stage 1 12-month marginal PD values represented, especially for accounts with a reporting-date horizon not aligned to calendar year-end? | Need an explicit 12-month window and period boundary convention. | Forecast-period definition and one worked Stage 1 example |
| OQ-015 | What is the exact relationship between the original cohort denominator and annual unconditional marginal PD? | Avoids multiplying already-marginal PD with survival a second time. | Source method document and example calculation |
| OQ-016 | What output precision, currency conversion policy, rounding point, and negative/zero EAD handling apply? | These affect reconciliation and determinism. | Accounting policy and data contract |

## Suggested next step

PR #2 should inspect source definitions and write a source data dictionary / lineage map without yet implementing ECL formulas. The highest priority discussions are OQ-001, OQ-002, OQ-004, OQ-008, and OQ-010.