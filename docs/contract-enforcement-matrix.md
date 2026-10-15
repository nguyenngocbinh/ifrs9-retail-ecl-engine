# Canonical input contract enforcement matrix

Status: planning and technical-validation matrix after PR #26. This document does not certify any upstream source mapping, Stage 3 EAD/LGD source semantics, or production deployment.

## Structural checks already implemented

| Contract assertion | Current implementation | Limitation |
|---|---|---|
| Required manifest families are registered and complete | `ecl_core.usp_ValidateRunInputs` | Does not certify source-to-column mapping. |
| Manifest row counts match staged physical row counts | `ecl_core.usp_ReconcileInputSnapshots` | Source count must use the same physical-row definition, including inactive rows. |
| Staging rows use the run process date | Input reconciliation | Structural date check only. |
| Active accounts have annual PD, LGD, EAD and shared EIR coverage | Input validation | Coverage is not evidence of semantic correctness. |
| Scenario-weight version is effective and has three weights summing to one | Input validation | Uses supplied configuration; does not require approval metadata. |
| EIR is greater than -1 | Input validation | EIR is dimensionless and consumed as supplied; no percentage/decimal conversion is applied. |
| Stage 3 discount convention | Methodology decision documented | Stage 3 uses the same shared EIR curve and `DF(t)=1/(1+EIR(t))^t` as Stage 2. Upstream EAD/LGD timing and pre-discounting still need confirmation. |

## Required next validation and regression work

1. Expand synthetic tests for contract assertions, including effective-date boundaries, missing scenario rows, invalid weight totals, EIR values at and below -1, maturity/coverage boundaries, and rerun idempotence.
2. Use the supplied dimensionless EIR value as-is with `DF(t)=1/(1+EIR(t))^t`; do not infer or apply percentage/decimal conversion.
3. Confirm upstream Stage 3 EAD/LGD timing and discount status before enabling Stage 3 calculation.
4. Verify migrations and tests on SQL Server 2016. SQL Server 2017 CI is not proof of 2016 compatibility.

## Out of scope

- ECL formulas, account/pool/portfolio ECL calculation, and publication.
- Source-system survey or production database access.
- Customer data or credentials.
- POCI-specific rules in the current canonical input contract (PR #22). Historical migrations/tests may still contain legacy POCI logic and require a separate cleanup decision before changing migration behavior.
- Approval workflow metadata as a precondition for using supplied scenario weights.

## Release gate

Structural validation does not certify source semantics or enable publication. Final calculation remains blocked until source mapping, Stage 3 EAD/LGD source semantics and SQL Server 2016 verification are resolved. The EIR numeric convention and Stage 3 discount-rate convention are resolved as documented. No approval workflow is required for scenario-weight data.
