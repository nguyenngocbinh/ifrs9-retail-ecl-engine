/*
Migration 006: shared EAD curve loader for all retail products.
ETL/source adapters populate ecl_stg.EADCurveInput at the canonical annual grain.
This procedure promotes that normalized input into ecl_stg.EADCurve; it does not
derive EAD from product-specific repayment schedules.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_stg.EADCurveInput', N'U') IS NULL
BEGIN
    CREATE TABLE ecl_stg.EADCurveInput
    (
        RUN_ID bigint NOT NULL,
        PROCESS_DATE date NOT NULL,
        ACCOUNT_ID varchar(100) NOT NULL,
        FORECAST_PERIOD smallint NOT NULL,
        EAD decimal(19,4) NOT NULL,
        CURRENCY_CODE char(3) NOT NULL,
        VERSION_ID int NOT NULL,
        IS_ACTIVE bit NOT NULL CONSTRAINT DF_EADCurveInput_IsActive DEFAULT (1),
        SOURCE_REFERENCE nvarchar(200) NULL,
        LOADED_AT datetime2(0) NOT NULL CONSTRAINT DF_EADCurveInput_LoadedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_EADCurveInput PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID, FORECAST_PERIOD),
        CONSTRAINT FK_EADCurveInput_Account FOREIGN KEY (RUN_ID, ACCOUNT_ID)
            REFERENCES ecl_stg.AccountSnapshot(RUN_ID, ACCOUNT_ID),
        CONSTRAINT CK_EADCurveInput_Period CHECK (FORECAST_PERIOD >= 1),
        CONSTRAINT CK_EADCurveInput_EAD CHECK (EAD >= 0)
    );

    CREATE INDEX IX_EADCurveInput_Run_Period
        ON ecl_stg.EADCurveInput (RUN_ID, FORECAST_PERIOD)
        INCLUDE (ACCOUNT_ID, PROCESS_DATE, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE);
END;
GO

IF OBJECT_ID(N'ecl_core.usp_LoadEADCurve', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_LoadEADCurve;
GO
CREATE PROCEDURE ecl_core.usp_LoadEADCurve
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date, @RUN_STATUS varchar(20), @ROW_COUNT bigint;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51600, 'EAD loader: run does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51601, 'EAD loader is only allowed before calculation begins.', 1;

        IF NOT EXISTS (SELECT 1 FROM ecl_stg.AccountSnapshot WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1)
            THROW 51602, 'EAD loader: no active account snapshots exist for this run.', 1;

        IF NOT EXISTS (SELECT 1 FROM ecl_stg.EADCurveInput WHERE RUN_ID = @RUN_ID)
            THROW 51603, 'EAD loader: no normalized EAD input rows exist for this run.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.EADCurveInput
            WHERE RUN_ID = @RUN_ID
              AND (PROCESS_DATE <> @PROCESS_DATE OR EAD < 0 OR CURRENCY_CODE <> 'VND')
        )
            THROW 51604, 'EAD loader: input date must match the run, EAD must be non-negative, and currency must be VND.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.EADCurveInput i
            LEFT JOIN ecl_stg.AccountSnapshot a
              ON a.RUN_ID = i.RUN_ID AND a.ACCOUNT_ID = i.ACCOUNT_ID
            WHERE i.RUN_ID = @RUN_ID
              AND (a.ACCOUNT_ID IS NULL OR a.PROCESS_DATE <> i.PROCESS_DATE)
        )
            THROW 51605, 'EAD loader: every input row must match an account snapshot with the same process date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            CROSS APPLY
            (
                SELECT CONVERT(int, CEILING(DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE) / 12.0)) AS HORIZON
            ) h
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND
              (
                  a.MATURITY_DATE <= @PROCESS_DATE
                  OR h.HORIZON < 1
                  OR h.HORIZON > 120
                  OR EXISTS
                  (
                      SELECT 1
                      FROM
                      (
                          SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                          FROM sys.all_objects x CROSS JOIN sys.all_objects y
                      ) n
                      WHERE n.N <= h.HORIZON
                        AND NOT EXISTS
                        (
                            SELECT 1
                            FROM ecl_stg.EADCurveInput i
                            WHERE i.RUN_ID = a.RUN_ID
                              AND i.ACCOUNT_ID = a.ACCOUNT_ID
                              AND i.PROCESS_DATE = @PROCESS_DATE
                              AND i.FORECAST_PERIOD = n.N
                              AND i.IS_ACTIVE = 1
                              AND i.CURRENCY_CODE = 'VND'
                        )
                  )
              )
        )
            THROW 51606, 'EAD loader: active accounts need active VND EAD rows for every annual period through maturity (maximum 120 periods).', 1;

        /* Replace only this run's canonical EAD rows; source intake remains auditable. */
        DELETE FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_stg.EADCurve
            (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
        SELECT RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE
        FROM ecl_stg.EADCurveInput
        WHERE RUN_ID = @RUN_ID;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'EAD_LOAD', 'SUCCEEDED',
             N'Normalized EAD input promoted to canonical EADCurve for all product types.',
             @ROW_COUNT, SUSER_SNAME());

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @ROW_COUNT AS EAD_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
