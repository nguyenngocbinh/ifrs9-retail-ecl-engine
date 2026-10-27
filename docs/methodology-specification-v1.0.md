# IFRS 9 Retail ECL methodology specification

- Version: 1.1 (proposed annual time-weighted EAD convention)
- Status: Draft for methodology confirmation; not approved calculation policy
- Engine target: SQL Server 2016 / T-SQL
- Scope: Mortgage, Auto, Credit Card, Personal Loan, Other Retail; excluding POCI initially

## 1. Inputs and ownership

| Input | Owner / behavior | Status |
|---|---|---|
| Account, reporting date, product | Existing source | Physical source/key unconfirmed |
| Stage / SICR | Existing upstream process | Source contract unconfirmed |
| Pool assignment | Existing upstream process | Source contract unconfirmed |
| Annual PD, scenario-specific | Existing upstream process | Unconditional marginal PD on original cohort |
| LGD | Existing upstream process | Flat across scenarios by current assumption |
| EAD | Existing upstream schedule source | Proposed: annual time-weighted average exposure based on the balance path within each forecast year, not the balance at year-end; methodology-owner approval required |
| Scenario weights | Existing approved table | Need physical table/version |
| EIR | Existing source | One common rate curve across pools; one EIR value per forecast period |
| Standard error | Not used in calculation | Optional audit/control only |

Scenarios and current weights:
- Downturn: 15.68%
- Base: 68.64%
- Upturn: 15.68%

The engine must validate that selected active weights are present, non-negative, and sum to 100% within an approved tolerance. Production code must load approved weights from their authoritative table; it must not hardcode them as a permanent business rule.

## 2. Stage and horizon mapping

| Stage | Horizon | Output |
|---|---|---|
| Stage 1 | 12-month ECL (first 12-month horizon) | `ECL_12_MONTH` |
| Stage 2 | Lifetime ECL | `ECL_LIFETIME` |
| Stage 3 | One-period defaulted-exposure calculation (`FORECAST_PERIOD = 1`, PD=1) | `ECL_DEFAULT` |

- Exactly one Stage is expected per account and reporting date.
- Stage output categories are mutually exclusive for aggregation.
- Do not add `ECL_DEFAULT` into `ECL_LIFETIME` again as a separate amount.
- POCI is excluded from this first implementation scope; identification mechanism remains to be confirmed.
- The proposed time-weighted EAD convention primarily addresses performing Stage 1/Stage 2 forecast periods. Stage 3 period-1 exposure semantics must be confirmed separately; do not automatically substitute a forward-year average for reporting-date defaulted exposure without methodology approval.

## 3. Scenario aggregation

Scenario PDs are already calculated upstream for Downturn, Base, and Upturn. The engine combines scenario results using the approved scenario weights. It must not recalculate PD from `PD FWL ± 1 SE`.

LGD and EAD are assumed equal across the three scenarios for this first specification. This does not mean that EAD/LGD input records should be copied blindly: their curve grains, period alignment, and meanings must be validated.

## 4. EAD convention — proposed annual time-weighted average

### 4.1 Forecast-period boundaries

Let:
- (D_0) be the reporting/process date.
- (D_n = DATEADD(year,n,D_0)) be the end boundary of annual forecast period (n).
- Forecast period (n) cover the half-open date interval ([D_{n-1},D_n)).

For each forecast period, calculate EAD as a day-weighted average of the exposure balance effective during that period. Do not select only the last schedule row on or before the period-end date.

```text
EAD_average(n) = SUM_i(EAD_i * Days_i) / Days_in_period(n)
```

Where:
- `EAD_i` is the balance effective during interval `i`, as derived from the reporting-date balance and contractual principal repayment schedule.
- `Days_i` is the number of calendar days that interval overlaps forecast period `n`.
- `Days_in_period(n) = D_n - D_(n-1)`.
- Intervals use a consistent half-open convention: the balance after a scheduled principal payment is effective from its schedule due date up to, but not including, the next schedule due date. This avoids double-counting a date.
- EAD must not become negative. Source rows, duplicate schedule events, missing schedule data, and any fallback to reporting-date balance must follow explicit validation rules rather than silently creating an incorrect balance path.

This convention is a time-weighted average exposure proxy for annual marginal PD, not an exact probability-weighted EAD-at-default. It implicitly assumes default timing is uniform within the annual period. If an approved default-timing distribution becomes available, replace calendar-day weights with approved default-probability weights and document that model change.

### 4.2 Treatment of maturity and zero balances

If the loan is fully repaid during a forecast year, the balance is zero from the effective repayment date through the rest of that year. The annual average therefore remains positive when the loan was outstanding for part of the year, and decreases to zero for full forecast years after repayment.

