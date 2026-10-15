# Canonical input contract enforcement matrix

Status: planning and technical-validation matrix after PR #25. This document does not certify any upstream source, FTP rate semantics, Stage 3 suitability, or production deployment.

## Structural checks already implemented

| Contract assertion | Current implementation | Limitation |
|---|---|---|
| Required manifest families are registered and complete | `ecl_core.usp_ValidateRunInputs` | Does not certify source-to-column mapping. |
| Manifest row counts match staged physical row counts | `ecl_core.usp_ReconcileInputSnapshots` | Source count must use the same physical-row definition, including inactive rows. |
| Staging rows use the run process date | Input reconciliation | Structural date check only. |
| Active accounts have annual PD, LGD, EAD and shared EIR coverage | Input validation | Coverage is not evidence of semantic correctness. |
| Scenario-weight version is effective and has three weights summing to one | Input validation | Uses supplied configuration; does not require approval metadata. |
| EIR is greater than -1 | Input validation | Does not certify FTP 12-month numeric units or transformation. |
| Stage 3 calculation semantics | Not implemented as calculation | EAD/LGD timing and discount status remain unresolved. |

## Required next validation and regression work

1. Add synthetic tests for contract assertions, including effective-date boundaries, missing scenario rows, invalid weight totals, EIR values at and below -1, maturity/coverage boundaries, and rerun idempotence.
2. Define the FTP input convention only when the intended numeric unit and any transformation are supplied. Keep `DF(t)=1/(1+EIR(t))^t` unchanged unless the user explicitly changes the formula; do not guess percentage-vs-decimal conversion.
3. Document the Stage 3 EAD/LGD timing and discounting assumptions before enabling Stage 3 calculation.
4. Verify migrations and tests on SQL Server 2016. SQL Server 2017 CI is not proof of 2016 compatibility.

## Out of scope

- ECL formulas, account/pool/portfolio ECL calculation, and publication.
- Source-system survey or production database access.
- Customer data or credentials.
- POCI-specific rules in the current canonical input contract (PR #22). Historical migrations/tests may still contain legacy POCI logic and require a separate cleanup decision before changing migration behavior.
- Approval workflow metadata as a precondition for using supplied scenario weights.

## Release gate

Structural validation does not certify source semantics or enable publication. Final calculation remains blocked until source mapping, FTP numeric convention, Stage 3 suitability and SQL Server 2016 verification are resolved. No approval workflow is required for scenario-weight data.
