-- Inserisce/aggiorna la connection string per log_error_write (dblink).
--
-- IMPORTANT:
-- - Do not commit passwords in this repository.
-- - Pass the connection string at runtime via psql variables.
--
-- How to run (PowerShell example):
--   psql ... -v dblink_conn_str="dbname=... user=... password=... host=... port=5432" -f set_log_error_write_dblink_conn.sql
--
-- Requirements:
-- - Table application_data.log_error_write_cfg must exist (created by 2_create_table.sql).

\if :{?dblink_conn_str}
\else
  \echo 'ERROR: missing required psql variable dblink_conn_str'
  \echo 'Usage: psql ... -v dblink_conn_str="dbname=... user=... password=... host=... port=5432" -f set_log_error_write_dblink_conn.sql'
  \quit 2
\endif

INSERT INTO application_data.log_error_write_cfg (config_key, config_value)
VALUES (
  'dblink_conn_str',
  :'dblink_conn_str'
)
ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value;

