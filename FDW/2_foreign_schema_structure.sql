-- ============================================================================================================
-- Script: foreign_schema_structure.sql
-- Purpose:
--   Generic FDW schema bootstrap: creates a *new* local schema containing the same foreign tables used
--   by the ETL (same structure as dwh_remote / dwh_remote2), but parametrized by:
--   - FDW schema name (local)
--   - FDW server name
--
-- How to run (psql):
--   psql ... -v fdw_schema=dwh_remote3 -v fdw_server=sqlserver_dwh -f FDW/2_foreign_schema_structure.sql
--
-- Optional overrides:
--   -v dwh_schema=sp203_an -v grouped_schema=dbo
--
-- Notes:
--   - Includes the Downtime datetime parsing fix by mapping DateTimeStart/DateTimeEnd as TEXT.
--   - Keeps the explicit column list for DeviceOnStepGrouped (dbo) as required by ETL.
-- ============================================================================================================

-- Required variables (must be passed via: psql ... -v key=value ...)
-- Example:
--   psql ... -v fdw_schema=dwh_remote3 -v fdw_server=sqlserver_dwh -v dwh_schema=sp203_an -v grouped_schema=dbo -f foreign_schema_structure.sql
\if :{?fdw_schema}
\else
  \echo 'ERROR: missing required psql variable fdw_schema (use: -v fdw_schema=...)'
  \quit 2
\endif
\if :{?fdw_server}
\else
  \echo 'ERROR: missing required psql variable fdw_server (use: -v fdw_server=...)'
  \quit 2
\endif
\if :{?dwh_schema}
\else
  \echo 'ERROR: missing required psql variable dwh_schema (use: -v dwh_schema=...)'
  \quit 2
\endif
\if :{?grouped_schema}
\else
  \echo 'ERROR: missing required psql variable grouped_schema (use: -v grouped_schema=...)'
  \quit 2
\endif

BEGIN;

CREATE SCHEMA IF NOT EXISTS :"fdw_schema";

