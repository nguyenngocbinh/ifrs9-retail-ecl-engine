# Source data dictionary — template

Copy one section per physical object. Use verified source metadata; do not infer missing details.

## Object register

| Logical input | Source system | Database/catalog | Schema | Object | Owner | Evidence/reference | Status |
|---|---|---|---|---|---|---|---|
| Account/reporting date | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| Stage/SICR | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| Pool assignment | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| Scenario PD | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| LGD curve | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| EAD curve | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| Scenario weights | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| EIR curve | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |
| POCI identification/exclusion | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Open |

## Column register

| Source object | Column | Data type | Nullable | Key role | Meaning | Unit/scale | Domain | Evidence |
|---|---|---|---|---|---|---|---|---|
| UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |

## Grain and key register

For each object, document:

- Expected row grain, stated in business terms.
- Candidate natural/business key and physical unique key.
- Reporting-date and effective-date behavior.
- Forecast-period convention and period end.
- Scenario dimension, if applicable.
- Product/pool/account/facility join keys.
- Expected cardinality when joined to each related source.
- How duplicates, missing periods, late-arriving records, and restatements are handled.
- Source snapshot/version or extraction timestamp.
- Profile query, execution date, and summarized result (counts only; no customer-level extracts).

## Domain and interpretation register

| Field | Meaning | Allowed range/values | Null behavior | Scaling | Currency | Approved reference |
|---|---|---|---|---|---|---|
| PD | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | N/A | UNKNOWN |
| LGD | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |
| EAD at default | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |
| EIR | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | N/A | UNKNOWN |
| Scenario weight | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | N/A | UNKNOWN |

## Sign-off

- Source owner:
- Methodology owner:
- Data engineering reviewer:
- Evidence/document links:
- Open issues:
- Date/status:
