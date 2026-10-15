# Project TODO / Roadmap

This file is the repository-level overview. Use linked GitHub Issues for active tracking and discussion. Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules

- [ ] Do not implement final ECL formulas while methodology blockers remain unresolved.
- [x] Logical schema proposal is designed from user decisions; no source-system survey is required for this step.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [x] Use synthetic, privacy-safe test data only.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Priority 0 — methodology decisions

- [ ] [#2 Confirm ECL methodology blockers](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/2) — core formula decisions are captured; production evidence still required for FTP 12-month numeric units, Stage 3 EAD/LGD suitability, and scenario-weight source/approval provenance.
- [x] Confirm logical curve grains: PD = account/scenario/period; LGD = account/period; EAD = account/period; EIR = shared/period; summary stores both portfolio and pool totals.
- [ ] [#4 Define canonical input contract and mapping](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/4) — logical contract baseline documented in `docs/canonical-input-contract.md`; upstream mapping and owner certification remain open.

## Priority 1 — platform foundation

- [x] [#5 Design run control, snapshots, and audit logging](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/5) — design and guarded run lifecycle are implemented.
- [x] [#6 Implement input validation and pre-calculation quality gates](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/6) — initial validation checks manifest, input families, scope, maturity, scenario weights, and curve coverage.
- [ ] [#10 Set up SQL deployment and CI for SQL Server 2016](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/10) — CI currently targets SQL Server 2017; SQL Server 2016 verification remains required.

## Priority 2 — calculation and controls

- [ ] [#7 Implement scenario-weighted ECL calculation in T-SQL](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/7) — blocked until input-contract evidence and methodology gates are approved.
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
| PR #8 | Input manifest row-count reconciliation and POCI audit | Merged as PR #21; POCI work is historical and out of scope for the current input-contract PR |
| PR #9 | Canonical input contract baseline | Merged as PR #22 |
| PR #10 | Contract enforcement matrix and evidence-gate roadmap | Merged as PR #23 |
| PR #11 | Targeted synthetic input-contract regression tests | Proposed in PR #24; SQL Server 2017 CI only |
| PR #12+ | Implement provenance/rate-basis contract and expand regression tests, then later calculation | Evidence and methodology gate required before ECL formulas |

## Confirmed methodology and input decisions

- [x] Lifetime horizon ends at each account's contractual maturity date.
- [x] Scenario weights are Downturn 15.68%, Base 68.64%, Upturn 15.68%; scenario ECL is the weighted sum of the three scenario ECLs.
- [x] Stage 3 uses PD=1, the same annual EAD/LGD curves as Stage 2, and annual discounting/aggregation; upstream suitability must still be certified.
- [x] Shared EIR discount factor selected: `DF(t)=1/(1+EIR(t))^t`.
- [x] EIR input is FTP selling-funds rate for 12 months; Treasury must confirm numeric units and its approved use in the formula before production calculation.
- [x] Reporting currency is VND; final published ECL rounds to whole VND.
- [x] Partial final-year convention: remaining months / 12 affects only discounting time/exponent; annual PD and EAD are not changed.
- [x] Scenario weights require VERSION_ID, PROCESS_DATE/effective dates, and retained source/approval history; official source/approval evidence still needs to be supplied.
- [ ] SQL Server 2016 deployment and compatibility verification.
- [ ] Upstream source-to-column mapping and certification.
- [ ] Treasury rate-unit confirmation.
- [ ] Written Stage 3 EAD/LGD suitability confirmation.
- [ ] Scenario-weight source/approval references populated for the applicable version.

## Next action

Expand synthetic regression coverage for effective-date boundaries, missing scenario rows, maturity/curve coverage, and safe reruns. Keep FTP_12M semantics and scenario-weight provenance explicit; do not implement ECL formulas until the evidence gates are closed.
