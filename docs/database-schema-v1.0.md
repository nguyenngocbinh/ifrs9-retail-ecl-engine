# Logical database schema proposal v1.0

## Decision record

This is a logical/canonical contract, not a claim about existing source tables. It is designed for SQL Server 2016 and T-SQL.

- Schemas: `ecl_cfg`, `ecl_stg`, `ecl_core`, `ecl_result`, `ecl_audit`.
- Inputs are normalized into separate tables.
- Pool names share one model and one set of result tables; `POOL_NAME` is the upstream-mapped pool code (for example `RETAIL_LN_AUTO` or `RETAIL_LN_MORTGAGE`).
- Primary business grain is `PROCESS_DATE + ACCOUNT_ID`; every execution is isolated by `RUN_ID`.
- Input rows carry `VERSION_ID` and `IS_ACTIVE`; a run must bind to one immutable set of input versions. `IS_ACTIVE` is selection metadata, not permission to mutate an already captured run.
- PD grain is account × scenario × forecast period; LGD and EAD grains are account × forecast period. EIR is shared by forecast period. Result detail is account × scenario × forecast period. Account output is one row per account/run. Portfolio output stores both portfolio and pool totals.
- Selected discount factor: `DF(t) = 1 / (1 + EIR(t))^t`, where `t` is the annual forecast period. EIR is shared by period.
- Lifetime horizon runs through each account's `MATURITY_DATE`. For a partial final forecast year, calculate `FINAL_PERIOD_FRACTION = remaining months / 12` and apply it **only to the discounting time/exponent**. Do not prorate, rescale, or otherwise change the supplied annual PD or EAD for the partial final year. The partial-year discount exponent is the elapsed forecast time including the final fraction (for example, year 3 plus 6 remaining months uses `t = 3.5`); the selected discount formula remains `DF(t) = 1 / (1 + EIR(t))^t`. The applicable period EIR remains sourced from the shared EIR curve. This is the agreed simplified convention for v1.
- Scenario weights are user-confirmed: Downturn 15.68%, Base 68.64%, Upturn 15.68%. Store them as immutable, versioned configuration with `VERSION_ID`, `PROCESS_DATE`, effective dates and audit history. The official external source/provenance will be added later.
- Scenario-weighted ECL = `ECL_DOWNTURN × 15.68% + ECL_BASE × 68.64% + ECL_UPTURN × 15.68%`.
- Reporting currency is VND. Retain internal calculation precision and round final published ECL to whole VND.
- Stage 3 uses PD=1, the same annual EAD/LGD curves as Stage 2, and annual losses discounted using the agreed EIR convention before aggregation.
- POCI is excluded from v1. If a POCI account is detected, persist a configured validation finding and never process it as a regular account. Severity controls run handling: ERROR/FATAL blocks the run; WARN may allow continuation only when the POCI account is excluded from calculation and its exclusion is visible in reconciliation.
- Calculation procedures are not included.

## Schemas and tables

| Schema | Table | Purpose / grain |
|---|---|---|
| ecl_cfg | PoolName | Approved pool-name code list used by canonical inputs |
| ecl_cfg | Scenario | Downturn/Base/Upturn code list |
| ecl_cfg | ScenarioWeightVersion | Version/effective period for scenario weights |
| ecl_cfg | ScenarioWeight | One row per version/scenario; process-date trace |
| ecl_core | RunControl | One row per run, including process date, scope, lifecycle, calculation version |
| ecl_stg | AccountSnapshot | One row per run/account; product, Stage, pool assignment and contractual maturity date |
| ecl_stg | PDCurve | One row per run/account/scenario/forecast period |
| ecl_stg | LGDCurve | One row per run/account/forecast period |
| ecl_stg | EADCurve | One row per run/account/forecast period |
| ecl_stg | EIRCurve | One row per run/forecast period; shared EIR curve |
| ecl_result | ECLDetail | One row per run/account/scenario/forecast period; calculation trace |
| ecl_result | ECLAccount | One row per run/account; mutually exclusive Stage output fields |
| ecl_result | ECLPortfolioSummary | One row per run/product/Stage/aggregation level/pool key |
| ecl_audit | RunEvent | Append-only run lifecycle and reconciliation events |
| ecl_audit | ValidationError | Persisted validation findings by run and optional business key |

## Keys and constraints

