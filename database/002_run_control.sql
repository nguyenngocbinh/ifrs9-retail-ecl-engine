/*
IFRS 9 Retail ECL Engine — run-control migration 002
Target: SQL Server 2016
Adds run-to-input-version manifest and guarded lifecycle procedures.
No ECL calculation formula is implemented here.

Deploy after database/001_create_logical_schema.sql in a disposable/dev database first.
This is an initial migration script, not a rerunnable/idempotent migration.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE ecl_core.RunInputManifest (
    RUN_ID bigint NOT NULL,
    IS_SEALED bit NOT NULL CONSTRAINT DF_RunInputManifest_IsSealed DEFAULT (0),
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_RunInputManifest_CreatedAt DEFAULT (SYSUTCDATETIME()),
    SEALED_AT datetime2(0) NULL,
    CREATED_BY sysname NOT NULL CONSTRAINT DF_RunInputManifest_CreatedBy DEFAULT (SUSER_SNAME()),
    CONSTRAINT PK_RunInputManifest PRIMARY KEY CLUSTERED (RUN_ID),
    CONSTRAINT FK_RunInputManifest_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
    CONSTRAINT CK_RunInputManifest_Seal CHECK ((IS_SEALED = 0 AND SEALED_AT IS NULL) OR (IS_SEALED = 1 AND SEALED_AT IS NOT NULL))
);
GO

CREATE TABLE ecl_core.RunInputManifestItem (
    RUN_ID bigint NOT NULL,
    INPUT_FAMILY varchar(30) NOT NULL,
    SOURCE_SYSTEM varchar(100) NOT NULL,
    SOURCE_OBJECT varchar(256) NOT NULL,
    SOURCE_VERSION varchar(100) NOT NULL,
    SNAPSHOT_ROW_COUNT bigint NOT NULL,
    CONTENT_HASH varbinary(32) NULL,
    IS_COMPLETE bit NOT NULL,
    REGISTERED_AT datetime2(0) NOT NULL CONSTRAINT DF_RunInputManifestItem_RegisteredAt DEFAULT (SYSUTCDATETIME()),
    REGISTERED_BY sysname NOT NULL CONSTRAINT DF_RunInputManifestItem_RegisteredBy DEFAULT (SUSER_SNAME()),
    CONSTRAINT PK_RunInputManifestItem PRIMARY KEY CLUSTERED (RUN_ID, INPUT_FAMILY),
    CONSTRAINT FK_RunInputManifestItem_Header FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunInputManifest(RUN_ID),
    CONSTRAINT CK_RunInputManifestItem_Family CHECK (INPUT_FAMILY IN ('ACCOUNT','PD','LGD','EAD','EIR','SCENARIO_WEIGHT')),
    CONSTRAINT CK_RunInputManifestItem_RowCount CHECK (SNAPSHOT_ROW_COUNT >= 0)
);
GO
CREATE INDEX IX_RunInputManifestItem_Family_Version
    ON ecl_core.RunInputManifestItem (INPUT_FAMILY, SOURCE_VERSION, RUN_ID)
    INCLUDE (SNAPSHOT_ROW_COUNT, IS_COMPLETE);
GO

/* Create a run and its manifest header atomically. */
IF OBJECT_ID(N'ecl_core.usp_CreateRun', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_CreateRun;
GO
CREATE PROCEDURE ecl_core.usp_CreateRun
    @PROCESS_DATE date,
    @RUN_TYPE varchar(20),
    @SCENARIO_WEIGHT_VERSION_ID int,
    @CALCULATION_VERSION varchar(30),
    @REQUESTED_POOL_NAME varchar(100) = NULL,
    @REQUESTED_POOL_ID varchar(100) = NULL,
    @RUN_NOTE nvarchar(1000) = NULL,
    @RUN_ID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @PROCESS_DATE IS NULL THROW 51001, 'PROCESS_DATE is required.', 1;
    IF @RUN_TYPE NOT IN ('FULL', 'SELECTIVE') THROW 51002, 'RUN_TYPE must be FULL or SELECTIVE.', 1;
    IF NULLIF(LTRIM(RTRIM(@CALCULATION_VERSION)), '') IS NULL THROW 51003, 'CALCULATION_VERSION is required.', 1;
    IF @RUN_TYPE = 'SELECTIVE' AND @REQUESTED_POOL_NAME IS NULL AND @REQUESTED_POOL_ID IS NULL
        THROW 51004, 'SELECTIVE runs require a product and/or pool selector.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM ecl_cfg.ScenarioWeightVersion
        WHERE VERSION_ID = @SCENARIO_WEIGHT_VERSION_ID
          AND EFFECTIVE_FROM <= @PROCESS_DATE
          AND (EFFECTIVE_TO IS NULL OR EFFECTIVE_TO >= @PROCESS_DATE)
    )
        THROW 51005, 'Scenario-weight version does not exist or is not effective for PROCESS_DATE.', 1;

    IF @REQUESTED_POOL_NAME IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM ecl_cfg.PoolName WHERE POOL_NAME = @REQUESTED_POOL_NAME AND IS_ACTIVE = 1)
        THROW 51006, 'Requested pool name is not active or does not exist.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO ecl_core.RunControl
            (PROCESS_DATE, RUN_TYPE, RUN_STATUS, SCENARIO_WEIGHT_VERSION_ID,
             REQUESTED_POOL_NAME, REQUESTED_POOL_ID, CALCULATION_VERSION, RUN_NOTE)
        VALUES
            (@PROCESS_DATE, @RUN_TYPE, 'CREATED', @SCENARIO_WEIGHT_VERSION_ID,
             @REQUESTED_POOL_NAME, @REQUESTED_POOL_ID, @CALCULATION_VERSION, @RUN_NOTE);

        SET @RUN_ID = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO ecl_core.RunInputManifest (RUN_ID)
        VALUES (@RUN_ID);

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'RUN_CREATED', 'SUCCEEDED',
             N'Run and input manifest header created.', SUSER_SNAME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Register one immutable input-family reference before sealing.
   SOURCE_OBJECT is a logical/source identifier, not a place for credentials or row data. */
