# Project TODO / Roadmap

Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules
- [ ] Do not implement final ECL formulas until the synthetic regression suite for rerun safety, publication gating/atomicity, and selective-run scope passes.
- [x] Canonical schema and input forms are the agreed interface; the user will populate these tables.
- [x] Use synthetic, privacy-safe test data only. No production source survey or source mapping is required for this phase.
- [x] SQL Server 2022 is the CI runtime for this phase; SQL Server 2016 compatibility verification is not required.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Current gates
- [x] Canonical happy-path input test validates and reconciles all six manifest families without producing ECL output.
- [x] SQL Server 2022 integration suite runs on an ephemeral container on GitHub-hosted runners.
- [x] Scenario-weight effective-date and required-scenario boundary tests pass on SQL Server 2022 CI.
- [x] Existing input validation, reconciliation, maturity/curve-coverage, and lifecycle regression tests pass on SQL Server 2022 CI.
- [x] PR #31 lifecycle gate regression tests are merged; CI passed: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/38843997785.
- [x] Add pre-calculation replay safety regression: repeated validation/reconciliation preserves findings, sealed manifest, lifecycle state, and empty ECL outputs; each reconciliation attempt has an audit event.
- [ ] Add result-level calculation rerun idempotency tests after the calculation procedure exists; current suite cannot verify output replay before calculation is implemented.
- [ ] Add and pass publication-gate tests proving failed reconciliation cannot publish and no partial outputs remain.
- [ ] Add and pass selective-run tests for valid requested scope and rejection of out-of-scope accounts.
- [ ] Review whether remaining input data-quality cases (duplicate keys, invalid grain, and wrong-date rows) are covered before calculation implementation.

## Existing test coverage audit (2026-10-16)
- `run_control_smoke_tests.sql`: lifecycle happy path, manifest sealing/immutability, successful reconciliation/publication milestones, and rejection of a transition out of PUBLISHED.
- `run_lifecycle_gate_tests.sql`: rejects CREATED -> CALCULATING and rejects calculation with an unsealed manifest; verifies status remains unchanged and no ECL detail is created.
- `input_validation_smoke_tests.sql`: missing PD/LGD/EAD/EIR coverage and legacy POCI-related cases; no ECL detail on validation failure.
- `input_reconciliation_smoke_tests.sql`: manifest count mismatch, blocked reconciliation, no ECL detail, and idempotence for a repeated mismatch finding.
- `input_contract_regression_tests.sql`: invalid scenario-weight sum, EIR = -1, no ECL detail, and no duplicate selected validation findings on rerun.
- `maturity_curve_coverage_tests.sql`: maturity boundary and period-2 curve coverage.
- `scenario_weight_boundary_tests.sql`: ineffective scenario-weight version and missing required scenario.
- `canonical_input_happy_path_tests.sql`: positive-path validation/reconciliation of all six input families without ECL output.
- Gap confirmed: result-level rerun idempotency cannot be verified until a calculation procedure exists. Failed-reconciliation publication blocking/atomicity and selective-run scope acceptance/rejection remain untested. The pre-calculation replay test now covers combined successful validation/reconciliation replay without duplicating the existing single-finding idempotency cases.

## Confirmed methodology
- [x] Lifetime horizon ends at contractual maturity.
- [x] Scenario weights: Downturn 15.68%, Base 68.64%, Upturn 15.68%; weighted ECL is the sum of scenario ECLs times weights.
- [x] Stage 3 follows Stage 2 logic with only PD=1 changed; same annual EAD/LGD curves and shared EIR discount convention.
- [x] Stage 1/2/3 use shared EIR and `DF(t)=1/(1+EIR(t))^t`.
- [x] EIR is the supplied FTP 12-month value, consumed as-is without percentage/decimal conversion.
- [x] Partial final-year fraction changes only discount-time exponent; annual PD and EAD are not prorated.
- [x] VND output; final published ECL rounded to whole VND.
- [x] No mandatory approval metadata for scenario weights.

## PR roadmap
| GitHub PR | Project PR | Scope | Status |
|---|---:|---|---|
| #1 | #1 | Documentation foundation | Merged |
| #13 | #2 | Source inventory toolkit | Merged; no source survey |
| #15 | #3 | Logical schema | Merged |
| #16–17 | #4 | Run-control design | Integrated |
| #18 | #5 | Run lifecycle and manifest | Merged |
| #19 | #6 | Initial SQL Server 2017 CI | Merged historically |
| #20 | #7 | Input validation | Merged |
| #21 | #8 | Input reconciliation | Merged; legacy POCI code is historical and out of scope |
| #22 | #9 | Canonical input contract | Merged |
| #23 | #10 | Contract enforcement matrix | Merged |
| #24 | #11 | Input regression tests | Merged |
| #25 | #12 | Remove approval gate | Merged |
| #26 | #13 | Maturity/coverage tests | Merged |
| #27 | #14 | EIR and Stage 3 convention | Merged |
| #28 | #15 | Canonical happy-path test and SQL Server 2016 harness | Merged; SQL Server 2016 verification not required |
| #29 | #16 | Scenario-weight boundary regression | Merged |
| #30 | #17 | Switch hosted integration CI to SQL Server 2022 container | Merged; CI passed |
| #31 | #18 | Add lifecycle gate regression tests | Merged; CI passed |
| #32 | #19 | Audit existing test coverage and reconcile roadmap | Merged |
| — | #20 | Pre-calculation replay safety regression | In review |

## Next action
Next: (1) publication gating/atomicity, (2) selective-run scope. Result-level calculation rerun idempotency must be tested once the calculation procedure exists. Run the complete SQL Server 2022 CI suite. Do not implement final ECL formulas until the pre-calculation safety, publication, and selective-scope gates pass. Canonical-table input is the agreed interface; do not require upstream mapping or conduct a production source survey.
