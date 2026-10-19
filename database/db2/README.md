# DB2 Auto EAD staging

This directory contains a DB2 LUW staging implementation for calculating Auto-loan EAD from the contractual principal schedule. It is intentionally isolated from the repository's SQL Server/T-SQL calculation runtime.

## Objects

- `001_create_auto_ead_schedule.sql`: creates `RM_RDM_MOP_PROD.TBL_AUTO_EAD_SCHEDULE`.
- `002_sp_calc_auto_ead.sql`: creates `RM_RDM_MOP_PROD.SP_CALC_AUTO_EAD(P_PROCESS_DATE)`, which replaces rows for the given reporting date and inserts one row per future principal schedule line.

## Run order

Execute both files using a DB2 client connected to the environment containing the upstream tables:

1. `database/db2/001_create_auto_ead_schedule.sql`
2. `database/db2/002_sp_calc_auto_ead.sql`

Then call:

```sql
CALL RM_RDM_MOP_PROD.SP_CALC_AUTO_EAD(DATE('2026-09-30'));
```

Inspect the staged rows:

```sql
SELECT *
FROM RM_RDM_MOP_PROD.TBL_AUTO_EAD_SCHEDULE
WHERE PROCESS_DATE = DATE('2026-09-30')
ORDER BY ACCOUNT_NUMBER, SCHEDULE_DUE_DATE, SCHEDULE_NO;
```

## Current assumptions and boundaries

- `FCC_RPTB_CL020.OUTSTANDINGVND` supplies `EAD_0` at `P_PROCESS_DATE`.
- `FCC_LOAN_SCHEDULE.AMOUNT_DUE` is used as scheduled principal repayment for due dates after `P_PROCESS_DATE`.
- Schedule rows are sourced from the currently available schedule snapshot. In the observed source, `PROCESS_DATE` is a snapshot/update date, not a historical as-of schedule date. Confirm that the schedule is appropriate for the reporting date before production use.
- This first pass does not apply `AMOUNT_SETTLED`, readjustments, waivers, write-offs, product-scope filtering, or additional data-quality rules.
- `EAD_AFTER_REPAYMENT` is the balance after cumulative scheduled principal at each due date; it is not yet a year-end EAD curve.
- The DB2 objects rely on upstream tables in `TPBCSO_SEC` and are not part of SQL Server migrations 001–005 or SQL Server CI.
