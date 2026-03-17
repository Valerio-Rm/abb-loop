param(
  # PostgreSQL connection
  [Parameter(Mandatory = $true)][string]$PgHost,
  [Parameter(Mandatory = $false)][int]$PgPort = 5432,
  [Parameter(Mandatory = $true)][string]$PgDb,
  [Parameter(Mandatory = $true)][string]$PgAdminUser,

  # FDW / privileges
  [Parameter(Mandatory = $true)][string]$PgRole,
  [Parameter(Mandatory = $true)][string]$ServerName,
  [Parameter(Mandatory = $true)][string]$FdwSchema,

  # MSSQL connection (tds_fdw server options + user mapping)
  [Parameter(Mandatory = $true)][string]$MssqlHost,
  [Parameter(Mandatory = $false)][int]$MssqlPort = 1433,
  [Parameter(Mandatory = $true)][string]$MssqlDb,
  [Parameter(Mandatory = $true)][string]$MssqlUser,
  [Parameter(Mandatory = $true)][string]$MssqlPassword,

  # Remote schemas
  [Parameter(Mandatory = $false)][string]$DwhSchema = "sp203_an",
  [Parameter(Mandatory = $false)][string]$GroupedSchema = "dbo",

  # psql executable (if not in PATH)
  [Parameter(Mandatory = $false)][string]$PsqlPath = "psql"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fdw1 = Join-Path $here "1_fdw_settings.sql"
$fdw2 = Join-Path $here "2_foreign_schema_structure.sql"

if (!(Test-Path -LiteralPath $fdw1)) { throw "Missing file: $fdw1" }
if (!(Test-Path -LiteralPath $fdw2)) { throw "Missing file: $fdw2" }

Write-Host "Running FDW bootstrap (1_fdw_settings.sql)..."
& $PsqlPath -h $PgHost -p $PgPort -d $PgDb -U $PgAdminUser `
  -v pg_role=$PgRole `
  -v server_name=$ServerName `
  -v fdw_schema=$FdwSchema `
  -v mssql_host=$MssqlHost `
  -v mssql_port=$MssqlPort `
  -v mssql_db=$MssqlDb `
  -v mssql_user=$MssqlUser `
  -v mssql_password="$MssqlPassword" `
  -f $fdw1

Write-Host "Creating foreign tables (2_foreign_schema_structure.sql)..."
& $PsqlPath -h $PgHost -p $PgPort -d $PgDb -U $PgAdminUser `
  -v fdw_schema=$FdwSchema `
  -v fdw_server=$ServerName `
  -v dwh_schema=$DwhSchema `
  -v grouped_schema=$GroupedSchema `
  -f $fdw2

Write-Host "Done."

