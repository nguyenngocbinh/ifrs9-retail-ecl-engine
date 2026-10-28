/*
Smoke test for migration 011 outcome-loader metadata.
Run only after migrations 001..011 on a disposable DEV/UAT database.
This test is metadata-only and writes no business data.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'ecl_bt.usp_Load12MonthAccountOutcomes', N'P') IS NULL
    THROW 51960, 'Missing ecl_bt.usp_Load12MonthAccountOutcomes; deploy migration 011 first.', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'ecl_bt.AccountOutcome')
      AND name = N'CK_BT_Outcome_Status'
      AND definition LIKE '%ALREADY_DEFAULTED%'
)
    THROW 51961, 'AccountOutcome status constraint is missing ALREADY_DEFAULTED.', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'ecl_bt.AccountOutcome')
      AND name = N'CK_BT_Outcome_DefaultConsistency'
)
    THROW 51962, 'AccountOutcome default-date consistency constraint is missing.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'ecl_bt.usp_Load12MonthAccountOutcomes')) LIKE '%first_to_default%'
    THROW 51963, 'Outcome loader must not depend on first_to_default from the customer-level source.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'ecl_bt.usp_Load12MonthAccountOutcomes')) NOT LIKE '%OUTCOME_SOURCE_SNAPSHOT_EMPTY%'
    THROW 51964, 'Outcome loader must warn when the entire source snapshot is missing.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'ecl_bt.usp_Load12MonthAccountOutcomes')) NOT LIKE '%OUTCOME_LABEL_INVALID%'
    THROW 51965, 'Outcome loader must warn for invalid/missing labels.', 1;

PRINT 'PASS: outcome loader metadata and missing-source warning checks passed.';
