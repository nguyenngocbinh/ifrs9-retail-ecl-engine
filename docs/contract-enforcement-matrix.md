# Canonical input contract enforcement matrix

Status: technical-validation matrix for the agreed canonical input interface. It does not certify production data or upstream source mappings, which are outside the current phase.

## Structural checks already implemented

| Contract assertion | Current implementation | Limitation |
|---|---|---|
| Required manifest families are registered and complete | `ecl_core.usp_ValidateRunInputs` | Checks the canonical interface, not upstream mapping. |
| Manifest row counts match staged physical row counts | `ecl_core.usp_ReconcileInputSnapshots` | Source count must use the same physical-row definition, including inactive rows. |
| Staging rows use the run process date | Input reconciliation and PR #36 data-quality gates | PR #36 covers ACCOUNT; PR #38 covers PD/LGD/EAD/EIR/SCENARIO_WEIGHT wrong-date rejection. |
| Active accounts have annual PD, LGD, EAD and shared EIR coverage | Input validation | Coverage is not evidence of source-system mapping. |
| Scenario-weight version is effective and has three weights summing to one | Input validation | Uses supplied configuration; does not require approval metadata. |
| EIR is greater than -1 | Input validation | EIR is dimensionless and consumed as supplied; no percentage/decimal conversion is applied. |
| Logical grain uniqueness | Canonical table keys plus validation/tests | Duplicate-grain regression covers ACCOUNT/PD/LGD/EAD/EIR (PR #38). |
| Stage 3 discount convention | Methodology decision documented | Stage 3 follows Stage 2 logic, with PD=1 as the only difference; same EAD/LGD curves and shared EIR discount convention. |

## Remaining validation and regression work

1. PR #38 completed wrong-reporting-date and duplicate-grain coverage for the remaining input families.
2. PR #39 adds calculation formulas, rerun rejection, and transactional account/detail/summary writes.
3. Remaining: run full SQL Server 2022 CI and add fault-injection rollback coverage for a forced mid-write failure.

The supplied dimensionless EIR value is consumed as-is with `DF(t)=1/(1+EIR(t))^t`; do not infer or apply percentage/decimal conversion.

## Out of scope

- Upstream source mapping and model construction; the engine consumes canonical input curves.
- Source-system survey, production database access, and upstream source-to-column mapping.
- Customer data or credentials.
- SQL Server 2016 compatibility verification; SQL Server 2022 is the CI target for this phase.
- POCI-specific rules in the current canonical input contract. Historical migrations/tests may still contain legacy POCI logic and require a separate cleanup decision before changing historical behavior.
- Approval workflow metadata as a precondition for using supplied scenario weights.

## Release gate

Calculation formulas are implemented in PR #39 and must not be merged until SQL Server 2022 CI passes and expected-value outputs are reviewed. Transactional writes are implemented; explicit forced-failure rollback regression remains open. No source mapping or SQL Server 2016 verification is required. No approval workflow is required for scenario-weight data.
