# IFRS 9 Retail ECL Engine

Production-oriented IFRS 9 expected credit loss (ECL) calculation engine for retail lending products, implemented in T-SQL for SQL Server 2016.

> **Status:** Documentation foundation (PR #1). No calculation SQL is implemented yet. Methodology items marked open must be resolved against approved policy and source-system definitions before they are encoded.

## Scope

Products in scope: Mortgage, Auto, Credit Card, Personal Loan, and Other Retail.

The engine consumes approved upstream data. It does not build PD, LGD, EAD, pool assignment, or Stage/SICR models.

- PD: annual unconditional marginal PD on the original cohort, supplied upstream for Downturn, Base, and Upturn scenarios.
- LGD: supplied upstream; currently assumed flat across scenarios.
- EAD: supplied upstream as annual EAD at default with a year-end convention; the exact interpretation must be confirmed against the source methodology.
- Stage / SICR and pool: supplied upstream.
- Scenario weights: Downturn 15.68%, Base 68.64%, Upturn 15.68%; authoritative source table must be identified.
- SQL runtime: SQL Server 2016, T-SQL only. Python is not part of the calculation engine.

## Stage mapping

| Stage | ECL horizon | Output category |
|---|---|---|
| Stage 1 | 12-month ECL | `ECL_12_MONTH` |
| Stage 2 | Lifetime ECL | `ECL_LIFETIME` |
| Stage 3 | Lifetime/default ECL using PD = 1 | `ECL_DEFAULT` |

Stage outputs are mutually exclusive at account/reporting-date grain. Do not add `ECL_DEFAULT` again into `ECL_LIFETIME` when aggregating the portfolio. POCI is excluded from the initial scope.

## Scenario and discounting assumptions

Three scenario PD curves are supplied upstream; the engine must not derive scenario PD from `PD FWL ± 1 SE`. Standard error, if present in source data, is audit/control information only.

The currently recorded discounting proposal is `DF(t) = 1 / (1 + EIR(t))^t`, where `t` is forecast year and the period-specific EIR is read from an existing source. This is a **verification blocker**: when EIR varies by period, this formula is not generally equivalent to cumulative discounting. Do not silently change it; reconcile it with the approved accounting methodology before implementation.

## Architecture

1. Validate and version input snapshots.
2. Create a controlled ECL run with a unique run ID.
3. Calculate account-period-scenario ECL using approved conventions.
4. Aggregate to account, pool, product, and portfolio outputs.
5. Reconcile counts and amounts, and publish only a fully successful run.
6. Retain immutable run/input references and implementation logs for auditability.

See:
- [Architecture](docs/architecture.md)
- [Methodology specification](docs/methodology-specification-v1.0.md)
- [Input/output contract](docs/input-output-contract.md)
- [Open questions and blockers](docs/open-questions.md)
- [PR #1 implementation log](docs/implementation-log/PR-001.md)

## Development sequence

- PR #1: documentation foundation and methodology/open-question register.
- PR #2: inspect and document real source schemas, keys, grains, and data lineage.
- PR #3: run control, input snapshot, and validation framework.
- Later PRs: calculation routines, deterministic test fixtures, reconciliation, publication, deployment, and CI.

Never invent physical source table names, keys, or data types. Do not include customer data in public fixtures.