IF OBJECT_ID(N'ecl_core.usp_RegisterRunInput', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_RegisterRunInput;
GO
CREATE PROCEDURE ecl_core.usp_RegisterRunInput
    @RUN_ID bigint,
    @INPUT_FAMILY varchar(30),
    @SOURCE_SYSTEM varchar(100),
    @SOURCE_OBJECT varchar(256),
    @SOURCE_VERSION varchar(100),
    @SNAPSHOT_ROW_COUNT bigint,
    @IS_COMPLETE bit,
    @CONTENT_HASH varbinary(32) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @INPUT_FAMILY NOT IN ('ACCOUNT','PD','LGD','EAD','EIR','SCENARIO_WEIGHT')
        THROW 51010, 'Unsupported INPUT_FAMILY.', 1;
    IF NULLIF(LTRIM(RTRIM(@SOURCE_SYSTEM)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SOURCE_OBJECT)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SOURCE_VERSION)), '') IS NULL
        THROW 51011, 'Source system, object, and version are required.', 1;
    IF @SNAPSHOT_ROW_COUNT < 0 THROW 51012, 'SNAPSHOT_ROW_COUNT cannot be negative.', 1;
    IF @IS_COMPLETE IS NULL THROW 51013, 'IS_COMPLETE must be explicitly supplied.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (
            SELECT 1
            FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
            JOIN ecl_core.RunInputManifest WITH (UPDLOCK, HOLDLOCK)
              ON RunControl.RUN_ID = RunInputManifest.RUN_ID
            WHERE RunControl.RUN_ID = @RUN_ID
              AND RunControl.RUN_STATUS IN ('CREATED','VALIDATING')
              AND RunInputManifest.IS_SEALED = 0
        )
            THROW 51014, 'Run is missing, no longer accepting inputs, or its manifest is sealed.', 1;

        INSERT INTO ecl_core.RunInputManifestItem
            (RUN_ID, INPUT_FAMILY, SOURCE_SYSTEM, SOURCE_OBJECT, SOURCE_VERSION,
             SNAPSHOT_ROW_COUNT, CONTENT_HASH, IS_COMPLETE)
        VALUES
            (@RUN_ID, @INPUT_FAMILY, @SOURCE_SYSTEM, @SOURCE_OBJECT, @SOURCE_VERSION,
             @SNAPSHOT_ROW_COUNT, @CONTENT_HASH, @IS_COMPLETE);

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        SELECT @RUN_ID, PROCESS_DATE, 'INPUT_VERSION_REGISTERED', 'SUCCEEDED',
               CONCAT('Registered input family ', @INPUT_FAMILY, ', version ', @SOURCE_VERSION, '.'),
               @SNAPSHOT_ROW_COUNT, SUSER_SNAME()
        FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Seal only when all required logical input families have a complete manifest entry. */
