# Canonical input contract — v1

Status: agreed logical interface baseline for the current implementation phase. Canonical tables and their forms are the input interface; the user will populate them. This document does not require production source surveys or upstream source-to-column mapping for this phase.

## 1. Run-wide invariants

Every staged row belongs to exactly one `RUN_ID` and has the same `PROCESS_DATE` as `ecl_core.RunControl`. The run binds an explicit `SCENARIO_WEIGHT_VERSION_ID`; a rerun creates a new `RUN_ID`. Input family versions and row counts are recorded in `RunInputManifestItem`.

Input reconciliation currently compares manifest counts with physical staging counts, including inactive rows. Therefore `SNAPSHOT_ROW_COUNT` means the number of rows physically staged for that run and family, including inactive rows. If the source count is defined differently, ingestion must transform or separately record the source count rather than treating a mismatched count as reconciled.

## 2. Logical input families

| Family | Logical grain / key | Required semantics |
|---|---|---|
| ACCOUNT | `RUN_ID + ACCOUNT_ID` | One account snapshot; `PROCESS_DATE`, product, Stage, pool, maturity, source version and active flag. |
| PD | `RUN_ID + ACCOUNT_ID + SCENARIO_CODE + FORECAST_PERIOD` | Scenario-specific unconditional marginal annual PD for the original cohort; periods are full annual periods. Values are supplied upstream; do not derive PD from PD FWL ± 1 SE. |
| LGD | `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD` | Undiscounted loss-given-default ratio for each full annual period. Flat across scenarios in v1. |
| EAD | `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD` | Exposure at expected default under the agreed year-end annual-period convention; VND in v1. No partial-year prorating. |
| EIR | `RUN_ID + FORECAST_PERIOD` | One shared FTP selling-funds rate for 12 months for each forecast period; same rate curve is applied across accounts/pools and all stages. The numeric value is dimensionless and consumed as supplied, without percentage/decimal conversion. |
| SCENARIO_WEIGHT | `VERSION_ID + SCENARIO_CODE` | Downturn 0.1568, Base 0.6864, Upturn 0.1568 for the selected configuration version; sum is 1. Version and effective-date history are retained. |

All curve rows must be compatible with the run's reporting date and input version. Forecast periods start at 1. Curves must cover the full annual periods needed through each account's contractual maturity.

## 3. FTP 12-month EIR and discount-time convention

The EIR input is the supplied FTP selling-funds rate for 12 months. The engine does not estimate EIR or build a term structure. Keep `RATE_BASIS='FTP_12M'` as the source semantic identifier; do not silently relabel it as annual-effective or nominal.

The numeric value has no unit and must be consumed as supplied. Do not multiply or divide by 100, infer a percentage convention, or apply any other transformation. The agreed discount formula remains:

`DF(t) = 1 / (1 + EIR(t)) ^ t`

For a maturity horizon of 3 years and 6 months, PD and EAD still use the supplied annual-period values; only the discount-time exponent is `t = 3.5`. The applicable shared FTP 12-month rate is selected from the configured forecast-period mapping. This is the agreed simplified v1 convention, not a claim that FTP 12-month is economically equivalent to an effective annual EIR.

## 4. Stage contract

- Stage 1 output category: `ECL_12_MONTH`.
- Stage 2 output category: `ECL_LIFETIME`.
- Stage 3 output category: `ECL_DEFAULT`; follow the same calculation logic as Stage 2 with the only change being PD = 1. Use the same annual EAD/LGD curves, shared EIR, discount-time convention, discounting, and aggregation.
- Stage 1, Stage 2 and Stage 3 use the same shared EIR curve and the same discount formula `DF(t)=1/(1+EIR(t))^t`. Stage 3 does not have a separate EIR curve or discount-rate rule.
- LGD inputs are defined as undiscounted in the canonical contract. No additional unresolved Stage 3 source-mapping or source-survey gate is imposed in this phase.

## 5. Scenario-weight configuration

- The engine uses the scenario weights supplied in the selected configuration version.
- The selected version must be effective on `PROCESS_DATE` and contain active Downturn, Base and Upturn weights summing to 1 within the configured tolerance.
- A changed weight set is represented by a new `VERSION_ID` and effective dates so prior runs can retain the version they used.
- Approval references, approver identity, approval timestamps and change-reason metadata are not prerequisites to input validation or calculation.

