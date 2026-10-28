# DB2 Non-Revolving EAD staging

This directory contains a DB2 LUW staging implementation for calculating EAD from a contractual principal schedule. The object names use **Non-Revolving EAD** so the naming is not tied to Auto alone. The current SQL uses the existing Auto-related source tables and assumptions; broader Non-Revolving product coverage still requires source/product eligibility review.

## Objects

- `001_create_nonrevolving_ead_schedule.sql`: creates `RM_RDM_MOP_PROD.TBL_NONREVOLVING_EAD_SCHEDULE`.
- `002_sp_calc_nonrevolving_ead.sql`: creates/replaces `RM_RDM_MOP_PROD.SP_CALC_NONREVOLVING_EAD(P_PROCESS_DATE, P_SEGMENT)`.
- `003_rename_auto_ead_objects.sql`: manual migration guidance for environments where the old Auto-named objects already exist.

## Segment mapping and selective execution

The procedure maps the product on the reporting snapshot to its modelling segment through:

```sql
FCC_RPTB_CL020.PRODUCT = RM_RDM_MOP_PROD.PRODUCT_CODE_IFRS9.PRODUCT_CODE
```

and filters on `PRODUCT_CODE_IFRS9.PRODUCT_MODELLING = P_SEGMENT`. For example, the current mapping includes `D20L → Mortgage` and `D41L → Autoloan`; the mapping table remains the source of truth.

Pass a non-empty segment explicitly. The procedure rejects a NULL or blank segment to avoid accidentally scanning and recalculating all segments. A run for one segment deletes/replaces only that segment's output for the given `PROCESS_DATE`; output for other segments on the same date is retained. The target output table does not store a separate `SEGMENT` column, so the delete identifies prior rows belonging to the requested segment by matching their account numbers to the CL020 snapshot and product mapping.

## Run order for a new environment

Execute the first two files using a DB2 client connected to the environment containing the upstream tables:

1. `database/db2/001_create_nonrevolving_ead_schedule.sql`
2. `database/db2/002_sp_calc_nonrevolving_ead.sql`

Example calls:

```sql
CALL RM_RDM_MOP_PROD.SP_CALC_NONREVOLVING_EAD(DATE('2026-09-30'), 'Mortgage');
CALL RM_RDM_MOP_PROD.SP_CALC_NONREVOLVING_EAD(DATE('2026-09-30'), 'Autoloan');
```

Inspect staged rows:

```sql
SELECT *
FROM RM_RDM_MOP_PROD.TBL_NONREVOLVING_EAD_SCHEDULE
WHERE PROCESS_DATE = DATE('2026-09-30')
ORDER BY ACCOUNT_NUMBER, SCHEDULE_DUE_DATE, SCHEDULE_NO;
```

The target table currently does not persist the segment. The mapping used by the procedure therefore controls both selection and segment-scoped replacement; if product mapping changes between runs, review/delete stale rows manually before recalculation.

## Current assumptions and boundaries

- `FCC_RPTB_CL020.OUTSTANDINGVND` supplies `EAD_0` for the exact `P_PROCESS_DATE` snapshot.
- `FCC_LOAN_SCHEDULE.AMOUNT_DUE` is used as scheduled principal repayment for due dates after `P_PROCESS_DATE`.
- If an account exists in the CL020 reporting-date snapshot but has no future principal schedule rows, the procedure emits one synthetic schedule row at `P_PROCESS_DATE` with zero principal repayment and `EAD_AFTER_REPAYMENT = EAD_0`. This preserves the account and carries the current balance forward when the SQL Server annual curve ETL maps the synthetic row to each required year-end period. Treat this as an explicit fallback assumption: it does not infer future principal amortization where no schedule exists.
- Schedule rows are sourced from the currently available schedule snapshot. Confirm it is appropriate for the reporting date before production use.
- This implementation does not apply `AMOUNT_SETTLED`, readjustments, waivers, write-offs, or additional data-quality rules.
- `EAD_AFTER_REPAYMENT` is the balance after cumulative scheduled principal at each due date; it is not yet an annual EAD curve.
- DB2 output still requires an ETL into SQL Server staging, followed by a SQL Server stored procedure to build the canonical `ecl_stg.EADCurve`. That integration is not implemented by these scripts.
- These objects have not been validated against a live DB2 runtime.
