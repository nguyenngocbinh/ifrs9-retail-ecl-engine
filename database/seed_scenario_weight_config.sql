/*
IFRS 9 Retail ECL Engine — reference configuration seed
Run AFTER database/001_create_logical_schema.sql through database/008_lgd_curve_loader.sql.
Safe to rerun: inserts missing configuration only; does not overwrite an existing version.
Review EFFECTIVE_FROM with the model/configuration owner before using outside DEV/UAT.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @VERSION_ID int = 1;
DECLARE @VERSION_NAME nvarchar(100) = N'SCENARIO_WEIGHT_V1';
DECLARE @EFFECTIVE_FROM date = '20260101';
DECLARE @EFFECTIVE_TO date = NULL;

BEGIN TRY
    BEGIN TRANSACTION;

    /* Scenario and pool reference values are already seeded by migration 001.
       Fail clearly if the required scenario codes are missing/inactive. */
    IF (SELECT COUNT_BIG(*) FROM ecl_cfg.Scenario
        WHERE SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN') AND IS_ACTIVE = 1) <> 3
        THROW 51001, 'Required active scenarios DOWNTURN, BASE, UPTURN are missing. Check database/001 seed data.', 1;

    IF EXISTS (
        SELECT 1
        FROM ecl_cfg.ScenarioWeightVersion
        WHERE VERSION_ID = @VERSION_ID
          AND (VERSION_NAME <> @VERSION_NAME
               OR EFFECTIVE_FROM <> @EFFECTIVE_FROM
               OR ISNULL(EFFECTIVE_TO, CONVERT(date,'99991231')) <> ISNULL(@EFFECTIVE_TO, CONVERT(date,'99991231')))
    )
        THROW 51002, 'ScenarioWeightVersion VERSION_ID=1 already exists with different attributes. Do not overwrite a version that may have been used by a run.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_cfg.ScenarioWeightVersion WHERE VERSION_ID = @VERSION_ID)
    BEGIN
        INSERT INTO ecl_cfg.ScenarioWeightVersion
            (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
        VALUES
            (@VERSION_ID, @VERSION_NAME, @EFFECTIVE_FROM, @EFFECTIVE_TO, 1);
    END;

    /* If version 1 already has any weight rows, require them to match exactly.
       This prevents a rerun from silently changing historical configuration. */
    IF EXISTS (
        SELECT 1
        FROM ecl_cfg.ScenarioWeight
        WHERE VERSION_ID = @VERSION_ID
          AND (
                (SCENARIO_CODE = 'DOWNTURN' AND SCENARIO_WEIGHT <> CONVERT(decimal(9,8),0.15680000))
             OR (SCENARIO_CODE = 'BASE'     AND SCENARIO_WEIGHT <> CONVERT(decimal(9,8),0.68640000))
             OR (SCENARIO_CODE = 'UPTURN'   AND SCENARIO_WEIGHT <> CONVERT(decimal(9,8),0.15680000))
             OR SCENARIO_CODE NOT IN ('DOWNTURN','BASE','UPTURN')
          )
    )
        THROW 51003, 'ScenarioWeight VERSION_ID=1 contains conflicting values. Do not overwrite a version that may have been used by a run.', 1;

    IF EXISTS (SELECT 1 FROM ecl_cfg.ScenarioWeight WHERE VERSION_ID = @VERSION_ID)
       AND (SELECT COUNT(*) FROM ecl_cfg.ScenarioWeight WHERE VERSION_ID = @VERSION_ID) <> 3
        THROW 51004, 'ScenarioWeight VERSION_ID=1 is partially populated. Review and repair it manually before rerunning this seed.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_cfg.ScenarioWeight WHERE VERSION_ID = @VERSION_ID)
    BEGIN
        INSERT INTO ecl_cfg.ScenarioWeight
            (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, IS_ACTIVE)
        VALUES
            (@VERSION_ID, 'DOWNTURN', 0.15680000, 1),
            (@VERSION_ID, 'BASE',     0.68640000, 1),
            (@VERSION_ID, 'UPTURN',   0.15680000, 1);
    END;

    /* Activate this version only if it is the sole version intended to be active.
       Do not deactivate other versions automatically. */
    IF EXISTS (
        SELECT 1 FROM ecl_cfg.ScenarioWeightVersion
        WHERE IS_ACTIVE = 1 AND VERSION_ID <> @VERSION_ID
          AND EFFECTIVE_FROM <= CONVERT(date, GETDATE())
          AND (EFFECTIVE_TO IS NULL OR EFFECTIVE_TO >= CONVERT(date, GETDATE()))
    )
        THROW 51005, 'Another active scenario-weight version is effective today. Resolve the version overlap before activating VERSION_ID=1.', 1;

    UPDATE ecl_cfg.ScenarioWeightVersion
       SET IS_ACTIVE = 1
     WHERE VERSION_ID = @VERSION_ID AND IS_ACTIVE = 0;

    COMMIT TRANSACTION;

    SELECT v.VERSION_ID, v.VERSION_NAME, v.EFFECTIVE_FROM, v.EFFECTIVE_TO, v.IS_ACTIVE,
           w.SCENARIO_CODE, w.SCENARIO_WEIGHT, w.IS_ACTIVE AS WEIGHT_IS_ACTIVE,
           SUM(w.SCENARIO_WEIGHT) OVER (PARTITION BY w.VERSION_ID) AS TOTAL_WEIGHT
    FROM ecl_cfg.ScenarioWeightVersion AS v
    JOIN ecl_cfg.ScenarioWeight AS w ON w.VERSION_ID = v.VERSION_ID
    WHERE v.VERSION_ID = @VERSION_ID
    ORDER BY CASE w.SCENARIO_CODE WHEN 'DOWNTURN' THEN 1 WHEN 'BASE' THEN 2 WHEN 'UPTURN' THEN 3 ELSE 4 END;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
