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

All curve rows must be compatible with the run's reporting date and input version. Forecast periods start at 1. For accounts that have not matured, curves must cover the full annual periods needed through contractual maturity. For unpaid accounts whose `PROCESS_DATE >= MATURITY_DATE`, apply the post-maturity convention in Section 8.1.

## 3. FTP 12-month EIR and discount-time convention

The EIR input is the supplied FTP selling-funds rate for 12 months. The engine does not estimate EIR or build a term structure. Keep `RATE_BASIS='FTP_12M'` as the source semantic identifier; do not silently relabel it as annual-effective or nominal.

The numeric value has no unit and must be consumed as supplied. Do not multiply or divide by 100, infer a percentage convention, or apply any other transformation. The agreed discount formula remains:

`DF(t) = 1 / (1 + EIR(t)) ^ t`

For a maturity horizon of 3 years and 6 months, PD and EAD still use the supplied annual-period values; only the discount-time exponent is `t = 3.5`. The applicable shared FTP 12-month rate is selected from the configured forecast-period mapping. This is the agreed simplified v1 convention, not a claim that FTP 12-month is economically equivalent to an effective annual EIR.

## 4. Stage contract

- Stage 1 output category: `ECL_12_MONTH`.
- Stage 2 output category: `ECL_LIFETIME`.
- Stage 3 output category: `ECL_DEFAULT`. Because Stage 3 PD is fixed at 1 (100%), calculate Stage 3 ECL only for `FORECAST_PERIOD = 1`, regardless of whether `MATURITY_DATE` is before, equal to, or after `PROCESS_DATE`. Use period-1 EAD/LGD/EIR and a one-year discount exponent (`t = 1`). Do not generate or sum Stage 3 periods 2+.
- For an active unpaid account with `MATURITY_DATE <= PROCESS_DATE`, use exactly `FORECAST_PERIOD = 1` as the post-maturity processing period, regardless of Stage. Calculate ECL using the period-1 PD/LGD/EAD and shared EIR inputs; use a one-year discount exponent for this designated period. Do not generate or sum periods 2+ for the post-maturity case. This is a v1 processing convention, not an assumption that all loans become Stage 3 solely because maturity has passed. Stage 3 also uses period 1 only when maturity is still in the future, because its PD is already 100%.
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
3. Stage 1/2 accounts have required curve coverage through contractual maturity; Stage 3 and accounts at/after maturity require only period-1 curve coverage.
4. PD values are in [0,1]; LGD values are in [0,1]; EAD is non-negative and denominated in VND.
5. One shared EIR value exists per required full forecast period and its supplied value is greater than -1 under the selected discount formula. Do not transform the value.
6. The selected scenario-weight version is effective on `PROCESS_DATE`, contains all three scenarios and sums to 1 within the configured tolerance.
7. Stage 3 uses PD=1 and only period-1 EAD/LGD/EIR inputs; its discount exponent is 1.0 and no period-2+ ECL is generated. Stage 1/2 retain their existing horizon logic.
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
- For accounts that have not matured, Stage 1/2 must have active EAD rows for all annual forecast periods through contractual maturity, with a maximum supported horizon of 120 periods. Stage 3 requires only period-1 EAD because its calculation horizon is fixed at one period.
- Auto and Non-Revolving source ETL are responsible for source-specific schedule/balance transformations before inserting into the canonical table. The shared procedure does not infer settlement, write-off, waiver, or amortization semantics.

### 8.1. Unpaid accounts at or after contractual maturity

- If an account remains unpaid and `PROCESS_DATE >= MATURITY_DATE`, use `FORECAST_PERIOD = 1` as the post-maturity processing period. Do not derive a zero/negative forecast period from the elapsed contractual maturity date, and do not omit the account from ECL solely because contractual maturity has passed.
- The period-1 EAD must represent the exposure determined under the applicable source/product rules for that account as of the reporting date. The `FORECAST_PERIOD = 1` rule defines the processing-period convention; it does not itself determine the EAD amount, recovery cash flows, or LGD.
- Apply the existing stage-classification rules to the account. Maturity date alone does not determine Stage 3; stage classification remains governed by the bank's default/SICR policy. Stage 3 always uses PD = 1 and period-1 EAD/LGD/EIR, whether or not contractual maturity has passed.
- This is a single-period post-maturity convention for v1, not a claim that the contractual loan has another year to maturity. Do not create additional post-maturity forecast periods unless a separate workout/recovery-horizon methodology is approved.
- The source-specific ETL must supply the required period-1 curve inputs consistently with the canonical input contract. The common EAD loader remains a validator/auditor and must not invent the post-maturity balance or recovery profile.
- `ecl_core.usp_CalculateECL` continues to consume `ecl_stg.EADCurve` unchanged.


