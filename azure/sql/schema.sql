-- Works management system schema. Safe to run more than once.

IF OBJECT_ID('dbo.ServiceRequest') IS NULL
CREATE TABLE dbo.ServiceRequest (
    TrackingId      varchar(24)    NOT NULL CONSTRAINT PK_ServiceRequest PRIMARY KEY,
    CorrelationId   varchar(64)    NULL,
    StatusCode      varchar(16)    NOT NULL CONSTRAINT DF_ServiceRequest_Status DEFAULT 'RECEIVED',
    CategoryCode    varchar(32)    NOT NULL,
    PriorityCode    varchar(8)     NOT NULL,
    DepartmentName  nvarchar(80)   NOT NULL,
    SlaHours        int            NOT NULL,
    Description     nvarchar(2000) NOT NULL,
    Address         nvarchar(200)  NULL,
    SuburbName      nvarchar(80)   NULL,
    Postcode        char(4)        NULL,
    Latitude        decimal(9,6)   NULL,
    Longitude       decimal(9,6)   NULL,
    AssetId         varchar(9)     NULL,
    ReporterName    nvarchar(120)  NULL,
    ReporterEmail   nvarchar(254)  NULL,
    ReporterPhone   varchar(20)    NULL,
    Channel         varchar(16)    NOT NULL,
    ReceivedUtc     datetime2(0)   NOT NULL,
    SlaDueUtc       AS DATEADD(hour, SlaHours, ReceivedUtc) PERSISTED,
    StoredUtc       datetime2(0)   NOT NULL CONSTRAINT DF_ServiceRequest_Stored DEFAULT SYSUTCDATETIME(),
    DeliveryCount   int            NOT NULL CONSTRAINT DF_ServiceRequest_Delivery DEFAULT 1,
    CONSTRAINT CK_ServiceRequest_Priority CHECK (PriorityCode IN ('LOW', 'MEDIUM', 'HIGH'))
);
GO

IF OBJECT_ID('dbo.Asset') IS NULL
CREATE TABLE dbo.Asset (
    AssetId      varchar(9)    NOT NULL CONSTRAINT PK_Asset PRIMARY KEY,
    AssetType    varchar(20)   NOT NULL,
    Description  nvarchar(200) NULL,
    SuburbName   nvarchar(80)  NOT NULL,
    Postcode     char(4)       NOT NULL,
    Latitude     decimal(9,6)  NULL,
    Longitude    decimal(9,6)  NULL,
    StatusCode   varchar(16)   NOT NULL,
    InstalledOn  date          NULL,
    LastRunId    varchar(32)   NOT NULL,
    UpdatedUtc   datetime2(0)  NOT NULL CONSTRAINT DF_Asset_Updated DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('dbo.EtlRun') IS NULL
CREATE TABLE dbo.EtlRun (
    RunId         varchar(32)   NOT NULL CONSTRAINT PK_EtlRun PRIMARY KEY,
    Source        nvarchar(200) NULL,
    TotalRows     int           NULL,
    LoadedRows    int           NULL,
    RejectedRows  int           NULL,
    ElapsedMs     int           NULL,
    FinishedUtc   datetime2(0)  NOT NULL CONSTRAINT DF_EtlRun_Finished DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ServiceRequest_Department_Status')
CREATE INDEX IX_ServiceRequest_Department_Status
    ON dbo.ServiceRequest (DepartmentName, StatusCode) INCLUDE (PriorityCode, SlaDueUtc);
GO

-- What each department has open, and how much of it is past its target.
CREATE OR ALTER VIEW dbo.vOpenRequestsByDepartment AS
SELECT  r.DepartmentName,
        COUNT(*)                                                        AS OpenRequests,
        SUM(CASE WHEN r.PriorityCode = 'HIGH' THEN 1 ELSE 0 END)        AS HighPriority,
        SUM(CASE WHEN r.SlaDueUtc < SYSUTCDATETIME() THEN 1 ELSE 0 END) AS PastTarget,
        SUM(CASE WHEN a.AssetId IS NOT NULL THEN 1 ELSE 0 END)          AS LinkedToKnownAsset
FROM    dbo.ServiceRequest AS r
LEFT JOIN dbo.Asset AS a ON a.AssetId = r.AssetId
WHERE   r.StatusCode NOT IN ('RESOLVED', 'CLOSED')
GROUP BY r.DepartmentName;
GO
