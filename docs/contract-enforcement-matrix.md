# Canonical input contract enforcement matrix

Status: planning and evidence-control matrix after PR #22. This document does not certify any upstream source, rate basis, approval evidence, or production deployment.

## Structural checks already implemented

| Contract assertion | Current implementation | Limitation |
|---|---|---|
| Required manifest families are registered and complete | `ecl_core.usp_ValidateRunInputs` | Does not certify the source-to-column mapping. |
| Manifest row counts match staged physical row counts | `ecl_core.usp_ReconcileInputSnapshots` | The source count must use the same physical-row definition, including inactive rows. |
| Staging rows use the run process date | Input reconciliation | Structural date check only. |
| Active accounts have annual PD, LGD, EAD and shared EIR coverage | Input validation | Coverage is not evidence of semantic correctness. |
| Scenario weight version is effective and has three weights summing to one | Input validation | Source and approval provenance are not yet stored/validated as a complete evidence contract. |
| EIR is greater than -1 | Input validation | Does not certify FTP 12-month numeric units or approved transformation. |
| Stage 3 calculation semantics | Not implemented as calculation | Upstream EAD/LGD suitability must be certified before calculation is enabled. |

## Required next validation and regression work

1. Add synthetic tests for each contract assertion, including effective-date boundaries, missing scenario rows, invalid weight totals, EIR values at and below -1, maturity/coverage boundaries, and rerun idempotence.
2. Define a versioned provenance schema for scenario weights: source/reference, approval/reference, approver, timestamp, change reason and immutable version history. Do not infer these fields from the numeric weights.
3. Define an explicit FTP rate contract: numeric unit, rate convention, any approved transformation, and Treasury evidence. Keep the selected formula `DF(t)=1/(1+EIR(t))^t` unchanged unless governance explicitly changes it.
4. Add a documented upstream certification gate for Stage 3 EAD/LGD timing and discount status.
5. Verify migrations and tests on SQL Server 2016. SQL Server 2017 CI is not proof of SQL Server 2016 compatibility.

## Out of scope

- ECL formulas, account/pool/portfolio ECL calculation, and publication.
- Source-system survey or production database access.
- Customer data or credentials.
- POCI-specific rules in the current canonical input contract (PR #22). Historical migrations/tests may still contain legacy POCI logic and require a separate cleanup decision before changing migration behavior.

## Release gate

A successful structural validation run must not be treated as approval to calculate or publish ECL. Calculation remains blocked until source mapping, FTP semantics, scenario-weight provenance/approval, Stage 3 suitability and SQL Server 2016 verification are closed and evidenced.
