-- ==============================================================
-- Script: 6_create_audit_functions_and_triggers.sql
-- Purpose: Create audit functions and triggers for selected tables
-- Scope:   Single tenant
--
-- Run as:  tenant_<tenantID>_user
-- Target:  Database: dlmo_tenant_<tenantID>_db
--
-- Order:   6 - After 5_create_audit_tables.sql, before 7_insert_default_data.sql
--
-- Version: 1.0.0
-- Last updated: 2025-01-15
-- Notes:
--   - Hardcodes source_schema = application_data, target_schema = application_audit
--   - Creates fn_audit_* functions and tr_audit_* triggers on lk_*, map_*, ass_*, sh_*, ft_% tables
-- ==============================================================

DO $$
DECLARE
    rec RECORD;
    table_name TEXT;
    audit_table_name TEXT;
    fn_name TEXT;
    trigger_name TEXT;
    full_table TEXT;
    -- Hardcoded schemas for tenant databases
    source_schema TEXT := 'application_data';
    target_schema TEXT := 'application_audit';
BEGIN
FOR rec IN
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = source_schema
      AND (
          t.table_name LIKE 'lk_%' OR
          t.table_name LIKE 'map_%' OR
          t.table_name LIKE 'ass_%' OR
          t.table_name LIKE 'sh_%' OR
          t.table_name LIKE 'ft_%'
      )
LOOP
    table_name := rec.table_name;
    audit_table_name := 'au_' || table_name;
    fn_name := 'fn_audit_' || table_name;
    trigger_name := 'tr_audit_' || table_name;
    full_table := quote_ident(source_schema) || '.' || quote_ident(table_name);

    BEGIN
        EXECUTE format('
            CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger LANGUAGE plpgsql AS $f$
            BEGIN
                IF TG_OP = ''INSERT'' THEN
                    INSERT INTO %I.%I SELECT NEW.*, ''I'', timezone(''UTC'', current_timestamp);
                    RETURN NEW;
                ELSIF TG_OP = ''UPDATE'' THEN
                    INSERT INTO %I.%I SELECT OLD.*, ''U'', timezone(''UTC'', current_timestamp);
                    RETURN NEW;
                ELSIF TG_OP = ''DELETE'' THEN
                    INSERT INTO %I.%I SELECT OLD.*, ''D'', timezone(''UTC'', current_timestamp);
                    RETURN OLD;
                END IF;
                RETURN NULL;
            END;
            $f$;',
            source_schema, fn_name,
            target_schema, audit_table_name,
            target_schema, audit_table_name,
            target_schema, audit_table_name
        );

        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s;', trigger_name, full_table);

        EXECUTE format('
            CREATE TRIGGER %I
            AFTER INSERT OR UPDATE OR DELETE ON %s
            FOR EACH ROW
            EXECUTE FUNCTION %I.%I();',
            trigger_name, full_table, source_schema, fn_name);

        --RAISE NOTICE '✔️ Created trigger % and function % for table %', trigger_name, fn_name, full_table;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Error creating audit function/trigger for table %: %', full_table, SQLERRM;
    END;
END LOOP;

RAISE NOTICE 'Audit trigger e funzioni creati correttamente per lo schema %', source_schema;
END;
$$;
