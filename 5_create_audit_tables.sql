-- ==============================================================
-- Script: 5_create_audit_tables.sql
-- Purpose: Create empty audit tables for selected source tables
-- Scope:   Single tenant
--
-- Run as:  tenant_<tenantID>_user
-- Target:  Database: dlmo_tenant_<tenantID>_db
--
-- Order:   5 - After 4_create_function_procedure.sql, before 6_create_audit_functions_and_triggers.sql
--
-- Version: 1.0.0
-- Last updated: 2025-01-15
-- Notes:
--   - Hardcodes source_schema = application_data, target_schema = application_audit
--   - Creates au_* tables mirroring selected tables (lk_*, map_*, ass_*, sh_*, ft_%)
-- ==============================================================

DO $$
DECLARE
    rec RECORD;
    audit_table_name TEXT;
    full_source_table TEXT;
    -- Hardcoded schemas for tenant databases
    source_schema TEXT := 'application_data';
    target_schema TEXT := 'application_audit';
BEGIN
    FOR rec IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = source_schema
          AND (
              table_name LIKE 'lk_%' OR
              table_name LIKE 'map_%' OR
              table_name LIKE 'ass_%' OR
              table_name LIKE 'sh_%' OR  -- shift tables
              table_name LIKE 'ft_%'
          )
    LOOP
        audit_table_name := 'au_' || rec.table_name;
        full_source_table := quote_ident(source_schema) || '.' || quote_ident(rec.table_name);

        BEGIN
            EXECUTE format($f$
                CREATE TABLE %I.%I AS
                SELECT 
                    *, 
                    NULL::VARCHAR(1) AS change_type,
                    NULL::TIMESTAMPTZ AS au_operation_ts
                FROM %s
                WHERE false;
            $f$,
                target_schema, audit_table_name,
                full_source_table
            );
        EXCEPTION
            WHEN duplicate_table THEN
                -- Audit table already exists, skip creation
                RAISE NOTICE 'Audit table % already exists in schema %, skipping', audit_table_name, target_schema;
            WHEN OTHERS THEN
                RAISE EXCEPTION 'Error creating audit table % in schema %: %', audit_table_name, target_schema, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE 'Audit tables creation completed successfully for schema %', target_schema;
END;
$$;