## 9. Shared PD loading

- Source-specific ETL must resolve the facility rating, approved business segment, source bucket, reporting date, forecast period, and scenario before inserting into canonical `ecl_stg.PDCurve`.
- `ecl_core.usp_LoadPDCurve @RUN_ID` validates the rows already loaded into `ecl_stg.PDCurve`; it does not calculate PD or silently infer source scenario codes.
- Every PD row must match the run `PROCESS_DATE` and an active account snapshot. Values must be within [0,1].
- Stage 1/2 accounts must have active rows for `DOWNTURN`, `BASE`, and `UPTURN` for each annual forecast period through maturity (maximum 120 periods). Stage 3 accounts require these three scenario rows only for `FORECAST_PERIOD = 1`.
- The source `RETAIL_MARGINAL_PIT_PD` stores `FINAL_MARGINAL_PIT_PD` by `SEGMENT_LV1`, `SEGMENT_LV2`, `BUCKET`, `RATING`, and `SCENARIO`. Source-to-canonical mapping is configured in `ecl_cfg.Scenario` by `SOURCE_SCENARIO_CODE`; do not hard-code numeric scenario mappings in ETL procedures. The initial seed for `RETAIL_MARGINAL_PIT_PD` is `1 = BASE`, `2 = UPTURN`, `3 = DOWNTURN`.
- The source ETL procedure is `ecl_core.usp_StageSourcePDCurve`, defined in `database/upstream/003_load_pd_curve_source.sql`. It joins facility rating to the active run snapshot by `ACCOUNT_ID` and `REPORTING_DATE`, then joins PD by `BUCKET`, `RATING`, and `ecl_cfg.PoolName.SEGMENT = SEGMENT_LV2`. It uses `PERIOD` as `FORECAST_PERIOD` and `FINAL_MARGINAL_PIT_PD` as `MARGINAL_PD`.
- Deploy the upstream script after the core schema and shared PD validator exist, and only after confirming the actual source database/schema and column definitions. The procedure defaults to source schema `dbo`; pass `@SOURCE_DATABASE` and `@SOURCE_SCHEMA` when needed.
- Scenario-code mappings are stored in `ecl_cfg.Scenario`, seeded by `database/001_create_logical_schema.sql`. The procedure joins this table and fails fast if relevant source rows contain an unmapped code. Update the configuration table—not the procedure—when the source mapping changes. The source `PROCESS_DATE` is not filtered because it is fixed by year.
- The procedure replaces PD rows for the supplied `RUN_ID` transactionally and does not call `usp_LoadPDCurve`; call that validator only after the ETL succeeds.


## 10. Shared LGD loading

- The source `IRB_MHRR.lgd.irb_tt14_nhnn_lgd_upload` provides one account-level observation at `reporting_date`, not a multi-year curve.
- Source ETL `ecl_core.usp_StageSourceLGDCurve @RUN_ID` matches `account_id` to the run's `AccountSnapshot.ACCOUNT_ID`, requires a source row at the run `PROCESS_DATE`, and expands `calibration_lgd` into each full annual forecast period through `MATURITY_DATE` (maximum 120 periods).
- The v1 canonical LGD contract is flat across scenarios, so `calibration_lgd` is used for all periods and scenarios. Source `downturn_lgd` is intentionally not used until scenario-specific LGD is approved as a separate methodology change.
- Canonical `VERSION_ID` is copied from the account snapshot; the source's text `version` is retained as source provenance in operational lineage rather than converted to the integer canonical version.
- Run `ecl_core.usp_LoadLGDCurve @RUN_ID` after source ETL. It validates reporting date, LGD range [0,1], account matching and active coverage through maturity for Stage 1/2; Stage 3 requires only period 1. It then records `LGD_LOAD` in `ecl_audit.RunEvent`.
- Duplicate source rows for an account/reporting date, missing account LGD, or invalid `calibration_lgd` fail the source ETL. Use a new `RUN_ID` for reruns; the loader will not overwrite existing canonical curve rows.
