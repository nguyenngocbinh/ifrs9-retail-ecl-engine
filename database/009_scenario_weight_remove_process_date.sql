/*
IFRS 9 Retail ECL Engine — migration 009
Remove PROCESS_DATE from scenario weights.
Scenario weights are governed by VERSION_ID and SCENARIO_CODE; the reporting date
selects the effective ScenarioWeightVersion through RunControl.
Safe to run after migration 008. This migration is idempotent for fresh databases
where migration 001 has already been updated to omit PROCESS_DATE.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_cfg.ScenarioWeight', N'U') IS NOT NULL
BEGIN
    IF EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'ecl_cfg.ScenarioWeight')
          AND name = N'IX_ScenarioWeight_ProcessDate_Active'
    )
        DROP INDEX IX_ScenarioWeight_ProcessDate_Active
            ON ecl_cfg.ScenarioWeight;

    IF COL_LENGTH(N'ecl_cfg.ScenarioWeight', N'PROCESS_DATE') IS NOT NULL
        ALTER TABLE ecl_cfg.ScenarioWeight DROP COLUMN PROCESS_DATE;
END;
GO
