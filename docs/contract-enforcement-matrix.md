# Canonical input contract enforcement matrix

Status: technical-validation matrix for the agreed canonical input interface. It does not certify production data or upstream source mappings, which are outside the current phase.

## Structural checks already implemented

| Contract assertion | Current implementation | Limitation |
|---|---|---|
| Required manifest families are registered and complete | `ecl_core.usp_ValidateRunInputs` | Checks the canonical interface, not upstream mapping. |
| Manifest row counts match staged physical row counts | `ecl_core.usp_ReconcileInputSnapshots` | Source count must use the same physical-row definition, including inactive rows. |
| Staging rows use the run process date | Input reconciliation and PR #36 data-quality gates | PR #36 tests ACCOUNT wrong-date handling; wrong-date tests for all other curve/config families remain a regression-coverage gap. |
| Active accounts have annual PD, LGD, EAD and shared EIR coverage | Input validation | Coverage is not evidence of source-system mapping. |
| Scenario-weight version is effective and has three weights summing to one | Input validation | Uses supplied configuration; does not require approval metadata. |
| EIR is greater than -1 | Input validation | EIR is dimensionless and consumed as supplied; no percentage/decimal conversion is applied. |
| Logical grain uniqueness | Canonical table keys plus validation/tests | Duplicate-grain regression exists for ACCOUNT and PD; extend it to LGD/EAD/EIR. |
| Stage 3 discount convention | Methodology decision documented | Stage 3 follows Stage 2 logic, with PD=1 as the only difference; same EAD/LGD curves and shared EIR discount convention. |

## Remaining validation and regression work

1. Add synthetic wrong-reporting-date tests for PD, LGD, EAD, EIR and SCENARIO_WEIGHT rows.
2. Add duplicate logical-grain tests for LGD, EAD and EIR. ACCOUNT/PD duplicate-grain coverage already exists.
3. Run the full SQL Server 2022 integration suite after these tests are wired into CI.
4. After a calculation procedure exists, test result-level calculation rerun idempotency.
5. After a publication procedure exists, test transactional atomicity and rollback of partial output writes.

The supplied dimensionless EIR value is consumed as-is with `DF(t)=1/(1+EIR(t))^t`; do not infer or apply percentage/decimal conversion.

## Out of scope

- ECL formulas, account/pool/portfolio ECL calculation, and publication until the pre-calculation safety gates are reviewed and green.
- Source-system survey, production database access, and upstream source-to-column mapping.
- Customer data or credentials.
- SQL Server 2016 compatibility verification; SQL Server 2022 is the CI target for this phase.
- POCI-specific rules in the current canonical input contract. Historical migrations/tests may still contain legacy POCI logic and require a separate cleanup decision before changing historical behavior.
- Approval workflow metadata as a precondition for using supplied scenario weights.

## Release gate

Do not enable final calculation formulas until the synthetic pre-calculation safety, publication lifecycle, and selective-run scope regression gates are green and reviewed. This does not require source mapping or SQL Server 2016 verification. Result-level rerun idempotency and true output-write atomicity remain deferred until the corresponding procedures exist. No approval workflow is required for scenario-weight data.
