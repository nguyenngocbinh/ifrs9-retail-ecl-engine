/*
Nạp PD từ TBL_MAN_FACILITY_RATING và RETAIL_MARGINAL_PIT_PD vào ecl_stg.PDCurve.
Giả định hai bảng nguồn nằm trong database hiện tại, schema dbo.
Triển khai sau database/001_create_logical_schema.sql và database/007_pd_curve_loader.sql.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourcePDCurve
    @RUN_ID bigint,
    @VERSION_ID int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date, @ROW_COUNT bigint;

    SELECT @PROCESS_DATE = PROCESS_DATE
    FROM ecl_core.RunControl
    WHERE RUN_ID = @RUN_ID
      AND RUN_STATUS IN ('CREATED', 'VALIDATING');

    IF @PROCESS_DATE IS NULL
        THROW 51800, 'RUN_ID không tồn tại hoặc run không ở trạng thái CREATED/VALIDATING.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM ecl_stg.PDCurve
        WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_stg.PDCurve
        (
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
            FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE
        )
        SELECT
            @RUN_ID,
            @PROCESS_DATE,
            CONVERT(varchar(100), fr.ACCOUNT_ID),
            CASE pd.SCENARIO
                WHEN 1 THEN 'BASE'
                WHEN 2 THEN 'DOWNTURN'
                WHEN 3 THEN 'UPTURN'
            END,
            TRY_CONVERT(smallint, pd.PERIOD),
            TRY_CONVERT(decimal(19,12), pd.FINAL_MARGINAL_PIT_PD),
            @VERSION_ID,
            1
        FROM dbo.TBL_MAN_FACILITY_RATING AS fr
        INNER JOIN ecl_stg.AccountSnapshot AS a
            ON a.RUN_ID = @RUN_ID
           AND a.PROCESS_DATE = @PROCESS_DATE
           AND a.ACCOUNT_ID = CONVERT(varchar(100), fr.ACCOUNT_ID)
           AND a.IS_ACTIVE = 1
        INNER JOIN ecl_cfg.PoolName AS pn
            ON pn.POOL_NAME = a.POOL_NAME
           AND pn.IS_ACTIVE = 1
        INNER JOIN dbo.RETAIL_MARGINAL_PIT_PD AS pd
            ON pd.BUCKET = fr.BUCKET
           AND pd.RATING = fr.RATING
           AND pd.SEGMENT_LV2 = pn.SEGMENT
           AND pd.SCENARIO IN (1, 2, 3)
        WHERE fr.REPORTING_DATE = @PROCESS_DATE;

        SET @ROW_COUNT = @@ROWCOUNT;

        IF @ROW_COUNT = 0
            THROW 51802, 'Không có dòng PD phù hợp. Kiểm tra REPORTING_DATE, ACCOUNT_ID, BUCKET, RATING, SEGMENT và mã SCENARIO.', 1;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS,
            EVENT_MESSAGE, ROW_COUNT, ACTOR
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'PD_SOURCE_ETL', 'SUCCEEDED',
            N'Nạp PD nguồn vào ecl_stg.PDCurve thành công.',
            @ROW_COUNT, SUSER_SNAME()
        );

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, @ROW_COUNT AS PD_ROW_COUNT, 'STAGED' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
