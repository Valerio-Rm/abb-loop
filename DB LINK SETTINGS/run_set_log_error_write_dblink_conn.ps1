# All values are provided at prompt; nothing sensitive is hardcoded here.

# psql binary path (default: 'psql' in PATH)
$PsqlPath = Read-Host -Prompt "Enter psql path (leave empty for 'psql')"
if ([string]::IsNullOrWhiteSpace($PsqlPath)) {
    $PsqlPath = "psql"
}
# Connection to the database that owns application_data.log_error_write_cfg
$DbHost = Read-Host -Prompt "Enter target DB host"
$DbPort = [int](Read-Host -Prompt "Enter target DB port")
$DbUser = Read-Host -Prompt "Enter target DB user"
$DbName = Read-Host -Prompt "Enter target DB name"

# Connection info that will be stored in dblink_conn_str
$DbLinkHost = Read-Host -Prompt "Enter dblink host"
$DbLinkPort = [int](Read-Host -Prompt "Enter dblink port")
$DbLinkUser = Read-Host -Prompt "Enter dblink user"
$DbLinkName = Read-Host -Prompt "Enter dblink database name"

# Directory of this script (handles spaces in path)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Ask for dblink password if not provided as parameter (avoids saving it in the file)
if (-not $DbLinkPassword) {
    $secure = Read-Host -Prompt "Enter password for dblink user '$DbLinkUser'" -AsSecureString
    $DbLinkPassword = [Runtime.InteropServices.Marshal]::PtrToStringUni(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
}

# Build dblink connection string (target for log_error_write dblink).
# NOTE: do not print the full string to avoid exposing the password.
$ConnStr = "dbname=$DbLinkName user=$DbLinkUser password=$DbLinkPassword host=$DbLinkHost port=$DbLinkPort"

Write-Host "Configuring dblink_conn_str for:" -ForegroundColor Cyan
Write-Host "  dbname=$DbLinkName user=$DbLinkUser host=$DbLinkHost port=$DbLinkPort" -ForegroundColor Yellow

# Build psql command arguments
$Args = @(
    "-h", $DbHost,
    "-p", $DbPort,
    "-U", $DbUser,
    "-d", $DbName,
    "-v", "dblink_conn_str=$ConnStr",
    "-f", (Join-Path $ScriptDir "set_log_error_write_dblink_conn.sql")
)

Write-Host ""
Write-Host "Executing psql to configure application_data.log_error_write_cfg.dblink_conn_str ..." -ForegroundColor Green

& $PsqlPath @Args

if ($LASTEXITCODE -ne 0) {
    Write-Host "psql exited with code $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "dblink_conn_str successfully upserted into application_data.log_error_write_cfg." -ForegroundColor Green

