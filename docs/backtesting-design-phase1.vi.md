# ECL backtesting — Phase 1 design (12-month default outcome)

Status: implementation proposal on feature branch; not approved as production methodology.

## Confirmed requirements

- Portfolio: all Retail pools represented by published ECL runs.
- Runtime: SQL Server / T-SQL.
- Historical ECL: published results are available.
- Account identifier: stable across monthly snapshots.
- Default source: a default date is available.
- First horizon: 12 months.
- Actual monetary loss: not defined yet; this phase must not claim to validate ECL amount against actual loss.
- Development controls: feature branch + pull request; no direct changes or merge to `main`.

## Repository facts verified

The canonical engine schema currently provides:
- `ecl_core.RunControl`: `RUN_ID`, `PROCESS_DATE`, `RUN_STATUS`, `SCENARIO_WEIGHT_VERSION_ID`, calculation version.
- `ecl_stg.AccountSnapshot`: one row per `RUN_ID + ACCOUNT_ID`, with `PROCESS_DATE`, `POOL_NAME`, `STAGE`, `IS_ACTIVE`.
- `ecl_stg.PDCurve`: account/scenario/forecast-period marginal PD.
- `ecl_cfg.ScenarioWeight`: scenario weights versioned by the source run.
- `ecl_result.ECLAccount`: account-level ECL components and total.
- A source run is considered eligible only if `RunControl.RUN_STATUS = 'PUBLISHED'`.

The confirmed outcome source is `[DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB]`, a monthly month-end account-level view. `ecl_bt.CohortAccount.ACCOUNT_ID` maps to source `contract_id` (business mapping: `account_id = contract_id`). Source fields used by the loader are `process_date`, `current_gb`, and `default_flag`. `first_to_default` exists only in the customer-level source and is not required for Phase 1 because the account-level `default_flag` is the 12-month outcome label. `current_gb = 1` means already defaulted at the cohort date; `current_gb = 0` means not defaulted at the cohort date. `default_flag = 1` is the forward 12-month default label, not the current default status. No production/customer rows or credentials belong in this repository.

## Phase 1 objective

Build auditable monthly cohorts from published runs and preserve:
1. the exact published source `RUN_ID` and `PROCESS_DATE`;
2. account-level ECL output as published;
3. a scenario-weighted period-1 PD forecast for 12-month default calibration;
4. Stage and pool at the cohort date;
5. outcome status and observation cutoff separately from forecast fields.

This phase supports default-rate / PD calibration. It does **not** calculate actual loss, LGD accuracy, EAD accuracy, or monetary ECL bias.

## Cohort and eligibility rules

- A cohort is the active account snapshot of one published `RUN_ID` at one `PROCESS_DATE`.
- Multiple monthly cohorts may contain the same account; they are separate observations and must not be deduplicated across dates.
- Forecasts are frozen from the source run. Do not recalculate a historical forecast with current curves or current scenario weights.
- 12-month PD forecast is `SUM(MARGINAL_PD(period 1, scenario) * scenario weight)` using the source run's scenario-weight version.
- Stage 3 at the cohort date is excluded from the at-risk 12-month default-rate denominator because it is already in default/credit-impaired status under the engine's current Stage convention. Keep it in cohort storage for traceability, but set PD-backtest eligibility false.
- Stage 1 and Stage 2 are eligible only when all three scenario PD values and all three source-version weights are available and valid.
- Default within the observation window is `DEFAULT_DATE > PROCESS_DATE AND DEFAULT_DATE <= DATEADD(month, 12, PROCESS_DATE)`. Default on or before the cohort date is not a future default.
- For `current_gb = 0` and `default_flag = 0`, classify `OBSERVED_NO_DEFAULT` only when `OUTCOME_AS_OF_DATE` reaches the full 12-month horizon; otherwise classify `IMMATURE`.
- By the user's agreed operational rule, a missing account snapshot or invalid/missing `current_gb`/`default_flag` is classified as `OBSERVED_NO_DEFAULT` but must create a `WARN` finding. If the entire source snapshot is missing for a cohort date, create an additional cohort-level `OUTCOME_SOURCE_SNAPSHOT_EMPTY` warning. These rows must remain visible in data-quality reporting so a missing source feed cannot silently look like a good backtest.
- Duplicate source rows for the same account/date are `DATA_ISSUE` and excluded from PD backtest eligibility.
- The default source must be mapped in the private target environment. Store source object/version metadata, not customer-level records or credentials, in repository files.

