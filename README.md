# IFRS 9 Retail ECL Engine

Production-oriented IFRS 9 expected credit loss (ECL) engine for retail lending, implemented in T-SQL. The current development and integration-test target is **SQL Server 2022**. Production deployment has not been verified by CI.

> **Status:** ECL calculation and publication v1 are implemented in migrations 001–005; migration 006 adds shared EAD curve validation. SQL Server 2022 regression coverage includes synthetic formula, lifecycle, input-quality, reconciliation, and calculation rollback tests. A reproducible database deployment guide and clean-database end-to-end verification remain outstanding.

## Scope

Products in scope: Mortgage, Auto, Credit Card, Personal Loan, and Other Retail.

The engine consumes approved upstream data. It does not build PD, LGD, EAD, pool assignment, or Stage/SICR models.

- **PD:** annual unconditional marginal PD on the original cohort, supplied upstream by scenario. Do not prorate PD for a partial final forecast year.
- **LGD:** supplied upstream; assumed flat across scenarios in v1.
- **EAD:** supplied upstream as annual EAD at expected default, using a year-end convention. Do not prorate EAD for a partial final forecast year.
- **Horizon:** Stage 1 uses 12-month ECL; Stage 2 and Stage 3 run to contractual maturity. Stage 3 uses PD = 1 and the same annual EAD/LGD/EIR curve convention as Stage 2.
- **Discounting:** shared EIR curve and DF(t)=1/(1+EIR(t))^t. For a partial final year, the remaining-month fraction affects only discounting time/exponent.
- **Scenario weights:** Downturn 15.68%, Base 68.64%, Upturn 15.68%. The selected immutable/versioned weight set is stored with run controls and audit data. Official external provenance remains a follow-up.
- **Currency:** VND. Keep detail precision and round published account/summary ECL to whole VND.
- **POCI:** excluded from v1; validation must not silently treat POCI as a regular loan.

## Implementation

Migrations are ordered database/001 through database/006:

1. Logical schema and canonical staging/result structures.
2. Run control, lifecycle, and input manifest.
3. Input validation.
4. Input snapshot reconciliation.
5. ECL calculation and publication procedures: ecl_core.usp_CalculateECL and ecl_core.usp_PublishECL.\n6. Shared EAD validation: ecl_core.usp_LoadEADCurve validates rows already loaded into ecl_stg.EADCurve.

Review the migration headers and the SQL Server 2022 CI workflow for the exact files and test sequence. Deploy only into a disposable development/test database until the deployment guide, clean-database verification, and environment-specific approvals are complete.

## Testing and deployment status

- Synthetic SQL Server 2022 integration tests run in an ephemeral GitHub Actions SQL Server container.
- CI success demonstrates the checked-in migrations/tests ran in that CI environment; it does **not** prove production readiness, successful deployment to another SQL Server, or SQL Server 2016 compatibility.
- Never commit customer-identifiable data, credentials, or environment-specific secrets.
- Use a new RUN_ID for a rerun; do not overwrite prior run outputs.
- Deployment guide roadmap: [Issue #40](https://github.com/nguyenngocbinh/ifrs9-retail-ecl-engine/issues/40).

## Development records

- [Project roadmap](TODO.md)
- [PR #39 — ECL calculation v1](docs/implementation-log/PR-039.md)
- [PR #41 — Calculation rollback fault-injection regression](docs/implementation-log/PR-041.md)

## Safety

Use synthetic, privacy-safe fixtures only. Do not run deployment scripts against a production database without environment approval, an approved backup/restore plan, and a reviewed deployment procedure.


## Shared EAD loading

Product-specific ETL calculates annual EAD and loads it directly into the canonical `ecl_stg.EADCurve` table at grain `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD`. Then call `ecl_core.usp_LoadEADCurve @RUN_ID` to validate process date, VND currency, non-negative EAD, and active-account coverage through maturity, and to record the successful validation in `ecl_audit.RunEvent`.

There is no separate `EADCurveInput` table and no copy/promotion step. `ecl_core.usp_CalculateECL` continues to consume `ecl_stg.EADCurve` unchanged. Auto and Non-Revolving ETL share the same canonical output contract; the loader does not calculate amortization or infer source-specific outstanding-balance, settlement, write-off, or waiver semantics. Load a new run under a new `RUN_ID`; do not overwrite prior run inputs.