IF OBJECT_ID(N'ecl_core.usp_SealRunInputs', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_SealRunInputs;
GO
CREATE PROCEDURE ecl_core.usp_SealRunInputs
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date;
    DECLARE @LOCK_RESULT int;
    DECLARE @LOCK_RESOURCE nvarchar(255);

    SET @LOCK_RESOURCE = CONCAT('ECL_RUN_INPUT_SEAL_', @RUN_ID);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LOCK_RESULT = sys.sp_getapplock
            @Resource = @LOCK_RESOURCE,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LOCK_RESULT < 0 THROW 51020, 'Could not acquire input-seal lock.', 1;

        SELECT @PROCESS_DATE = PROCESS_DATE
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID AND RUN_STATUS IN ('CREATED','VALIDATING');

        IF @PROCESS_DATE IS NULL THROW 51021, 'Run is missing or not in a state that accepts input sealing.', 1;

        IF NOT EXISTS (SELECT 1 FROM ecl_core.RunInputManifest WHERE RUN_ID = @RUN_ID AND IS_SEALED = 0)
            THROW 51022, 'Manifest is missing or already sealed.', 1;

        IF EXISTS (
            SELECT required.INPUT_FAMILY
            FROM (VALUES ('ACCOUNT'),('PD'),('LGD'),('EAD'),('EIR'),('SCENARIO_WEIGHT')) required(INPUT_FAMILY)
            LEFT JOIN ecl_core.RunInputManifestItem item
              ON item.RUN_ID = @RUN_ID AND item.INPUT_FAMILY = required.INPUT_FAMILY
            WHERE item.INPUT_FAMILY IS NULL OR item.IS_COMPLETE <> 1
        )
            THROW 51023, 'Cannot seal manifest: one or more required input families are missing or incomplete.', 1;

        UPDATE ecl_core.RunInputManifest
        SET IS_SEALED = 1, SEALED_AT = SYSUTCDATETIME()
        WHERE RUN_ID = @RUN_ID AND IS_SEALED = 0;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        SELECT @RUN_ID, @PROCESS_DATE, 'INPUTS_SEALED', 'SUCCEEDED',
               N'Input manifest sealed; version references are immutable through the supported procedures.',
               (SELECT COUNT_BIG(*) FROM ecl_core.RunInputManifestItem WHERE RUN_ID = @RUN_ID),
               SUSER_SNAME();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Guard lifecycle transitions. Output is not published until reconciliation succeeded. */
IF OBJECT_ID(N'ecl_core.usp_TransitionRunStatus', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_TransitionRunStatus;
GO
CREATE PROCEDURE ecl_core.usp_TransitionRunStatus
    @RUN_ID bigint,
    @NEW_STATUS varchar(20),
    @EVENT_MESSAGE nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OLD_STATUS varchar(20);
    DECLARE @PROCESS_DATE date;
    DECLARE @ALLOWED bit = 0;
    DECLARE @LOCK_RESULT int;
    DECLARE @LOCK_RESOURCE nvarchar(255);

    SET @LOCK_RESOURCE = CONCAT('ECL_RUN_STATUS_', @RUN_ID);

    IF @NEW_STATUS NOT IN ('VALIDATING','VALIDATION_FAILED','CALCULATING','RECONCILIATION_FAILED','SUCCEEDED','PUBLISHED','FAILED','CANCELLED')
        THROW 51030, 'Unsupported target run status.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LOCK_RESULT = sys.sp_getapplock
            @Resource = @LOCK_RESOURCE,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LOCK_RESULT < 0 THROW 51031, 'Could not acquire run-status lock.', 1;

        SELECT @OLD_STATUS = RUN_STATUS, @PROCESS_DATE = PROCESS_DATE
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @OLD_STATUS IS NULL THROW 51032, 'Run does not exist.', 1;

        IF (@OLD_STATUS = 'CREATED' AND @NEW_STATUS IN ('VALIDATING','CANCELLED','FAILED'))
           OR (@OLD_STATUS = 'VALIDATING' AND @NEW_STATUS IN ('CALCULATING','VALIDATION_FAILED','CANCELLED','FAILED'))
           OR (@OLD_STATUS = 'CALCULATING' AND @NEW_STATUS IN ('SUCCEEDED','RECONCILIATION_FAILED','CANCELLED','FAILED'))
           OR (@OLD_STATUS = 'SUCCEEDED' AND @NEW_STATUS = 'PUBLISHED')
            SET @ALLOWED = 1;

        IF @ALLOWED = 0 THROW 51033, 'Illegal run-status transition.', 1;

        IF @NEW_STATUS = 'CALCULATING'
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM ecl_core.RunInputManifest WHERE RUN_ID = @RUN_ID AND IS_SEALED = 1)
                THROW 51034, 'Inputs must be sealed before calculation starts.', 1;

            IF EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND SEVERITY IN ('ERROR','FATAL'))
                THROW 51035, 'Run has ERROR/FATAL validation findings; calculation is blocked.', 1;
        END;

        IF @NEW_STATUS = 'SUCCEEDED'
        BEGIN
            IF ISNULL((
                SELECT TOP (1) EVENT_STATUS
                FROM ecl_audit.RunEvent
                WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'RECONCILIATION'
                ORDER BY EVENT_ID DESC
            ), '') <> 'SUCCEEDED'
                THROW 51036, 'The latest reconciliation event must be SUCCEEDED before SUCCEEDED.', 1;
        END;

        IF @NEW_STATUS = 'PUBLISHED' AND ISNULL((
            SELECT TOP (1) EVENT_STATUS
            FROM ecl_audit.RunEvent
            WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'PUBLICATION'
            ORDER BY EVENT_ID DESC
        ), '') <> 'SUCCEEDED'
            THROW 51037, 'The latest publication event must be SUCCEEDED before PUBLISHED.', 1;

        UPDATE ecl_core.RunControl
        SET RUN_STATUS = @NEW_STATUS,
            FINISHED_AT = CASE WHEN @NEW_STATUS IN ('VALIDATION_FAILED','RECONCILIATION_FAILED','SUCCEEDED','FAILED','CANCELLED')
                               THEN COALESCE(FINISHED_AT, SYSUTCDATETIME()) ELSE FINISHED_AT END
        WHERE RUN_ID = @RUN_ID AND RUN_STATUS = @OLD_STATUS;

        IF @@ROWCOUNT <> 1 THROW 51038, 'Run status changed concurrently; retry after re-reading state.', 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'STATUS_TRANSITION', 'SUCCEEDED',
             CONCAT(@OLD_STATUS, ' -> ', @NEW_STATUS, CASE WHEN @EVENT_MESSAGE IS NULL THEN '' ELSE CONCAT(': ', @EVENT_MESSAGE) END),
             SUSER_SNAME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Deployment principal should grant EXECUTE on these procedures and avoid direct DML
   against RunControl/manifest/audit tables. Permissions are deployment-specific. */


