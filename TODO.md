# Project TODO / Roadmap

This file is the repository-level overview. Use the linked GitHub Issues for active tracking, discussion, and closure. Each implementation PR must also have its own log at docs/implementation-log/PR-NNN.md.

## Working rules

- [ ] Do not implement final ECL formulas while methodology blockers remain unresolved.
- [ ] Do not guess physical source objects, keys, grains, or data types.
- [ ] Keep calculation logic in T-SQL compatible with SQL Server 2016.
- [ ] Use synthetic, privacy-safe test data only.
- [ ] Update this roadmap and the per-PR implementation log when scope/status changes.

## Priority 0 — unblock methodology and source mapping

- [ ] [#2 Confirm ECL methodology blockers](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/2) — Stage 3 allocation, EAD/LGD semantics, discounting, PD semantics, horizons, POCI, precision.
- [ ] [#3 Inventory upstream source schemas and lineage](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/3) — inspect real DDL, keys, grains, lineage, source versions.
- [ ] [#4 Define physical input contract and mapping](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/4) — map approved logical inputs to verified physical sources.

## Priority 1 — platform foundation

- [ ] [#5 Design run control, snapshots, and audit logging](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/5)
- [ ] [#6 Implement input validation and pre-calculation quality gates](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/6)
- [ ] [#10 Set up SQL deployment and CI for SQL Server 2016](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/10)

## Priority 2 — calculation and controls

- [ ] [#7 Implement scenario-weighted ECL calculation in T-SQL](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/7) — only after methodology and physical contracts are approved.
- [ ] [#8 Build account and portfolio aggregation with reconciliation](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/8)
- [ ] [#9 Create synthetic regression and edge-case test suite](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/9)

## Priority 3 — production readiness

- [ ] [#11 Define production publication, monitoring, and operations](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/11)
- [ ] [#12 Maintain PR implementation logs and release checklist](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/12)

## PR roadmap

| PR | Intended scope | Gate |
|---|---|---|
| PR #1 | Documentation foundation, methodology draft, logical contract, open questions, TODO tracking | Review and merge documentation |
| PR #2 | Source inventory, physical data dictionary, grain/key/lineage map | Actual source definitions available |
| PR #3 | Run control, input snapshot/versioning, audit and validation design | Operational constraints confirmed |
| PR #4+ | Calculation, aggregation, tests, publication, deployment | Relevant methodology blockers approved |

## Current blockers

- EAD/LGD period semantics and Stage 3 default-loss allocation are unresolved.
- Discounting convention for a period-varying EIR needs approved methodology.
- Actual source schemas, key/grain relationships, EIR source, and scenario-weight source need inspection.
- Lifetime horizon, POCI exclusion, LGD/EAD domains, precision, and rounding remain to be confirmed.
