# Project TODO / Roadmap

This file is the repository-level overview. Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules

- [ ] Do not implement final ECL formulas until canonical input validation/reconciliation tests pass and SQL Server 2016 compatibility is verified.
- [x] Canonical schema and input forms are the agreed interface; the user will load production data into these tables.
- [x] Use synthetic, privacy-safe test data only. No production source survey or source-system mapping is required for this test scope.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Priority 0 — canonical input contract

- [x] Canonical staging/configuration targets and required fields are defined in `database/001_create_logical_schema.sql` and `docs/canonical-input-contract.md`.
- [ ] Exercise the canonical table forms with synthetic positive-path data and verify validation plus six-family manifest reconciliation.
- [x] Confirm calculation methodology: Stage 3 follows Stage 2 calculation, with only PD=1 changed; EIR is consumed as supplied and the same discount formula applies.

## Priority 1 — platform foundation

- [x] Run-control design, guarded lifecycle, input validation and pre-calculation reconciliation migrations are implemented.
- [x] SQL Server 2017 CI runs lifecycle, validation, reconciliation and regression tests.
- [ ] SQL Server 2016 deployment and compatibility verification — manual workflow added; actual runtime test is pending a configured self-hosted runner.

## Priority 2 — calculation and controls

- [ ] Implement scenario-weighted ECL calculation in T-SQL — wait until canonical positive-path/negative-path tests pass and SQL Server 2016 compatibility is verified.
- [ ] Build account and portfolio aggregation with reconciliation.
- [ ] Expand synthetic regression and edge-case tests, including rerun/idempotence and publication safety.

## Priority 3 — production readiness

- [ ] Define production publication, monitoring, and operations.
- [ ] Maintain PR implementation logs and release checklist.

## PR roadmap

| PR | Intended scope | Gate |
|---|---|---|
| PR #1 | Documentation foundation and methodology/open-question register | Merged |
| PR #2 | Source inventory toolkit and templates | Merged; no source survey run |
| PR #3 | Logical schema and normalized input contracts | Merged |
| PR #4 | Run-control design and lifecycle procedures | Integrated into main |
| PR #5 | Run manifest and guarded lifecycle procedures | Merged |
| PR #6 | GitHub Actions SQL integration tests | Merged; SQL Server 2017 target |
| PR #7 | Initial pre-calculation input validation | Merged as PR #20 |
| PR #8 | Input manifest row-count reconciliation and POCI audit | Merged as PR #21; POCI is outside the current calculation scope |
| PR #9 | Canonical input contract baseline | Merged as PR #22 |
| PR #10 | Contract enforcement matrix and evidence-gate roadmap | Merged as PR #23 |
| PR #11 | Targeted synthetic input-contract regression tests | Merged as PR #24 |
| PR #12 | Remove mandatory scenario-weight approval gate | Merged as PR #25 |
| PR #13 | Maturity and curve-coverage boundary tests | Merged as PR #26 |
| PR #14 | Dimensionless EIR and shared Stage 3 calculation convention | Merged as PR #27 |
| PR #15 | Canonical input happy-path test and SQL Server 2016 harness | Proposed in PR #28; test result and SQL Server 2016 runtime remain pending |

## Confirmed methodology and input decisions

- [x] Lifetime horizon ends at each account's contractual maturity date.
- [x] Scenario weights are Downturn 15.68%, Base 68.64%, Upturn 15.68%; scenario ECL is the weighted sum of the three scenario ECLs.
- [x] Stage 3 follows Stage 2 calculation logic with only PD changed to 1.
- [x] Stage 1, Stage 2 and Stage 3 use the same shared EIR curve and `DF(t)=1/(1+EIR(t))^t`.
- [x] EIR is the supplied FTP selling-funds rate for 12 months; it has no unit and is consumed as supplied without percentage/decimal conversion.
- [x] Reporting currency is VND; final published ECL rounds to whole VND.
- [x] Partial final-year convention: remaining months / 12 affects only discounting time/exponent; annual PD and EAD are not changed.
- [x] Scenario weights are taken from supplied configuration data; the engine validates effectivity, all three scenarios and sum to 100%; approval metadata is not required.
- [ ] Canonical happy-path integration test passes in CI.
- [ ] SQL Server 2016 deployment and compatibility verification.

## Next action

Run the expanded synthetic SQL integration suite. If it passes, configure and dispatch the SQL Server 2016 workflow when a controlled runner is available. Do not implement final ECL formulas until these test/platform gates are satisfied.