## 6. Required pre-calculation assertions

1. All six manifest families are complete and reconcile to physical staged row counts.
2. Staging rows match the run's `PROCESS_DATE`; account keys and curve grains are unique.
3. Active accounts have required curve coverage through maturity.
4. PD values are in [0,1]; LGD values are in [0,1]; EAD is non-negative and denominated in VND.
5. One shared EIR value exists per required full forecast period and its supplied value is greater than -1 under the selected discount formula. Do not transform the value.
6. The selected scenario-weight version is effective on `PROCESS_DATE`, contains all three scenarios and sums to 1 within the configured tolerance.
7. Stage 3 uses the same EAD/LGD curves and EIR discount convention as Stage 2, with PD=1 as the only calculation difference.
8. No ECL formula or publication is enabled merely because structural checks pass.

## 7. Current phase boundaries

- Canonical input tables/forms are the agreed interface. The user populates them; synthetic data is used for automated regression.
- Upstream source-to-column mapping, source-owner evidence, and production database surveys are not required gates for this phase.
- SQL Server 2022 is the CI target. SQL Server 2016 compatibility verification is not required.
- POCI is outside the current canonical contract. Historical migrations/tests may retain legacy POCI behavior; do not alter those historical behaviors without a separate cleanup decision.
- ECL calculation formulas and publication remain blocked until the safety regression gates are reviewed and green. Result-level rerun idempotency and transactional publication atomicity can only be tested after their respective procedures exist.

## 8. Shared EAD loading

- Product-specific ETL calculates one annual EAD value per account and forecast period, then writes it directly into canonical `ecl_stg.EADCurve`. No separate `EADCurveInput` table is used.
- The common procedure `ecl_core.usp_LoadEADCurve @RUN_ID` validates the rows already loaded into `ecl_stg.EADCurve` and records the successful validation in `ecl_audit.RunEvent`; it does not copy, transform, or calculate EAD.
- The run's `PROCESS_DATE` must match the run control and account snapshot; currency must be VND; EAD must be non-negative.
- Every active account must have active EAD rows for all annual forecast periods through maturity, with a maximum supported horizon of 120 periods.
- Auto and Non-Revolving source ETL are responsible for source-specific schedule/balance transformations before inserting into the canonical table. The shared procedure does not infer settlement, write-off, waiver, or amortization semantics.
- `ecl_core.usp_CalculateECL` continues to consume `ecl_stg.EADCurve` unchanged.


## 9. Shared PD loading

- Source-specific ETL must resolve the facility rating, approved business segment, source bucket, reporting date, forecast period, and scenario before inserting into canonical `ecl_stg.PDCurve`.
- `ecl_core.usp_LoadPDCurve @RUN_ID` validates the rows already loaded into `ecl_stg.PDCurve`; it does not calculate PD or silently infer source scenario codes.
- Every PD row must match the run `PROCESS_DATE` and an active account snapshot. Values must be within [0,1].
- Every active account must have active rows for `DOWNTURN`, `BASE`, and `UPTURN` for each annual forecast period through maturity (maximum 120 periods).
- `database/008_retail_marginal_pit_pd_source_loader.sql` implements the source-specific transformation from `TBL_MAN_FACILITY_RATING` and `RETAIL_MARGINAL_PIT_PD` into `PDCurve`. It joins on `BUCKET`, `RATING`, and `ecl_cfg.PoolName.SEGMENT = SEGMENT_LV2`; facility rating is matched by run `PROCESS_DATE` and `POOL_NAME`.
- The source PD table's `PROCESS_DATE` is treated as a dataset-version marker. The loader selects `MAX(PROCESS_DATE)` and records a `WARN` in `ecl_audit.ValidationError` plus a `WARNING` run event containing the selected date; this source date is not required to equal the ECL run date.
- Source `SCENARIO` values 1/2/3 must be mapped explicitly using the procedure parameters. The loader intentionally does not assume their semantic order. The source period is converted to a positive annual `FORECAST_PERIOD` relative to the run date.
