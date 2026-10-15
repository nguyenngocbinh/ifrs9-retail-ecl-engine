# Project TODO / Roadmap

This file is the repository-level overview. Use linked GitHub Issues for active tracking and discussion. Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules

- [ ] Do not implement final ECL formulas while methodology blockers remain unresolved.
- [x] Logical schema proposal is designed from user decisions; no source-system survey is required for this step.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [x] Use synthetic, privacy-safe test data only.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Priority 0 — methodology decisions

- [ ] [#2 Confirm ECL methodology blockers](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/2) — partial-final-period treatment is decided: remaining months / 12 affects only discounting time/exponent; annual PD and EAD remain unchanged. POCI scope is excluded from v1 with configured validation and no silent calculation.
- [x] Confirm logical curve grains: PD = account/scenario/period; LGD = account/period; EAD = account/period; EIR = shared/period; summary stores both portfolio and pool totals.
- [ ] [#4 Define canonical input contract and mapping](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/4) — confirm period semantics, units/currency and input coverage; physical source mapping is not a prerequisite for logical schema design.

## Priority 1 — platform foundation

- [x] [#5 Design run control, snapshots, and audit logging](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/5) — design and guarded run lifecycle are implemented.
- [x] [#6 Implement input validation and pre-calculation quality gates](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/6) — initial validation procedure checks manifest, input families, scope, maturity, scenario weights, POCI classification, and PD/LGD/EAD/EIR curve coverage. Extend as the canonical input contract is finalized.
- [ ] [#10 Set up SQL deployment and CI for SQL Server 2016](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/10) — CI currently targets SQL Server 2017; SQL Server 2016 verification remains required.

## Priority 2 — calculation and controls

- [ ] [#7 Implement scenario-weighted ECL calculation in T-SQL](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/7) — blocked until methodology and canonical input contracts are approved.
- [ ] [#8 Build account and portfolio aggregation with reconciliation](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/8)
- [ ] [#9 Create synthetic regression and edge-case test suite](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/9) — start with validation and lifecycle regression cases; do not invent expected ECL outputs.

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
| PR #8 | Input manifest row-count reconciliation and POCI audit | PR #21; review CI before merge |
| PR #9+ | Final ECL reconciliation, expanded synthetic regression tests, and later calculation | Methodology/input-contract gate required before ECL formulas |

## Current blockers

- PD, LGD and EAD logical grains are approved at account level.
- [x] Lifetime horizon is each account's contractual maturity date.
- [x] Scenario weights are Downturn 15.68%, Base 68.64%, Upturn 15.68%; scenario ECL is the weighted sum of the three scenario ECLs.
- [x] Stage 3 uses PD=1, the same annual EAD/LGD curves as Stage 2, and annual discounting/aggregation.
- [x] Shared EIR discount factor selected: DF(t)=1/(1+EIR(t))^t.
- [x] Reporting currency is VND; final published ECL rounds to whole VND.
- [x] Scenario weights are user-confirmed and must be stored as versioned history with VERSION_ID and PROCESS_DATE; external official source/provenance will be added later.
- [x] Partial final-year convention: remaining months / 12 affects only discounting time/exponent; annual PD and EAD are not changed.
- [x] POCI is excluded from v1; unknown POCI classification is an error, and detected POCI accounts generate a warning that must be paired with exclusion and reconciliation before any future calculation.
- SQL Server 2017 CI is not proof of SQL Server 2016 compatibility.
- Input rate-basis/source-period details and official scenario-weight provenance remain open in the canonical input contract.

## Next action

Review PR #21 CI, then implement final ECL reconciliation design and expand synthetic regression tests. Keep final ECL formulas blocked until methodology and canonical input-contract blockers are resolved. Keep final ECL formulas blocked until methodology and canonical input-contract blockers are resolved.
