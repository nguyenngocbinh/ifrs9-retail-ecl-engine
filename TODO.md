# Project TODO / Roadmap

Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules
- [x] Pre-calculation safety, publication lifecycle gating, and selective-run scope gates are green. ECL formulas are implemented in PR #39; keep them gated by the full SQL Server 2022 regression suite.
- [x] Canonical schema and input forms are the agreed interface; the user will populate these tables.
- [x] Use synthetic, privacy-safe test data only. No production source survey or source mapping is required for this phase.
- [x] SQL Server 2022 is the CI runtime for this phase; SQL Server 2016 compatibility verification is not required.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Current gates
- [x] Canonical happy-path input test validates and reconciles all six manifest families without producing ECL output.
- [x] SQL Server 2022 integration suite runs on an ephemeral container on GitHub-hosted runners.
- [x] Scenario-weight effective-date and required-scenario boundary tests pass on SQL Server 2022 CI.
- [x] Existing input validation, reconciliation, maturity/curve-coverage, lifecycle, and selective-scope regression tests are integrated into CI.
- [x] PR #31 lifecycle gate regression passed: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/38843997785.
- [x] PR #33 pre-calculation replay safety regression passed: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/38845145233.
- [x] PR #34 publication lifecycle gate regression is merged; true output-write atomicity remains untestable until a publisher procedure exists.
- [x] PR #35 selective-run scope regression passed: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/38845986311.
- [x] PR #36 input data-quality gates merged; SQL Server 2022 CI passed: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/38846860879.
- [x] PR #38 wrong-date and duplicate-grain data-quality coverage merged; full SQL Server 2022 CI passed: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/38847716284.
- [x] PR #39 ECL calculation and publication v1 merged; keep the formula regression suite in SQL Server 2022 CI. Production deployment remains unverified.
- [x] Calculation rerun rejection test added in PR #39; result writes are in one transaction.
- [x] PR #41 fault-injection rollback regression merged; SQL Server 2022 GitHub Actions run #39215971117 completed successfully: https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/actions/runs/39215971117.

## Existing test coverage audit (2026-10-16)
- `run_control_smoke_tests.sql`: lifecycle happy path, manifest sealing/immutability, successful reconciliation/publication milestones, and rejection of a transition out of PUBLISHED.
- `run_lifecycle_gate_tests.sql`: rejects CREATED -> CALCULATING and rejects calculation with an unsealed manifest; verifies status remains unchanged and no ECL detail is created.
- `input_validation_smoke_tests.sql`: missing PD/LGD/EAD/EIR coverage and legacy POCI-related cases; no ECL detail on validation failure.
- `input_reconciliation_smoke_tests.sql`: manifest count mismatch, blocked reconciliation, no ECL detail, and idempotence for a repeated mismatch finding.
- `input_contract_regression_tests.sql`: invalid scenario-weight sum, EIR = -1, no ECL detail, and no duplicate selected validation findings on rerun.
- `maturity_curve_coverage_tests.sql`: maturity boundary and period-2 curve coverage.
- `scenario_weight_boundary_tests.sql`: ineffective scenario-weight version and missing required scenario.
- `canonical_input_happy_path_tests.sql`: positive-path validation/reconciliation of all six input families without ECL output.
- `precalculation_rerun_safety_tests.sql`: repeated validation/reconciliation keeps manifest and run state stable, creates no ECL output, and records one reconciliation event per attempt.
- `publication_gate_tests.sql`: rejects invalid lifecycle transitions after failed reconciliation/publication milestones; does not test output-write atomicity.
- `selective_run_scope_tests.sql`: accepts in-scope synthetic rows and blocks product/pool mismatches.
- `input_data_quality_tests.sql`: PR #36 covered ACCOUNT wrong-date handling and duplicate ACCOUNT/PD grains; PR #38 adds wrong-date coverage for PD/LGD/EAD/EIR/SCENARIO_WEIGHT and duplicate LGD/EAD/EIR grain rejection.
- `ecl_calculation_tests.sql`: PR #39 synthetic calculation coverage for Stage 1/2/3, scenario weighting, fractional discount time, retry rejection and publication rounding.
- Gap remaining: explicit fault-injection rollback regression for a forced mid-write failure.

## Confirmed methodology
- [x] Lifetime horizon ends at contractual maturity.
- [x] Scenario weights: Downturn 15.68%, Base 68.64%, Upturn 15.68%; weighted ECL is the sum of scenario ECLs times weights.
- [x] Stage 3 follows Stage 2 logic with only PD=1 changed; same annual EAD/LGD curves and shared EIR discount convention.
- [x] Stage 1/2/3 use shared EIR and `DF(t)=1/(1+EIR(t))^t`.
- [x] EIR is the supplied FTP 12-month value, consumed as-is without percentage/decimal conversion.
- [x] Partial final-year fraction changes only discount-time exponent; annual PD and EAD are not prorated.
- [x] VND output; final published ECL rounded to whole VND.
- [x] No mandatory approval metadata for scenario weights.
- [x] POCI is outside the current canonical contract; legacy POCI behavior in already-merged migrations/tests is historical and should not be changed silently.

## PR roadmap
| GitHub PR | Project PR | Scope | Status |
| #47 | #29 | Document upstream Stage bucket rules and segment-to-pool mappings | In progress — documentation PR opened separately |
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
| #33 | #20 | Pre-calculation replay safety regression | Merged; CI passed |
| #34 | #21 | Publication lifecycle gate regression | Merged |
| #35 | #22 | Selective-run scope regression | Merged; CI passed |
| #36 | #23 | Input data-quality gates | Merged; SQL Server 2022 CI passed |
| #37 | #24 | Reconcile roadmap and canonical contract | Merged |
| #38 | #25 | Complete input data-quality regression coverage | Merged; CI passed |
| #39 | #26 | Implement ECL calculation and publication v1 | Merged |
| #41 | #27 | Fault-injection rollback regression | Merged; SQL Server 2022 CI passed |
| #42 | #28 | Reconcile README, roadmap, and implementation logs | In progress |

## Current next actions
1. Review and merge PR #47 for upstream Stage and segment-to-pool mapping documentation.
2. Reconcile the README and implementation logs with the merged calculation and rollback-test work (PR #42).
3. Complete the step-by-step SQL Server deployment guide tracked in [Issue #40](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/40).
4. Run migrations 001–005 and the complete synthetic calculate-and-publish flow against a clean, disposable SQL Server 2022 database; record the actual results and any blockers.
5. Keep production readiness separate: environment-specific source mapping, approved scenario-weight provenance, permissions, performance, monitoring/retention, backup/restore and operational runbooks remain gated.

Do not infer production deployment success from CI. Do not merge future PRs without explicit user authorization.
