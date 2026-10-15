# Source lineage map — template

## Logical flow

Approved source object -> validated source extract/snapshot -> normalized input contract -> ECL run input -> calculation detail -> account result -> pool/product/portfolio aggregation -> reconciliation -> publication.

This is a conceptual flow, not a claim that the physical pipeline already exists.

## Mapping register

| Logical input | Physical object/column | Join key | Expected grain | Cardinality | Transformations | Version/effective date | Evidence | Status |
|---|---|---|---|---|---|---|---|---|
| Account/reporting date | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| Stage/SICR | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| Pool assignment | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| Scenario PD | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| LGD | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| EAD | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| Scenario weights | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |
| EIR | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | None confirmed | UNKNOWN | UNKNOWN | Open |

## Required checks

- Verify the grain of each source before joining.
- Verify uniqueness on the intended join keys.
- Check for one-to-many joins that would multiply PD/LGD/EAD contributions.
- Record the expected and observed row-count relationship for each join.
- Identify filters, effective-date selection, and late-arriving/restated data rules.
- Document whether source records are account-level, facility-level, pool-level, or portfolio-level.
- Never include actual customer IDs or row-level source records in this file.
