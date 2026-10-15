# Project TODO / Roadmap

This file is the repository-level overview. Use linked GitHub Issues for active tracking and discussion. Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules

- [ ] Do not implement final ECL formulas while methodology/source/platform blockers remain unresolved.
- [x] Logical schema proposal is designed from user decisions; no source-system survey is required for this step.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [x] Use synthetic, privacy-safe test data only.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Priority 0 — methodology and input contract

- [ ] [#2 Confirm ECL methodology blockers](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/2) — source-to-column mapping and Stage 3 EAD/LGD timing/pre-discounting semantics remain open.
- [x] Confirm logical curve grains: PD = account/scenario/period; LGD = account/period; EAD = account/period; EIR = shared/period; summary stores both portfolio and pool totals.
- [ ] [#4 Define canonical input contract and mapping](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/4) — logical contract baseline documented in `docs/canonical-input-contract.md`; upstream mapping remains open.

## Priority 1 — platform foundation

- [x] [#5 Design run control, snapshots, and audit logging](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/5) — design and guarded run lifecycle are implemented.
- [x] [#6 Implement input validation and pre-calculation quality gates](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/6) — initial validation checks manifest, input families, scope, maturity, scenario weights, and curve coverage.
- [ ] [#10 Set up SQL deployment and CI for SQL Server 2016](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/10) — CI currently targets SQL Server 2017; SQL Server 2016 verification remains required.

## Priority 2 — calculation and controls

- [ ] [#7 Implement scenario-weighted ECL calculation in T-SQL](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/7) — blocked until source mapping, Stage 3 EAD/LGD semantics and SQL Server 2016 verification are resolved.
- [ ] [#8 Build account and portfolio aggregation with reconciliation](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/8)
- [ ] [#9 Create synthetic regression and edge-case test suite](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/9) — expand lifecycle/input tests without inventing expected ECL outputs.

## Priority 3 — production readiness

- [ ] [#11 Define production publication, monitoring, and operations](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/11)
- [ ] [#12 Maintain PR implementation logs and release checklist](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/12)

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
| PR #8 | Input manifest row-count reconciliation and POCI audit | Merged as PR #21; POCI work is historical and out of scope for the current contract |
| PR #9 | Canonical input contract baseline | Merged as PR #22 |
| PR #10 | Contract enforcement matrix and evidence-gate roadmap | Merged as PR #23 |
| PR #11 | Targeted synthetic input-contract regression tests | Merged as PR #24; SQL Server 2017 CI only |
| PR #12 | Remove mandatory scenario-weight approval gate | Merged as PR #25 |
| PR #13 | Clarify no-approval input contract and test maturity/curve-coverage boundaries | Merged as PR #26 |
| PR #14 | Record dimensionless EIR handling and shared Stage 3 discount convention | Proposed in PR #27 |
| PR #15+ | Verify SQL Server 2016 compatibility and finish upstream source contract | Do not implement final ECL formulas until gates are resolved |

## Confirmed methodology and input decisions

- [x] Lifetime horizon ends at each account's contractual maturity date.
- [x] Scenario weights are Downturn 15.68%, Base 68.64%, Upturn 15.68%; scenario ECL is the weighted sum of the three scenario ECLs.
- [x] Stage 3 uses PD=1, the same annual EAD/LGD curves as Stage 2, and annual discounting/aggregation.
- [x] Stage 1, Stage 2 and Stage 3 use the same shared EIR curve and `DF(t)=1/(1+EIR(t))^t`.
- [x] EIR is the supplied FTP selling-funds rate for 12 months; it has no unit and is consumed as supplied without percentage/decimal conversion.
- [x] Reporting currency is VND; final published ECL rounds to whole VND.
- [x] Partial final-year convention: remaining months / 12 affects only discounting time/exponent; annual PD and EAD are not changed.
- [x] Scenario weights are taken from supplied configuration data. The engine validates effective dates and active Downturn/Base/Upturn weights summing to 100%; no approval metadata is required.
- [ ] Upstream source-to-column mapping and source owner confirmation.
- [ ] Confirm Stage 3 EAD/LGD curves have the agreed timing and are not pre-discounted.
- [ ] SQL Server 2016 deployment and compatibility verification.

## Next action

Verify migration and test compatibility on SQL Server 2016, then close the remaining source-contract questions for upstream mapping and Stage 3 EAD/LGD timing/pre-discounting. Do not implement final ECL formulas until those gates are resolved.
