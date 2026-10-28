/*
Metadata-only smoke tests for migration 012.
Run after migrations 001..012 on a disposable DEV/UAT database.
Does not read or modify business account rows.
*/
SET NOCOUNT ON;

IF COL_LENGTH(N'ecl_bt.AccountOutcome', N'ACTUAL_LOSS_PROXY') IS NULL
    THROW 51970, 'Missing AccountOutcome.ACTUAL_LOSS_PROXY; deploy migration 012.', 1;
IF COL_LENGTH(N'ecl_bt.AccountOutcome', N'ACTUAL_LOSS_STATUS') IS NULL
    THROW 51971, 'Missing AccountOutcome.ACTUAL_LOSS_STATUS; deploy migration 012.', 1;
IF OBJECT_ID(N'ecl_bt.usp_Load12MonthActualLossProxy', N'P') IS NULL
    THROW 51972, 'Missing actual-loss proxy loader.', 1;
IF OBJECT_ID(N'ecl_bt.usp_Report12MonthActualLossBacktest', N'P') IS NULL
    THROW 51973, 'Missing actual-loss backtest report procedure.', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'ecl_bt.AccountOutcome')
      AND name = N'CK_BT_Outcome_ActualLoss'
)
    THROW 51974, 'Missing actual-loss proxy validation constraint.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'ecl_bt.usp_Load12MonthActualLossProxy')) NOT LIKE '%os_amount%'
    THROW 51975, 'Actual-loss loader must use os_amount.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'ecl_bt.usp_Load12MonthActualLossProxy')) NOT LIKE '%current_gb%'
    THROW 51976, 'Actual-loss loader must identify the first current_gb=1 month-end.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'ecl_bt.usp_Report12MonthActualLossBacktest')) NOT LIKE '%FORECAST_ECL_12_MONTH%'
    THROW 51977, 'Actual-loss report must compare against 12-month ECL forecast.', 1;

PRINT 'PASS: actual-loss proxy columns, loader, report, and required source fields exist.';