- Surrogate execution key: `RUN_ID` (identity bigint).
- Account snapshot PK: `(RUN_ID, ACCOUNT_ID)`; unique within the run, with PROCESS_DATE repeated for partitioning/reconciliation and explicit lineage.
- PD curve PK: `(RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD)`.
- LGD curve PK: `(RUN_ID, ACCOUNT_ID, FORECAST_PERIOD)`.
- EAD curve PK: `(RUN_ID, ACCOUNT_ID, FORECAST_PERIOD)`.
- EIR curve PK: `(RUN_ID, FORECAST_PERIOD)`.
- ECL detail PK: `(RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD)`.
- Account output PK: `(RUN_ID, ACCOUNT_ID)`.
- Portfolio summary PK: `(RUN_ID, POOL_NAME, STAGE, AGGREGATION_LEVEL, POOL_ID)`. `AGGREGATION_LEVEL` is `PORTFOLIO` or `POOL`; portfolio-wide rows use `POOL_NAME='__ALL_POOLS__'` and `POOL_ID='__ALL_POOLS__'`; pool-level rows use the actual pool name and pool ID. This avoids nullable columns in the primary key.
- FKs enforce pool/scenario/run lineage and result-to-input account existence.
- Check constraints reject invalid Stage, PD/LGD/weight ranges, negative EAD/ECL and invalid run states.
- Indexes target run-first access patterns, account/pool joins, pool/Stage aggregation and audit lookup.

## Management fields and rerun semantics

- `PROCESS_DATE`: reporting/as-of date.
- `RUN_ID`: isolated execution and immutable snapshot namespace.
- `VERSION_ID`: source/logical dataset version; for scenario weights it points to an explicit version record.
- `IS_ACTIVE`: candidate version selection flag at load/configuration time. Deactivating a version must not rewrite old snapshots or change the results of prior runs.
- POCI validation is configuration-driven. The configured severity is recorded in `ecl_audit.ValidationError`; regardless of severity, POCI is never included in ordinary ECL calculation in v1. ERROR/FATAL stops the run, while WARN allows continuation only after excluding and reconciling the account.
- `CALCULATION_VERSION`: explicit algorithm/schema release identity.

A run must transition through controlled states. Only a fully validated, calculated and reconciled run can become `SUCCEEDED`; publication is a separate state. A rerun receives a new RUN_ID. Do not overwrite previous result rows. A transaction and/or publish pointer should be added when publication procedures are implemented.

## Important implementation caveats

1. **PD/LGD/EAD grains are approved at account level.** PD is account × scenario × period; LGD and EAD are account × period. Validate period semantics, units and curve coverage before calculation.
2. EAD is annual EAD at expected default using the year-end convention, as selected. The lifetime curve is used through each account's maturity date. In a partial final year, use the supplied annual EAD unchanged; do not multiply it by the remaining-month fraction.
3. PD is supplied upstream as annual unconditional marginal PD on the original cohort. Use the supplied annual PD unchanged in a partial final year; do not apply a linear or hazard-based prorating transformation.
4. **EIR curve is shared across pools**. The selected discount factor is `DF(t) = 1 / (1 + EIR(t))^t`, where `t` is elapsed forecast time in years, including the remaining-month fraction for the partial final year. Example: 6 months into the fourth forecast year gives `t = 3.5`. Only discounting time uses the partial-year fraction; PD and EAD remain unchanged. No calculation procedure is implemented here.
5. `ScenarioWeight` DDL stores weights by version and scenario. Weight-sum and exact effective-version selection are run-time validation rules, not enforced by a row-level CHECK constraint.
6. `ECLPortfolioSummary` uses a non-null `AGGREGATION_LEVEL` and `POOL_ID`; portfolio-wide rows use `AGGREGATION_LEVEL='PORTFOLIO'` and `POOL_ID='__ALL_POOLS__'`, while pool rows use `AGGREGATION_LEVEL='POOL'`, the actual pool name, and a real pool ID.
7. `IS_ACTIVE` is included on standardized inputs as requested, but each run should snapshot only the selected active version. It is not a substitute for run isolation.
8. Currency handling is explicit on EAD; all amounts must be in a consistent reporting currency before aggregation. Conversion logic is outside this DDL.
9. Stage 3 uses PD=1, the same annual EAD/LGD curves as Stage 2, and annual discounting/aggregation. Lifetime horizon is each account's MATURITY_DATE. Scenario weights are Downturn 15.68%, Base 68.64%, Upturn 15.68%.

## Deployment

Run `database/001_create_logical_schema.sql` only in a disposable or explicitly approved development database. It is an initial-create script, not an idempotent migration or rollback script. It inserts canonical pool-name and scenario codes and deliberately does not seed scenario weights. No customer-level data or credentials are included.