-- =====================================================================================
-- Lookups / core DWH entities (schema = :dwh_schema)
-- =====================================================================================

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Code";
CREATE FOREIGN TABLE :"fdw_schema"."Code" (
  "CodeIntId" integer NOT NULL,
  "CodeKey" varchar(255) NOT NULL,
  "Description" text NOT NULL,
  "CodeTypeIntId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Code');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."CodeType";
CREATE FOREIGN TABLE :"fdw_schema"."CodeType" (
  "CodeTypeIntId" integer NOT NULL,
  "ProcessIntId" smallint NOT NULL,
  "CodeTypeKey" varchar(50) NOT NULL,
  "Description" text NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'CodeType');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Device";
CREATE FOREIGN TABLE :"fdw_schema"."Device" (
  "Id" bigint NOT NULL,
  "SerialNumber" varchar(100) NOT NULL,
  "ProcessIntId" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Device');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."DeviceOnMeasure";
CREATE FOREIGN TABLE :"fdw_schema"."DeviceOnMeasure" (
  "Id" bigint NOT NULL,
  "DeviceOnStepId" bigint NOT NULL,
  "MeasureId" integer NOT NULL,
  "ValueReal" real,
  "ValueString" text,
  "DurationMs" integer NOT NULL,
  "ValueTypeEnum" smallint NOT NULL,
  "SequenceNumber" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'DeviceOnMeasure');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."DeviceOnStep";
CREATE FOREIGN TABLE :"fdw_schema"."DeviceOnStep" (
  "Id" bigint NOT NULL,
  "DeviceId" bigint NOT NULL,
  "StartDateTime" timestamp(6) without time zone NOT NULL,
  "EndDateTime" timestamp(6) without time zone,
  "CycleTimeMs" integer,
  "CodeIntId" integer NOT NULL,
  "FixtureIntId" integer NOT NULL,
  "ResultIntId" integer,
  "SiteIntId" smallint NOT NULL,
  "StepIntId" integer NOT NULL,
  "ShiftIntId" integer NOT NULL,
  "PassNumber" smallint NOT NULL,
  "ProductionTimeHalfHourId" integer NOT NULL,
  "ProductionTimeDateId" integer NOT NULL,
  "IntervalTimeWaitMs" integer NOT NULL,
  "IntervalTimeWorkMs" integer,
  "IsGood" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'DeviceOnStep');

-- =====================================================================================
-- ETL fact-like sources with explicit column list
-- =====================================================================================

-- dbo.DeviceOnStepGrouped (schema = :grouped_schema)
DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."DeviceOnStepGrouped";
CREATE FOREIGN TABLE :"fdw_schema"."DeviceOnStepGrouped" (
  "ProductionTimeDateId" integer,
  "CodeIntId" smallint,
  "FixtureIntId" smallint,
  "ResultIntId" smallint,
  "SiteIntId" smallint,
  "StepIntId" smallint,
  "ShiftIntId" smallint,
  "PassNumber" integer,
  "TotalProduction" integer,
  "CycleTimeAvgSec" numeric(18,6),
  "AvgWorkTimeSec" numeric(28,6),
  "TotalWorkTimeSec" numeric(28,6)
)
SERVER :"fdw_server"
OPTIONS (schema_name :'grouped_schema', table_name 'DeviceOnStepGrouped');

-- sp203_an.Downtime (schema = :dwh_schema) with datetime-as-text fix
DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Downtime";
CREATE FOREIGN TABLE :"fdw_schema"."Downtime" (
  "Id" integer NOT NULL,
  "SeverityEn" smallint NOT NULL,
  "StreamEn" smallint NOT NULL,
  "ToolName" text,
  "Description" text,
  "CodeIntId" integer,
  "MachineIntId" integer NOT NULL,
  "DateTimeStart" text NOT NULL,
  "DateTimeEnd" text NOT NULL,
  "IntervalTimeMs" integer NOT NULL,
  "ShiftIntId" integer NOT NULL,
  "ProductionTimeHalHourId" integer NOT NULL,
  "ProductionTimeDateId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Downtime');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."EventMachine";
CREATE FOREIGN TABLE :"fdw_schema"."EventMachine" (
  "Id" bigint NOT NULL,
  "DowntimeEn" smallint NOT NULL,
  "SeverityEn" smallint NOT NULL,
  "StreamEn" smallint NOT NULL,
  "Timestamp" timestamp(6) without time zone NOT NULL,
  "ToolName" text,
  "Description" text,
  "CodeIntId" integer,
  "MachineIntId" integer NOT NULL,
  "ProductionTimeDateId" integer NOT NULL,
  "ProductionTimeHalHourId" integer NOT NULL,
  "ShiftIntId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'EventMachine');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Fixture";
CREATE FOREIGN TABLE :"fdw_schema"."Fixture" (
  "FixtureIntId" integer NOT NULL,
  "FixtureKey" varchar(50) NOT NULL,
  "Desciption" text NOT NULL,
  "MachineIntId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Fixture');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Line";
CREATE FOREIGN TABLE :"fdw_schema"."Line" (
  "Id" integer NOT NULL,
  "LineKey" varchar(200) NOT NULL,
  "Description" text NOT NULL,
  "DisplayOrder" integer NOT NULL,
  "DisplayIsActive" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Line');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."LineVsMachine";
CREATE FOREIGN TABLE :"fdw_schema"."LineVsMachine" (
  "Id" integer NOT NULL,
  "LineId" integer NOT NULL,
  "MachineId" integer NOT NULL,
  "DisplayOrder" integer NOT NULL,
  "DisplayIsActive" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'LineVsMachine');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Machine";
CREATE FOREIGN TABLE :"fdw_schema"."Machine" (
  "MachineIntId" integer NOT NULL,
  "MachineKey" varchar(50) NOT NULL,
  "Description" text NOT NULL,
  "DisplayOrder" integer NOT NULL,
  "DisplayIsActive" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Machine');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."MachineVsStep";
CREATE FOREIGN TABLE :"fdw_schema"."MachineVsStep" (
  "Id" integer NOT NULL,
  "MachineIntId" integer NOT NULL,
  "StepIntId" integer NOT NULL,
  "IdealCycleTimeMs" integer NOT NULL,
  "IsActive" smallint NOT NULL,
  "Position" integer NOT NULL,
  "Priority" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'MachineVsStep');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Measure";
CREATE FOREIGN TABLE :"fdw_schema"."Measure" (
  "Id" integer NOT NULL,
  "OperationIntId" integer NOT NULL,
  "MeasureKey" varchar(50) NOT NULL,
  "Description" text NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Measure');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Operation";
CREATE FOREIGN TABLE :"fdw_schema"."Operation" (
  "OperationIntId" integer NOT NULL,
  "OperationKey" varchar(100) NOT NULL,
  "Description" text NOT NULL,
  "StepIntId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Operation');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Process";
CREATE FOREIGN TABLE :"fdw_schema"."Process" (
  "ProcessIntId" smallint NOT NULL,
  "ProcessKey" varchar(200) NOT NULL,
  "Description" text NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Process');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."ProductionTimeDate";
CREATE FOREIGN TABLE :"fdw_schema"."ProductionTimeDate" (
  "Id" integer NOT NULL,
  "Date" text NOT NULL,
  "Year" integer NOT NULL,
  "Month" integer NOT NULL,
  "Day" integer NOT NULL,
  "Weekday" varchar(50) NOT NULL,
  "WeekNumber" integer NOT NULL,
  "Quarter" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'ProductionTimeDate');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."ProductionTimeHalfHour";
CREATE FOREIGN TABLE :"fdw_schema"."ProductionTimeHalfHour" (
  "Id" integer NOT NULL,
  "TimeOfDayStart" text NOT NULL,
  "TimeOfDayEnd" text NOT NULL,
  "Description" varchar(15) NOT NULL,
  "Hour" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'ProductionTimeHalfHour');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Property";
CREATE FOREIGN TABLE :"fdw_schema"."Property" (
  "PropertyIntId" integer NOT NULL,
  "PropertyKey" varchar(50) NOT NULL,
  "ProcessIntId" smallint NOT NULL,
  "Description" text NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Property');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."PropertyValue";
CREATE FOREIGN TABLE :"fdw_schema"."PropertyValue" (
  "PropertyValueIntId" integer NOT NULL,
  "PropertyValueKey" varchar(50) NOT NULL,
  "PropertyId" integer NOT NULL,
  "Description" varchar(50) NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'PropertyValue');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Result";
CREATE FOREIGN TABLE :"fdw_schema"."Result" (
  "ResultIntId" integer NOT NULL,
  "ResultKey" varchar(50) NOT NULL,
  "Description" text NOT NULL,
  "IsGood" smallint NOT NULL,
  "StepIntId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Result');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Shift";
CREATE FOREIGN TABLE :"fdw_schema"."Shift" (
  "ShiftIntId" integer NOT NULL,
  "ShiftKey" varchar(50) NOT NULL,
  "StartTime" text NOT NULL,
  "EndTime" text NOT NULL,
  "Description" text NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Shift');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Site";
CREATE FOREIGN TABLE :"fdw_schema"."Site" (
  "SiteIntId" smallint NOT NULL,
  "SiteKey" varchar(50) NOT NULL,
  "Description" text NOT NULL,
  "DisplayOrder" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Site');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."SiteVsMachine";
CREATE FOREIGN TABLE :"fdw_schema"."SiteVsMachine" (
  "Id" integer NOT NULL,
  "MachineId" integer NOT NULL,
  "SiteId" smallint NOT NULL,
  "DisplayIsActive" smallint NOT NULL,
  "DisplayOrder" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'SiteVsMachine');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Step";
CREATE FOREIGN TABLE :"fdw_schema"."Step" (
  "StepIntId" integer NOT NULL,
  "StepKey" varchar(50) NOT NULL,
  "Description" text NOT NULL,
  "DisplayOrder" integer NOT NULL,
  "ProcessIntId" smallint NOT NULL,
  "IsEndStep" smallint NOT NULL,
  "IsStartStep" smallint NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Step');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."Workflow";
CREATE FOREIGN TABLE :"fdw_schema"."Workflow" (
  "WorkflowIntId" integer NOT NULL,
  "WorkflowKey" varchar(50) NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'Workflow');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."WorkflowVsCode";
CREATE FOREIGN TABLE :"fdw_schema"."WorkflowVsCode" (
  "Id" integer NOT NULL,
  "WorkflowIntId" integer NOT NULL,
  "CodeIntId" integer NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name 'WorkflowVsCode');

DROP FOREIGN TABLE IF EXISTS :"fdw_schema"."__MigrationsHistory";
CREATE FOREIGN TABLE :"fdw_schema"."__MigrationsHistory" (
  "MigrationId" varchar(150) NOT NULL,
  "ProductVersion" varchar(32) NOT NULL
)
SERVER :"fdw_server"
OPTIONS (schema_name :'dwh_schema', table_name '__MigrationsHistory');

COMMIT;

