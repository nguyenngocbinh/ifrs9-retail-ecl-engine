# Logical database schema proposal v1.0

## Decision record

This is a logical/canonical contract, not a claim about existing source tables. It is designed for SQL Server 2016 and T-SQL.

- Schemas: `ecl_cfg`, `ecl_stg`, `ecl_core`, `ecl_result`, `ecl_audit`.
- Inputs are normalized into separate tables.
- Product types share one model and one set of result tables; `PRODUCT_TYPE` distinguishes Mortgage, Auto, Credit Card, Personal Loan, and Other Retail.
- Primary business grain is `PROCESS_DATE + ACCOUNT_ID`; every execution is isolated by `RUN_ID`.
- Input rows carry `VERSION_ID` and `IS_ACTIVE`; a run must bind to one immutable set of input versions. `IS_ACTIVE` is selection metadata, not permission to mutate an already captured run.
- PD grain is account × scenario × forecast period; LGD and EAD grains are account × forecast period. EIR is shared by forecast period. Result detail is account × scenario × forecast period. Account output is one row per account/run. Portfolio output stores both portfolio and pool totals.
- No ECL calculation procedure is included. Methodology blockers remain open.

## Schemas and tables

| Schema | Table | Purpose / grain |
|---|---|---|
| ecl_cfg | ProductType | Approved shared product code list |
| ecl_cfg | Scenario | Downturn/Base/Upturn code list |
| ecl_cfg | ScenarioWeightVersion | Version/effective period for scenario weights |
| ecl_cfg | ScenarioWeight | One row per version/scenario; process-date trace |
| ecl_core | RunControl | One row per run, including process date, scope, lifecycle, calculation version |
| ecl_stg | AccountSnapshot | One row per run/account; product, Stage and pool assignment |
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
- Portfolio summary PK: `(RUN_ID, PRODUCT_TYPE, STAGE, AGGREGATION_LEVEL, POOL_ID)`. `AGGREGATION_LEVEL` is `PORTFOLIO` or `POOL`; portfolio-wide rows use the non-null sentinel `POOL_ID='__ALL_POOLS__'`, while pool-level rows must use a real pool ID. This avoids nullable columns in the primary key.
- FKs enforce product/scenario/run lineage and result-to-input account existence.
- Check constraints reject invalid Stage, PD/LGD/weight ranges, negative EAD/ECL and invalid run states.
- Indexes target run-first access patterns, account/pool joins, product/Stage aggregation and audit lookup.

## Management fields and rerun semantics

- `PROCESS_DATE`: reporting/as-of date.
- `RUN_ID`: isolated execution and immutable snapshot namespace.
- `VERSION_ID`: source/logical dataset version; for scenario weights it points to an explicit version record.
- `IS_ACTIVE`: candidate version selection flag at load/configuration time. Deactivating a version must not rewrite old snapshots or change the results of prior runs.
- `CALCULATION_VERSION`: explicit algorithm/schema release identity.

A run must transition through controlled states. Only a fully validated, calculated and reconciled run can become `SUCCEEDED`; publication is a separate state. A rerun receives a new RUN_ID. Do not overwrite previous result rows. A transaction and/or publish pointer should be added when publication procedures are implemented.

## Important implementation caveats

1. **PD/LGD/EAD grains are approved at account level.** PD is account × scenario × period; LGD and EAD are account × period. Validate period semantics, units and curve coverage before calculation.
2. EAD interpretation remains open: confirm whether each period contains EAD-at-default or a marginal/period loss input.
3. PD is account × scenario × period, as selected by the user.
4. **EIR curve is shared across pools** as previously requested. Rate basis and discount-factor methodology remain unresolved; no formula is implemented here.
5. `ScenarioWeight` DDL stores weights by version and scenario. Weight-sum and exact effective-version selection are run-time validation rules, not enforced by a row-level CHECK constraint.
4. `ECLPortfolioSummary` uses a non-null `AGGREGATION_LEVEL` and `POOL_ID`; portfolio-wide rows use `AGGREGATION_LEVEL='PORTFOLIO'` and `POOL_ID='__ALL_POOLS__'`, while pool rows use `AGGREGATION_LEVEL='POOL'` and a real pool ID.
5. `IS_ACTIVE` is included on standardized inputs as requested, but each run should snapshot only the selected active version. It is not a substitute for run isolation.
6. Currency handling is explicit on EAD; all amounts must be in a consistent reporting currency before aggregation. Conversion logic is outside this DDL.
7. Stage 3 uses PD=1 as the selected approach, but EAD/LGD allocation and the period-level loss method remain unresolved. Period-varying EIR discounting, lifetime horizon, and rounding also remain open. Do not implement any calculation formula until these methods are approved.

## Deployment

Run `database/001_create_logical_schema.sql` only in a disposable or explicitly approved development database. It is an initial-create script, not an idempotent migration or rollback script. It inserts shared product/scenario codes and deliberately does not seed scenario weights. No customer-level data or credentials are included.
