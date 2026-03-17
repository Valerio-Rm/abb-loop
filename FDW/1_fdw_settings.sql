-- fdw_settings.sql
-- Template riutilizzabile: setup tds_fdw + server + user mapping + grants.
--
-- This script intentionally does NOT create/import foreign tables anymore.
-- Use `foreign_schema_structure.sql` to create one or more FDW schemas (e.g. dwh_remote, dwh_remote2, ...)
-- with the explicit column lists and ETL-required fixes (e.g. Downtime DateTime* as text).
--
-- Example (psql):
--   psql ... -v pg_role=abb_prj_user -v server_name=sqlserver_dwh -v fdw_schema=fdw_sqlserver_dwh ^
--     -v mssql_host=10.0.0.1 -v mssql_port=1433 -v mssql_db=DB_0023_DWH -v mssql_user=sa -v mssql_password=*** ^
--     -f FDW/1_fdw_settings.sql
--   psql ... -v fdw_schema=dwh_remote  -v fdw_server=sqlserver_dwh -v dwh_schema=sp203_an -v grouped_schema=dbo -f FDW/2_foreign_schema_structure.sql
--   psql ... -v fdw_schema=dwh_remote2 -v fdw_server=sqlserver_dwh -v dwh_schema=sp203_an -v grouped_schema=dbo -f FDW/2_foreign_schema_structure.sql
--
-- Recommended: use the SAME schema name in both steps (fdw_schema).
--
-- Example (aligned):
--   psql ... -v pg_role=abb_prj_user -v server_name=sqlserver_dwh -v fdw_schema=dwh_remote2 ^
--     -v mssql_host=10.0.0.1 -v mssql_port=1433 -v mssql_db=DB_0023_DWH -v mssql_user=sa -v mssql_password=*** ^
--     -f FDW/1_fdw_settings.sql
--   psql ... -v fdw_schema=dwh_remote2 -v fdw_server=sqlserver_dwh -v dwh_schema=sp203_an -v grouped_schema=dbo ^
--     -f FDW/2_foreign_schema_structure.sql

-- Required psql variables
\if :{?pg_role}
\else
  \echo 'ERROR: missing required psql variable pg_role (use: -v pg_role=...)'
  \quit 2
\endif
\if :{?server_name}
\else
  \echo 'ERROR: missing required psql variable server_name (use: -v server_name=...)'
  \quit 2
\endif
\if :{?fdw_schema}
\else
  \echo 'ERROR: missing required psql variable fdw_schema (use: -v fdw_schema=...)'
  \quit 2
\endif
\if :{?mssql_host}
\else
  \echo 'ERROR: missing required psql variable mssql_host (use: -v mssql_host=...)'
  \quit 2
\endif
\if :{?mssql_port}
\else
  \echo 'ERROR: missing required psql variable mssql_port (use: -v mssql_port=...)'
  \quit 2
\endif
\if :{?mssql_db}
\else
  \echo 'ERROR: missing required psql variable mssql_db (use: -v mssql_db=...)'
  \quit 2
\endif
\if :{?mssql_user}
\else
  \echo 'ERROR: missing required psql variable mssql_user (use: -v mssql_user=...)'
  \quit 2
\endif
\if :{?mssql_password}
\else
  \echo 'ERROR: missing required psql variable mssql_password (use: -v mssql_password=...)'
  \quit 2
\endif

DO $$
DECLARE
  -- Params (provided via psql variables)
  v_pg_role          name := :'pg_role';          -- ruolo/utente PG a cui dare accesso
  v_server_name      text := :'server_name';      -- nome FOREIGN SERVER in PG
  v_fdw_schema       name := :'fdw_schema';       -- schema locale che conterrà le foreign tables

  v_mssql_host       text := :'mssql_host';
  v_mssql_port       text := :'mssql_port';
  v_mssql_db         text := :'mssql_db';

  v_mssql_user       text := :'mssql_user';
  v_mssql_password   text := :'mssql_password';

  r                  record;

BEGIN
  -- 1) Estensione FDW (una volta per database; schema esplicito per non dipendere dal search_path)
  EXECUTE 'CREATE EXTENSION IF NOT EXISTS tds_fdw WITH SCHEMA public';

  -- 1b) Estensione dblink (usata spesso per logging/connessioni ausiliarie)
  -- Se dblink è già installata in uno schema diverso, la spostiamo in public.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') THEN
    EXECUTE 'CREATE EXTENSION dblink WITH SCHEMA public';
  ELSIF EXISTS (
    SELECT 1
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'dblink' AND n.nspname <> 'public'
  ) THEN
    EXECUTE 'ALTER EXTENSION dblink SET SCHEMA public';
  END IF;

  -- Permetti al ruolo di usare lo schema che ospita le funzioni dblink
  EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', v_pg_role);

  -- Grant EXECUTE su tutte le funzioni dblink* in public al ruolo
  FOR r IN
    SELECT p.oid::regprocedure AS regproc
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'dblink%'
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO %I', r.regproc::text, v_pg_role);
  END LOOP;

  -- 2) Crea FOREIGN SERVER
  EXECUTE format($f$
    CREATE SERVER IF NOT EXISTS %I
    FOREIGN DATA WRAPPER tds_fdw
    OPTIONS (servername %L, port %L, database %L, tds_version %L)
  $f$, v_server_name, v_mssql_host, v_mssql_port, v_mssql_db, '7.4');

  -- Se il server esiste già, CREATE SERVER IF NOT EXISTS non aggiorna le options:
  -- rendiamo lo script idempotente riallineando sempre host/port/database.
  EXECUTE format($f$
    ALTER SERVER %I
    OPTIONS (SET servername %L, SET port %L, SET database %L, SET tds_version %L)
  $f$, v_server_name, v_mssql_host, v_mssql_port, v_mssql_db, '7.4');

  -- 3) Permessi uso FDW + server
  EXECUTE format('GRANT USAGE ON FOREIGN DATA WRAPPER tds_fdw TO %I', v_pg_role);
  EXECUTE format('GRANT USAGE ON FOREIGN SERVER %I TO %I', v_server_name, v_pg_role);

  -- 4) User mapping (credenziali MSSQL)
  EXECUTE format($f$
    CREATE USER MAPPING IF NOT EXISTS FOR %I
    SERVER %I
    OPTIONS (username %L, password %L)
  $f$, v_pg_role, v_server_name, v_mssql_user, v_mssql_password);

  -- 5) Crea schema locale che conterrà le foreign tables
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_fdw_schema);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_fdw_schema, v_pg_role);
  -- Se vuoi permettere anche CREATE dentro lo schema:
  -- EXECUTE format('GRANT CREATE ON SCHEMA %I TO %I', v_fdw_schema, v_pg_role);

END $$;

