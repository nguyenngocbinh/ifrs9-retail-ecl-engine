# Canonical input contract — v1

Status: contract baseline for review. This document defines the logical interface; it does not claim that upstream source mappings or source-system evidence have been certified.

## 1. Run-wide invariants

Every staged row belongs to exactly one `RUN_ID` and has the same `PROCESS_DATE` as `ecl_core.RunControl`. The run binds an explicit `SCENARIO_WEIGHT_VERSION_ID`; a rerun creates a new `RUN_ID`. Input family versions and row counts are recorded in `RunInputManifestItem`.

Input reconciliation currently compares manifest counts with physical staging counts, including inactive rows. Therefore `SNAPSHOT_ROW_COUNT` must mean the number of rows physically staged for that run and family, including inactive rows. If the source count is defined differently, ingestion must transform or separately record the source count rather than treating a mismatched count as reconciled.

## 2. Logical input families

| Family | Logical grain / key | Required semantics |
|---|---|---|
| ACCOUNT | `RUN_ID + ACCOUNT_ID` | One account snapshot; `PROCESS_DATE`, product, Stage, pool, maturity, source version and active flag. |
| PD | `RUN_ID + ACCOUNT_ID + SCENARIO_CODE + FORECAST_PERIOD` | Scenario-specific unconditional marginal annual PD for the original cohort; periods are full annual periods. Values are supplied upstream; do not derive PD from PD FWL ± 1 SE. |
| LGD | `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD` | Undiscounted loss-given-default ratio for each full annual period. Flat across scenarios in v1. |
| EAD | `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD` | Exposure at expected default under the agreed year-end annual-period convention; VND in v1. No partial-year prorating. |
| EIR | `RUN_ID + FORECAST_PERIOD` | One shared FTP selling-funds rate for 12 months for each forecast period; same rate curve is applied across accounts/pools. |
| SCENARIO_WEIGHT | `VERSION_ID + SCENARIO_CODE` | Exactly Downturn 0.1568, Base 0.6864, Upturn 0.1568 for the approved version; sum is 1. Version history and provenance must be retained. |

All curve rows must be compatible with the run's reporting date and input version. Forecast periods start at 1. Curves must cover the full annual periods needed through each account's contractual maturity.

## 3. FTP 12-month EIR and discount-time convention

The user-selected EIR input is FTP selling funds for 12 months. The engine does not estimate EIR or build a term structure. Keep `RATE_BASIS='FTP_12M'` as the source semantic identifier; do not silently relabel it as annual-effective or nominal without an explicit treasury definition.

The agreed discount formula remains:

`DF(t) = 1 / (1 + EIR(t)) ^ t`

For a maturity horizon of 3 years and 6 months, PD and EAD still use the supplied annual-period values; only the discount-time exponent is `t = 3.5`. The applicable shared FTP 12-month rate is selected from the configured forecast-period mapping. This is the agreed simplified v1 convention, not a claim that FTP 12-month is economically equivalent to an effective annual EIR. Treasury/model governance should confirm the rate's numeric unit and transformation (if any) before production calculation is enabled.

## 4. Stage contract

- Stage 1 output category: `ECL_12_MONTH`.
- Stage 2 output category: `ECL_LIFETIME`.
- Stage 3 output category: `ECL_DEFAULT`; use PD = 1 and the same annual EAD/LGD curves as Stage 2, then discount annual losses and aggregate.
- Stage 3 compatibility is a source-contract assertion, not inferable from column types alone. Upstream owners must certify that EAD timing and LGD are suitable for the Stage 3 convention and are not already discounted.

## 5. Scenario-weight provenance and immutability

Each scenario-weight version must preserve:
- `VERSION_ID`, version name, effective dates and process date;
- exact weights for Downturn/Base/Upturn;
- source system and source/reference identifier;
- approval/reference identifier, approver and approval timestamp where applicable;
- change reason and creation audit metadata.

Never update a historical version in place to reflect a changed decision. Create a new `VERSION_ID` with new effective dates and provenance. Every run retains the exact selected version. The numeric weights are user-confirmed; official source/approval evidence must be populated by the responsible owner before production use.

## 6. Required pre-calculation assertions

1. All six manifest families are complete and reconcile to the physical staged row counts.
2. All staged rows match the run's `PROCESS_DATE`; account keys and curve grains are unique.
3. Active accounts have required curve coverage through maturity.
4. PD values are in [0,1]; LGD values are in [0,1]; EAD is non-negative and denominated in VND.
5. One shared EIR value exists per required full forecast period, its value is greater than -1 under the selected formula, and its numeric units/rate convention are certified.
6. The selected scenario-weight version is effective on `PROCESS_DATE`, contains all three scenarios, sums to 1 within the configured tolerance, and has source/approval provenance.
7. Stage 3 EAD/LGD semantics are certified upstream before Stage 3 calculation is enabled.
8. No ECL formula or publication is enabled merely because structural checks pass.

## 7. Explicitly unresolved production evidence

- Upstream source-to-column mapping and source owner certification.
- Treasury confirmation of FTP 12-month numeric unit and how that value is to be used with the agreed exponent formula.
- Source/approval evidence for scenario weights.
- Written confirmation that upstream Stage 3 EAD/LGD curves satisfy the agreed semantics.
- Deployment and compatibility verification on SQL Server 2016. Current CI uses SQL Server 2017 and is not proof of 2016 compatibility.
