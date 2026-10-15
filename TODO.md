# Project TODO / Roadmap

Each implementation PR has its own log at \`docs/implementation-log/PR-NNN.md\`.

## Working rules
- [ ] Do not implement final ECL formulas until synthetic input regression tests pass and SQL Server 2016 compatibility is verified.
- [x] Canonical schema and input forms are the agreed interface; the user will populate these tables.
- [x] Use synthetic, privacy-safe test data only. No production source survey or source mapping is required for this phase.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [x] Update this roadmap and per-PR implementation log when scope/status changes.

## Current gates
- [x] Canonical happy-path input test validates and reconciles all six manifest families without producing ECL output.
- [x] SQL Server 2017 CI passed after PR #28 was merged.
- [ ] Scenario-weight effective-date and required-scenario boundary tests pass in CI.
- [ ] SQL Server 2016 migrations/tests pass on a controlled SQL Server 2016 runner.

## Confirmed methodology
- [x] Lifetime horizon ends at contractual maturity.
- [x] Scenario weights: Downturn 15.68%, Base 68.64%, Upturn 15.68%; weighted ECL is the sum of scenario ECLs times weights.
- [x] Stage 3 follows Stage 2 logic with only PD=1 changed; same annual EAD/LGD curves and shared EIR discount convention.
- [x] Stage 1/2/3 use shared EIR and \`DF(t)=1/(1+EIR(t))^t\`.
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
| #19 | #6 | SQL Server 2017 CI | Merged |
| #20 | #7 | Input validation | Merged |
| #21 | #8 | Input reconciliation | Merged; legacy POCI code is historical and out of scope |
| #22 | #9 | Canonical input contract | Merged |
| #23 | #10 | Contract enforcement matrix | Merged |
| #24 | #11 | Input regression tests | Merged |
| #25 | #12 | Remove approval gate | Merged |
| #26 | #13 | Maturity/coverage tests | Merged |
| #27 | #14 | EIR and Stage 3 convention | Merged |
| #28 | #15 | Canonical happy-path test and SQL Server 2016 harness | Merged; SQL Server 2017 CI passed |
| Next | #16 | Scenario-weight effectivity/missing-scenario regression and roadmap alignment | Proposed in PR #29 |

## Next action
Keep the SQL Server 2017 regression suite green, then verify all migrations/tests on SQL Server 2016 using the controlled runner. Do not implement final ECL formulas before both gates pass. Upstream mapping is not a gate for the canonical-table phase; do not run a production source survey.
