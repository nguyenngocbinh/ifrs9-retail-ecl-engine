# Project TODO / Roadmap

This file is the repository-level overview. Use linked GitHub Issues for active tracking and discussion. Each implementation PR has its own log at `docs/implementation-log/PR-NNN.md`.

## Working rules

- [ ] Do not implement final ECL formulas while methodology blockers remain unresolved.
- [x] Logical schema proposal is designed from user decisions; no source-system survey is required for this step.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [ ] Use synthetic, privacy-safe test data only.
- [ ] Update this roadmap and per-PR implementation log when scope/status changes.

## Priority 0 — methodology decisions

- [ ] [#2 Confirm ECL methodology blockers](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/2) — Stage 3 allocation, EAD/LGD semantics, discounting, PD semantics, horizons, POCI, precision.
- [x] Confirm logical curve grains: PD = account/scenario/period; LGD = account/period; EAD = account/period; EIR = shared/period; summary stores both portfolio and pool totals.\n- [ ] [#4 Define canonical input contract and mapping](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/4) — confirm period semantics, units/currency and input coverage; physical source mapping is not a prerequisite for logical schema design.

## Priority 1 — platform foundation

- [ ] [#5 Design run control, snapshots, and audit logging](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/5)
- [ ] [#6 Implement input validation and pre-calculation quality gates](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/6)
- [ ] [#10 Set up SQL deployment and CI for SQL Server 2016](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/10)

## Priority 2 — calculation and controls

- [ ] [#7 Implement scenario-weighted ECL calculation in T-SQL](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/7) — only after methodology and canonical input grains are approved.
- [ ] [#8 Build account and portfolio aggregation with reconciliation](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/8)
- [ ] [#9 Create synthetic regression and edge-case test suite](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/9)

## Priority 3 — production readiness

- [ ] [#11 Define production publication, monitoring, and operations](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/11)
- [ ] [#12 Maintain PR implementation logs and release checklist](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/12)

## PR roadmap

| PR | Intended scope | Gate |
|---|---|---|
| PR #1 | Documentation foundation and methodology/open-question register | Review/merge |
| PR #2 | Source inventory toolkit and templates | Independent review; no source survey required for logical schema |
| PR #3 | Logical schema, normalized input contracts, run/audit/output DDL proposal | Review canonical curve grains and SQL deployment safety |
| PR #4 | Input version binding, validation gates and controlled run lifecycle | Resolve necessary input-grain and validation rules |
| PR #5+ | Calculation, aggregation, tests, publication, deployment | Relevant methodology decisions approved |

## Current blockers

- LGD and PD curve grain must be approved against the logical model.
- EAD period semantics and Stage 3 default-loss allocation remain unresolved.
- Discounting convention for a period-varying EIR needs approved methodology.
- Lifetime horizon, POCI exclusion, domains, units, precision and rounding remain to be confirmed.
- The DDL is a proposal and has not been executed against SQL Server.

## Next action

Review the revised `docs/database-schema-v1.0.md` and DDL. Next, finalize period semantics, EIR discounting and Stage 3 loss allocation before any calculation SQL; implement input version binding and validation gates in the next PR.