/* Record controlled reconciliation/publication milestones used by transition gates. */
IF OBJECT_ID(N'ecl_core.usp_RecordRunMilestone', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_RecordRunMilestone;
GO
CREATE PROCEDURE ecl_core.usp_RecordRunMilestone
    @RUN_ID bigint,
    @MILESTONE varchar(20),
    @MILESTONE_STATUS varchar(20),
    @EVENT_MESSAGE nvarchar(2000) = NULL,
    @ROW_COUNT bigint = NULL,
    @AMOUNT_VALUE decimal(28,8) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @MILESTONE NOT IN ('RECONCILIATION','PUBLICATION')
        THROW 51040, 'Unsupported milestone.', 1;
    IF @MILESTONE_STATUS NOT IN ('SUCCEEDED','FAILED')
        THROW 51041, 'Milestone status must be SUCCEEDED or FAILED.', 1;
    IF @ROW_COUNT < 0 THROW 51042, 'ROW_COUNT cannot be negative.', 1;

    DECLARE @PROCESS_DATE date;
    DECLARE @RUN_STATUS varchar(20);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL THROW 51043, 'Run does not exist.', 1;

        IF @MILESTONE = 'RECONCILIATION' AND @RUN_STATUS <> 'CALCULATING'
            THROW 51044, 'Reconciliation milestone can only be recorded while CALCULATING.', 1;
        IF @MILESTONE = 'PUBLICATION' AND @RUN_STATUS <> 'SUCCEEDED'
            THROW 51045, 'Publication milestone can only be recorded while SUCCEEDED.', 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, AMOUNT_VALUE, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, @MILESTONE, @MILESTONE_STATUS, @EVENT_MESSAGE, @ROW_COUNT, @AMOUNT_VALUE, SUSER_SNAME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Defense in depth: reject sealed manifest item mutations without dooming the caller transaction.
   RAISERROR (unlike THROW) does not honor XACT_ABORT; the caller can assert the rejection
   and continue/roll back its disposable test transaction deliberately. */
IF OBJECT_ID(N'ecl_core.trg_RunInputManifestItem_Sealed', N'TR') IS NOT NULL
    DROP TRIGGER ecl_core.trg_RunInputManifestItem_Sealed;
GO
CREATE TRIGGER ecl_core.trg_RunInputManifestItem_Sealed
ON ecl_core.RunInputManifestItem
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    /* Triggers default XACT_ABORT to ON; disable it so the expected RAISERROR does not doom caller transaction. */
    SET XACT_ABORT OFF;

    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN ecl_core.RunInputManifest h ON h.RUN_ID = i.RUN_ID
        WHERE h.IS_SEALED = 1
    )
    OR EXISTS (
        SELECT 1
        FROM deleted d
        JOIN ecl_core.RunInputManifest h ON h.RUN_ID = d.RUN_ID
        WHERE h.IS_SEALED = 1
    )
    BEGIN
        RAISERROR('Input manifest items are immutable after the manifest is sealed.', 16, 1);
        RETURN;
    END
END;
GO

/* Prevent a sealed manifest header from being reopened or having its seal timestamp changed. */
IF OBJECT_ID(N'ecl_core.trg_RunInputManifest_PreventUnseal', N'TR') IS NOT NULL
    DROP TRIGGER ecl_core.trg_RunInputManifest_PreventUnseal;
GO
CREATE TRIGGER ecl_core.trg_RunInputManifest_PreventUnseal
ON ecl_core.RunInputManifest
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    IF EXISTS (
        SELECT 1
        FROM deleted d
        JOIN inserted i ON i.RUN_ID = d.RUN_ID
        WHERE d.IS_SEALED = 1
          AND (i.IS_SEALED <> 1 OR i.SEALED_AT <> d.SEALED_AT)
    )
    BEGIN
        RAISERROR('A sealed manifest cannot be reopened or have its seal timestamp changed.', 16, 1);
        RETURN;
    END
END;
GO
