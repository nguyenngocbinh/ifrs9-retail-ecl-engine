# Source inventory kit

Status: prepared for metadata collection. No production source mapping is asserted by this kit.

## Purpose

Collect enough source metadata to define a physical data dictionary, join map, source grain, and versioning rules before writing ECL calculation SQL.

## Safety

- Run queries using a read-only account with catalog metadata access.
- The SQL Server script reads system catalog metadata only; it does not select customer/account records.
- Do not export or commit customer-level data, credentials, connection strings, or sensitive query results.
- Review metadata before committing it because schema/object/column names can themselves be sensitive in some environments.
- Run only against approved environments and follow your bank's data handling rules.

## Collection steps

1. List candidate source objects for account/reporting date, Stage/SICR, pool, scenario PD, LGD, EAD, scenario weights, EIR, and POCI exclusion.
2. Run the SQL Server catalog script for each relevant database/schema where you have permission.
3. If an upstream source is DB2 or another platform, collect equivalent catalog metadata using that platform's approved read-only queries; do not run the SQL Server script there.
4. Complete the data dictionary and lineage templates with verified evidence.
5. Profile uniqueness and source grain using approved, privacy-safe aggregates in the source environment. Do not export row-level account data to this repository.
6. Link each mapping to a source owner, definition, and methodology evidence.
7. Keep unresolved mappings explicitly marked UNKNOWN rather than guessing.

## Files

- sqlserver_catalog_inventory.sql: SQL Server catalog metadata only.
- source-data-dictionary-template.md: object/column and grain register.
- lineage-map-template.md: source-to-logical-input relationship register.
- ../open-questions.md: methodology and mapping blockers.

## Minimum evidence for each logical input

- Physical object and column names.
- Source system/database/schema and owner.
- Business key and unique grain.
- Reporting date/effective-date behavior.
- Forecast period and scenario keys, if applicable.
- Units, scaling, currency, null behavior, and valid domain.
- Data dictionary or approved methodology reference.
- Profile/uniqueness check performed and result summary without customer data.

## Not in scope

This kit does not resolve methodology questions about EAD/LGD period semantics, Stage 3 allocation, or EIR discounting. It does not create calculation tables or execute ECL calculations.