## Initial physical design

Migration `010_ecl_backtest_foundation.sql` creates:
- `ecl_bt.BacktestRun`: backtest configuration and lifecycle.
- `ecl_bt.CohortAccount`: frozen account forecast and cohort dimensions, linked to published ECL account output.
- `ecl_bt.AccountOutcome`: default observation status, default date, and observation cutoff, independent from forecasts.
- `ecl_bt.BacktestFinding`: data quality / eligibility findings.

Procedure `ecl_bt.usp_Build12MonthCohort` builds the frozen cohort from a published source run. Migration `011_ecl_backtest_load_account_outcomes.sql` adds `ecl_bt.usp_Load12MonthAccountOutcomes`, which joins the account-level monthly source snapshot by account and `PROCESS_DATE`. It distinguishes `ALREADY_DEFAULTED` (`current_gb = 1`) from future default (`current_gb = 0` and `default_flag = 1`), without requiring `first_to_default`. `default_flag = 0` is treated as observed no-default only when `OUTCOME_AS_OF_DATE` reaches the full horizon. Missing snapshots or invalid/missing flags follow the agreed non-default treatment but emit account-level `WARN` findings; a completely empty source snapshot emits an additional cohort-level warning. Duplicate source rows are `DATA_ISSUE`; incomplete horizons for valid `default_flag = 0` records are `IMMATURE`.

## First metrics

At cohort date, by monthly cohort / pool / Stage / portfolio:
- eligible account count;
- mature outcome count and immature/data-issue count;
- observed 12-month default count and default rate;
- expected default count as the sum of account-level 12-month PD over the same eligible, mature denominator;
- observed-to-expected (O/E), only when expected defaults > 0;
- calibration difference: observed default rate minus mean predicted PD.

Do not use an arbitrary universal pass/fail threshold. Thresholds and escalation require model-risk owner approval. Consider overlapping monthly cohorts when interpreting trends; they are not independent samples.

## Unresolved decisions / required source checks

1. Confirmed source mapping is in place; still validate the `contract_id` datatype, uniqueness per `process_date`, and the source's handling of cures/re-defaults in DEV/UAT.
2. Whether the source provides complete as-of history, including corrections/backdated default dates, and whether historical `default_flag` values are restated after corrections.
3. How to prove observation completeness to `PROCESS_DATE + 12 months`; snapshot disappearance alone is not proof of no default.
4. Account closures/payoffs during the window and whether they count as observed non-defaults.
5. Approved minimum sample size, calibration thresholds, segment grouping, and reporting frequency.
6. Actual loss definition, recoveries, write-offs, costs, discounting and workout maturity. This is explicitly deferred.
7. Source run statuses and whether all required historical published runs remain queryable.

## Test plan before use

Use synthetic SQL fixtures only:
- published vs unpublished source run;
- source run outside configured cohort date range;
- all scenario PDs present and missing scenario;
- Stage 3 excluded from PD denominator;
- `current_gb = 1` at cohort date;
- `current_gb = 0` with `default_flag = 1` (without requiring a default date);
- `default_flag = 0` with mature and immature observation windows;
- missing and duplicate source account/date rows;
- invalid/missing flags create warnings and use the agreed non-default treatment;
- an entirely empty source snapshot creates a cohort-level warning;
- immature observation and missing default source record;
- repeated account across monthly cohorts;
- reconciliation between cohort rows and active account snapshots;
- zero expected defaults and no division-by-zero;
- no changes to `ecl_result` historical rows.

## Deployment boundary

Deploy only to a disposable DEV/UAT database after review. The migration is additive and is not wired into existing ECL calculation or publication. Do not run it against production without change approval, backup/rollback plan, and target-database source mapping.
