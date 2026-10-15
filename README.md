# IFRS 9 Retail ECL Engine

Production-oriented IFRS 9 expected credit loss (ECL) calculation engine for retail lending products, implemented in T-SQL for SQL Server 2016.

> **Status:** Documentation and logical-schema proposal are under review. No ECL calculation procedure is implemented. Methodology items marked open must be resolved before executable formulas are encoded.

## Scope

Products in scope: Mortgage, Auto, Credit Card, Personal Loan, and Other Retail.

The engine consumes approved upstream data. It does not build PD, LGD, EAD, pool assignment, or Stage/SICR models.

- PD: annual unconditional marginal PD on the original cohort, supplied upstream for Downturn, Base, and Upturn scenarios.
- LGD: supplied upstream; currently assumed flat across scenarios.
- EAD: supplied upstream as annual EAD at default with a year-end convention; exact interpretation remains to be confirmed.
- Stage / SICR and pool: supplied upstream.
- Scenario weights: Downturn 15.68%, Base 68.64%, Upturn 15.68%; authoritative source/version selection remains to be approved.
- SQL runtime: SQL Server 2016, T-SQL only. Python is not part of the calculation engine.

## Stage mapping

| Stage | ECL horizon | Output category |
|---|---|---|
| Stage 1 | 12-month ECL | `ECL_12_MONTH` |
| Stage 2 | Lifetime ECL | `ECL_LIFETIME` |
| Stage 3 | Lifetime/default ECL using PD = 1 | `ECL_DEFAULT` |

Stage outputs are mutually exclusive at account/reporting-date grain. Do not add `ECL_DEFAULT` again into `ECL_LIFETIME` when aggregating the portfolio. POCI is excluded from the initial scope.

## Database design

The proposed functional schemas are `ecl_cfg`, `ecl_stg`, `ecl_core`, `ecl_result`, and `ecl_audit`. Inputs are normalized into separate tables: PD at account/scenario/period, LGD and EAD at account/period, and shared EIR at period grain. Results use a shared product discriminator and are stored at account/run grain with a scenario-period detail layer.

See [Logical database schema v1.0](docs/database-schema-v1.0.md) and [initial SQL Server 2016 DDL](database/001_create_logical_schema.sql). The DDL is a review proposal and has not been deployed to a live SQL Server instance.

## Scenario and discounting assumptions

Three scenario PD curves are supplied upstream; the engine must not derive scenario PD from `PD FWL ± 1 SE`. Standard error, if present in source data, is audit/control information only.

The recorded discounting proposal is `DF(t) = 1 / (1 + EIR(t))^t`, where `t` is forecast year and period-specific EIR is read from an existing source. This is a verification blocker: if EIR varies by period, this formula is not generally equivalent to cumulative discounting. Do not silently change it; reconcile it with approved accounting methodology. Stage 3 EAD/LGD allocation is also unresolved. No calculation formula will be implemented until both decisions are approved.

## Development sequence

- PR #1: documentation foundation and methodology/open-question register.
- PR #2: source inventory toolkit and templates (separate, reviewable change).
- PR #3: functional schemas, normalized logical input tables, run/audit/output DDL proposal.
- Later PRs: input quality gates, snapshot/version binding, calculation routines, deterministic synthetic tests, reconciliation, publication, deployment, and CI.

No source survey is required to design the logical schema. Physical source mappings remain out of scope. Never include customer-identifiable data in public fixtures.
