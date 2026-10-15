# Upstream source-to-canonical mapping register

Status: **partially specified — upstream source objects and source columns have not been supplied or inspected**. This document maps the agreed logical input families to the engine's canonical staging/configuration columns. It deliberately does not invent upstream table or column names.

This is a mapping specification, not a claim that source-to-column mapping is complete. Fill the upstream columns and evidence references only from approved source DDL, data dictionary, interface specification, or source-owner confirmation. No production data survey is required for this document.

## 1. Family-level mapping

| Logical family | Canonical target | Canonical grain | Upstream source object | Mapping status |
|---|---|---|---|---|
| ACCOUNT | `ecl_stg.AccountSnapshot` | `RUN_ID + ACCOUNT_ID` | TBD | Canonical target defined; source unresolved |
| PD | `ecl_stg.PDCurve` | `RUN_ID + ACCOUNT_ID + SCENARIO_CODE + FORECAST_PERIOD` | TBD | Canonical target defined; source unresolved |
| LGD | `ecl_stg.LGDCurve` | `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD` | TBD | Canonical target defined; source unresolved |
| EAD | `ecl_stg.EADCurve` | `RUN_ID + ACCOUNT_ID + FORECAST_PERIOD` | TBD | Canonical target defined; source unresolved |
| EIR | `ecl_stg.EIRCurve` | `RUN_ID + FORECAST_PERIOD` | TBD | Canonical target defined; source unresolved |
| SCENARIO_WEIGHT | `ecl_cfg.ScenarioWeight` + `ecl_cfg.ScenarioWeightVersion` | `VERSION_ID + SCENARIO_CODE` | TBD | Configuration target defined; upstream/config owner source unresolved |

## 2. Column-level canonical mapping

```text
ACCOUNT
  Engine-generated: RUN_ID
  Load/run contract: PROCESS_DATE
  Required source mapping: ACCOUNT_ID, PRODUCT_TYPE, STAGE, POOL_ID, MATURITY_DATE
  Optional source mapping: CUSTOMER_ID, source version/reference, active flag
  Target: ecl_stg.AccountSnapshot

PD
  Engine-generated: RUN_ID
  Load/run contract: PROCESS_DATE
  Source mapping: ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD, MARGINAL_PD, VERSION_ID
  Target: ecl_stg.PDCurve

LGD
  Engine-generated: RUN_ID
  Load/run contract: PROCESS_DATE
  Source mapping: ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID
  Target: ecl_stg.LGDCurve

EAD
  Engine-generated: RUN_ID
  Load/run contract: PROCESS_DATE
  Source mapping: ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID
  Target: ecl_stg.EADCurve

EIR
  Engine-generated: RUN_ID
  Load/run contract: PROCESS_DATE
  Source mapping: FORECAST_PERIOD, EIR, VERSION_ID
  RATE_BASIS target: FTP_12M (semantic label, not a numeric conversion)
  Target: ecl_stg.EIRCurve

SCENARIO_WEIGHT
  Source/config mapping: VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT,
                         PROCESS_DATE, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE
  Targets: ecl_cfg.ScenarioWeightVersion, ecl_cfg.ScenarioWeight
  Required scenarios: DOWNTURN, BASE, UPTURN
  Required weights: 0.1568, 0.6864, 0.1568
```

The actual upstream column names, expressions, joins, filters and type conversions remain TBD until source definitions are provided. `RUN_ID` is assigned by the run/load process; it is not presumed to exist in an upstream model table.

## 3. Mapping rules already fixed by the contract

- PD is an upstream-supplied unconditional marginal annual PD by account, scenario and forecast period. Do not derive it from PD FWL ± 1 SE.
- LGD is an upstream-supplied ratio by account and period; v1 uses the same curve across scenarios.
- EAD is an upstream-supplied VND amount by account and annual forecast period.
- EIR is the shared FTP 12-month input by forecast period. Its numeric value has no unit and is consumed as supplied; do not multiply/divide by 100 or apply another implicit conversion.
- Stage 3 follows Stage 2 calculation logic, with only PD set to 1.
- Scenario weights are read from the selected versioned configuration and must be effective for `PROCESS_DATE`, contain all three scenarios and sum to 1.
- Forecast periods begin at 1. Maturity/curve coverage must follow the canonical contract.
- Do not load or use customer-level values in this repository's tests; use synthetic fixtures only.

## 4. Required evidence for each source mapping

For every family, record:

| Evidence field | Required content |
|---|---|
| Source system and object | Exact database/schema/table, view, file interface, or API contract name |
| Source columns | Exact source column names for every required canonical field |
| Key/grain | Evidence that the source grain matches the canonical key or a documented deduplication rule |
| Join path | Join keys and cardinality when multiple source objects are needed |
| Filters | As-of date, active/current-row logic, product scope and exclusion rules |
| Transformation | Explicit casts, code mapping, date/period derivation, rounding and null/default behavior |
| Units/semantics | PD/LGD definitions, EAD currency, EIR convention and any source-applied discounting |
| Version/effective date | Source version, process date, effective-date selection and reproducibility |
| Evidence/owner | Link/path to approved DDL or data dictionary and accountable source owner |
| Status | `UNMAPPED`, `DRAFT`, `CONFIRMED`, or `BLOCKED`; only evidence-backed `CONFIRMED` closes the mapping gate |

## 5. Outstanding inputs needed to finish mapping

Provide an approved source DDL/data dictionary or interface specification for the six families above, plus code/domain mappings for product, Stage, pool and scenario. Source object names and column names cannot be recovered from the engine's logical schema alone.

Until those source definitions are available, keep source-to-column mapping open and do not implement final ECL calculation formulas.