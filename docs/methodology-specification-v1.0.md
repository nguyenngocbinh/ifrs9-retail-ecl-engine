# IFRS 9 Retail ECL methodology specification

- Version: 1.0 (initial assumptions register)
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
| EAD | Existing upstream process | Annual, year-end convention, EAD at default; exact semantics to verify |
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
| Stage 3 | Default/lifetime calculation with PD=1 | `ECL_DEFAULT` |

- Exactly one Stage is expected per account and reporting date.
- Stage output categories are mutually exclusive for aggregation.
- Do not add `ECL_DEFAULT` into `ECL_LIFETIME` again as a separate amount.
- POCI is excluded from this first implementation scope; identification mechanism remains to be confirmed.

## 3. Scenario aggregation

Scenario PDs are already calculated upstream for Downturn, Base, and Upturn. The engine combines scenario results using the approved scenario weights. It must not recalculate PD from `PD FWL ± 1 SE`.

LGD and EAD are assumed equal across the three scenarios for this first specification. This does not mean that EAD/LGD input records should be copied blindly: their curve grains, period alignment, and meanings must be validated.

## 4. ECL calculation contract

At a conceptual annual contribution level:

```text
ECL_contribution(t, s) = PD_contribution(t, s)
                         × LGD(t)
                         × EAD_at_default(t)
                         × DiscountFactor(t)
```

`PD_contribution(t,s)` is intended to represent the appropriate marginal default probability for annual period `t`, conditional on the original cohort being the denominator. The precise source definition must be checked to ensure the supplied marginal PD is not converted or multiplied into a cumulative PD incorrectly.

For Stage 1, contributions are restricted to the approved 12-month horizon. For Stage 2, contributions cover the approved remaining lifetime horizon. Stage 3 uses PD=1 per the currently selected rule, subject to validation of curve semantics and the approved method for allocating default exposure across periods.

Scenario-weighted ECL is conceptually:

```text
ECL = sum_s(ScenarioWeight(s) × sum_t(ECL_contribution(t,s)))
```

Stage-specific formulas are a contract for implementation only after the discounting and curve-semantics blockers below are resolved.

## 5. Discounting — blocking verification item

The currently recorded user choice is:

```text
DF(t) = 1 / (1 + EIR(t)) ^ t
```

where EIR(t) is the existing source's rate for forecast period t, and t is the annual forecast index.

**Do not treat this as final approved policy yet.** If EIR varies by period, applying each period's rate raised to t is generally not equivalent to cumulative discounting using a term structure. Confirm the approved accounting convention and source rate semantics before implementation. Do not silently replace this formula with a cumulative product or a constant-rate formula.

## 6. Stage 3

Current selected rule: always use PD=1 for Stage 3 and validate LGD/EAD input curves. The implementation must not mechanically apply a full series of PD=1 contributions across all future periods without confirming whether it duplicates the same default exposure. The actual Stage 3 calculation contract depends on OQ-001 and OQ-008 in `docs/open-questions.md`.

## 7. Input validation policy

- Invalid PD input: reject the run; do not silently cap/floor.
- Validate unique account/reporting-date key and one Stage per account/reporting date.
- Validate that required forecast periods exist and align across PD, LGD, EAD, and EIR.
- Validate PD domain according to the approved source contract; do not assume a conversion where source semantics are unresolved.
- Validate scenario weights and the source version used.
- Validate LGD/EAD ranges only after approved domains, scaling, and exceptional cases are documented.
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
1. Annual EAD/LGD curve semantics and Stage 3 loss allocation.
2. Approved discount factor definition where EIR varies by period.
3. Actual source schemas, keys, grains, and versioning strategy.
4. Authoritative scenario-weight table and EIR source definition.
5. Lifetime horizon and POCI identification/exclusion.