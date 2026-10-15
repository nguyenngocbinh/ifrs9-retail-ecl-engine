# Logical input/output contract

This document defines logical contracts only. It intentionally does not specify physical SQL Server table names, schemas, or column data types before actual source definitions are inspected.

## 1. Run parameters

| Field | Meaning |
|---|---|
| Run ID | Unique identifier for the execution |
| Reporting date | As-of date for the portfolio |
| Run scope | Full portfolio or selective |
| Product filter | Optional allowed product selection |
| Pool filter | Optional pool selection |
| Source versions | Identifiers or timestamps for all upstream source snapshots |
| Calculation version | Version of calculation methodology/code |
| Requested by / timestamp | Audit metadata, subject to platform conventions |

## 2. Logical input entities

### Account / staging / pool
- Reporting date
- Stable account or facility identifier
- Product
- Pool
- Stage (one Stage per account/reporting date)
- POCI identification/status or documented proof of exclusion

### Scenario PD curve
- Reporting date and account/facility identifier, or approved calculation grain and its mapping to account-level output
- Scenario: Downturn, Base, Upturn
- Forecast period index and period end
- Annual unconditional marginal PD on original cohort
- Source version

### LGD curve
- Key and grain to be confirmed from real source
- Forecast period index / period end as applicable
- LGD and scaling/unit definition
- Scenario behavior (assumed common across scenarios for initial scope)
- Source version

### EAD curve
- Key and grain to be confirmed from real source
- Forecast period index / period end
- EAD at default using year-end convention (source semantics to be verified)
- Currency/unit and scaling definition
- Scenario behavior (assumed common across scenarios for initial scope)
- Source version

### Scenario weights
- Reporting date/effective date as applicable
- Scenario
- Approved weight
- Approval/version identifier

### EIR curve
- Key and grain (currently assumed common across pools) to be confirmed
- Forecast period index and effective rate
- Rate convention, compounding, time basis, and discounting policy identifier
- Source version

## 3. Logical calculation detail output

Proposed detail grain: run ID × reporting date × account/facility × Stage × scenario × forecast period, or a different approved grain if upstream inputs require it.

Candidate fields:
- Run ID, reporting date, account/facility ID, product, pool, Stage
- Scenario, scenario weight, forecast period, period end
- Source PD, LGD, EAD at default, EIR
- Applied discount factor
- Unweighted ECL contribution by period/scenario
- Weighted ECL contribution by period/scenario
- Calculation version and source-version references

## 4. Account output

Proposed unique grain: run ID × reporting date × account/facility ID.

Fields:
- Product, pool, Stage
- `ECL_12_MONTH`, `ECL_LIFETIME`, `ECL_DEFAULT` as mutually exclusive Stage outputs
- Final Stage ECL amount (single appropriate category for the account)
- Currency
- Validation/reconciliation status

## 5. Aggregated output

Required dimensions:
- Reporting date
- Run ID
- Product
- Pool
- Portfolio
- Stage / ECL output category

Required measures:
- Account/facility count
- ECL amount
- Optional reconciliation totals and exception counts

## 6. Validation and publication metadata

- Run status: created, validating, calculating, reconciling, published, failed, cancelled (final permitted states to define).
- Input record counts, rejected record counts, duplicate/missing-key counts.
- Scenario weight sum and tolerance used.
- ECL totals by Stage/product/pool/portfolio.
- Reconciliation status and exception references.
- Start/end timestamp and failure message.

The physical schema, nullable behavior, data types, currency precision, primary keys, and indexes are not yet defined. They must be based on repository/source metadata and tested against SQL Server 2016.