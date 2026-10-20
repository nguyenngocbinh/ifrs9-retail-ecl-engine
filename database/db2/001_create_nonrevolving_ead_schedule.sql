-- DB2 LUW: Non-Revolving EAD schedule staging table.
-- Separate upstream/staging adapter; this is not a SQL Server migration.
-- Execute in the DB2 environment where TPBCSO_SEC source tables are available.

CREATE TABLE RM_RDM_MOP_PROD.TBL_NONREVOLVING_EAD_SCHEDULE
(
    PROCESS_DATE                 DATE          NOT NULL,
    ACCOUNT_NUMBER               VARCHAR(50)   NOT NULL,
    MATURITY_DATE                DATE,
    SCHEDULE_DUE_DATE             DATE          NOT NULL,
    SCHEDULE_NO                   INTEGER,
    EAD_0                         DECIMAL(31, 2),
    PRINCIPAL_REPAYMENT            DECIMAL(31, 2),
    CUM_PRINCIPAL_REPAYMENT        DECIMAL(31, 2),
    EAD_AFTER_REPAYMENT            DECIMAL(31, 2)
);