If an account has a positive reporting-date balance but no future contractual principal schedule, do not assume it is repaid or carry its balance forward indefinitely without an approved fallback rule. Preserve the balance source and raise/record the unresolved schedule condition according to the approved source-data policy.

The schedule-based balance path described here uses contractual principal repayments. Prepayment adjustments, interest components, progressive drawdown, bullet-loan treatment, and product-specific EAD formulas must follow the bank-approved EAD methodology; they are not inferred by this averaging formula alone.

### 4.3 Annual ECL contribution

At a conceptual annual contribution level:

```text
ECL_contribution(t, s) = PD_marginal(t, s)
                         * LGD(t)
                         * EAD_average(t)
                         * DiscountFactor(t)
```

`PD_marginal(t,s)` is intended to represent the appropriate marginal default probability for annual period `t`, using the original-cohort denominator. Check the source definition to ensure marginal PD is not converted to or multiplied into cumulative PD incorrectly.

For Stage 1, contributions are restricted to the approved 12-month horizon. For Stage 2, contributions cover the approved remaining lifetime horizon. Stage 3 remains a separate one-period defaulted-exposure calculation (`FORECAST_PERIOD = 1`, PD=1); its period-1 EAD basis and discounting must be explicitly confirmed before applying the time-weighted convention to Stage 3.

Scenario-weighted ECL is conceptually:

```text
ECL = SUM_s(ScenarioWeight(s) * SUM_t(ECL_contribution(t, s)))
```

Stage-specific formulas are a contract for implementation only after the discounting, EAD curve semantics, and source data blockers below are resolved.

## 5. Discounting — blocking verification item

The currently recorded user choice is:

```text
DF(t) = 1 / (1 + EIR(t)) ^ t
```

where EIR(t) is the existing source's rate for forecast period t, and t is the annual forecast index.

**Do not treat this as final approved policy yet.** If EIR varies by period, applying each period's rate raised to t is generally not equivalent to cumulative discounting using a term structure. Confirm the approved accounting convention and source rate semantics before implementation. Do not silently replace this formula with a cumulative product or a constant-rate formula.

Using a time-weighted average EAD does not by itself determine the discounting time. Confirm whether the approved discount convention remains the annual period index (t), or requires an exposure/default timing adjustment. Do not change the discount factor silently.

## 6. Stage 3

Selected v1 implementation convention: Stage 3 always uses PD=1 but calculates ECL only for `FORECAST_PERIOD = 1`, regardless of whether contractual maturity has passed. Use period-1 EAD/LGD/EIR and discount with exponent 1.0; create one row for each scenario and do not calculate periods 2+. This is an implementation choice to avoid repeated PD=1 contributions across future periods, not by itself formal approval of the bank's accounting methodology. Confirm whether period-1 EAD should represent reporting-date defaulted exposure or another approved exposure basis. Do not assume the performing-account annual time-weighted average is appropriate for Stage 3.

## 7. Input validation policy

- Invalid PD input: reject the run; do not silently cap/floor.
- Validate unique account/reporting-date key and one Stage per account/reporting date.
- Validate that required forecast periods exist and align across PD, LGD, EAD, and EIR.
- Validate PD domain according to the approved source contract; do not assume a conversion where source semantics are unresolved.
- Scenario weights must be validated and the source version recorded.
- Validate LGD/EAD ranges only after approved domains, scaling, and exceptional cases are documented.
- For time-weighted EAD, validate non-negative balances, ordered schedule dates, one effective balance per interval, complete period coverage, and no duplicate account/period EAD outputs.
- No partial output publication on validation or calculation failure.

## 8. Operational requirements

- Unique run ID and reproducible input version references.
- Full-portfolio and selective product/pool run modes.
- Safe rerun behavior and publication idempotency.
- Counts and amounts reconciled between account results and pool/product/portfolio aggregates.
- Audit records include input versions, calculation version, parameters, start/end time, status, and exception information.
- Synthetic test fixtures only; no customer data in public repository.

## 9. Items required before executable calculation SQL

See `docs/open-questions.md`. Most important blockers:
1. Approval of annual time-weighted EAD as the EAD-at-default proxy, including the uniform-within-year default timing assumption and treatment of prepayment/product-specific formulas.
2. Stage 3 period-1 EAD semantics and loss allocation.
3. Approved discount factor definition when EIR varies by period and whether timing adjustment is needed.
4. Actual source schemas, keys, grains, and versioning strategy.
5. Authoritative scenario-weight table and EIR source definition.
6. Lifetime horizon, missing-curve-period treatment, and POCI identification/exclusion.
