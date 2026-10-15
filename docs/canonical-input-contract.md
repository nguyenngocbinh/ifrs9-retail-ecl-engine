# Canonical input contract — v1

Status: logical interface baseline. It does not claim that upstream source mappings or source-system evidence have been certified.

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
- Stage 3 output category: `ECL_DEFAULT`; use PD = 1 and the same annual EAD/LGD curves as Stage 2, then discount annual losses and aggregate.
- Stage 1, Stage 2 and Stage 3 use the same shared EIR curve and the same discount formula `DF(t)=1/(1+EIR(t))^t`. Stage 3 does not have a separate EIR curve or discount-rate rule.
- The user's decision resolves the Stage 3 discount-rate convention. It does not independently certify upstream Stage 3 EAD/LGD timing or confirm that those curves are undiscounted; those source semantics must still be confirmed before Stage 3 calculation is enabled.

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
7. Stage 3 uses the same EIR curve and discount formula as Stage 2. Confirm upstream EAD/LGD timing and discount status before enabling Stage 3 calculation.
8. No ECL formula or publication is enabled merely because structural checks pass.

## 7. Explicitly unresolved items

- Upstream source-to-column mapping and source owner confirmation.
- Confirmation that upstream Stage 3 EAD/LGD curves have the agreed timing and are not pre-discounted.
- Deployment and compatibility verification on SQL Server 2016. Current CI uses SQL Server 2017 and is not proof of SQL Server 2016 compatibility.
