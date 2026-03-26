-- ==============================================================
-- Script: 4_create_function_procedure.sql
-- Purpose: Create PL/pgSQL functions, procedures and triggers for a tenant
-- Scope:   Single tenant
--
-- Run as:  tenant_<tenantID>_user
-- Target:  Database: dlmo_tenant_<tenantID>_db
--
-- Order:   4 - After 3_create_view.sql, before 5_create_audit_tables.sql
--
-- Version: 1.1.0
-- Last updated: 2025-01-22
-- Notes:
--   - Creates procedural logic in schemas (primarily application_data)
--   - Some functions may depend on tables and views from scripts 2 and 3
--   - Modified store procedure due to issue https://decisyon.atlassian.net/browse/DLMOV2-322. The CREATE PROCEDURE application_data.manage_lk_plant now execute the setup_new_plant_partitions function. in the INSERT flow
-- ==============================================================
-- DROP FUNCTION application_data.calculate_total_roles(int8, int8, int8, int4);

CREATE OR REPLACE FUNCTION application_data.calculate_total_roles(p_plant_id bigint, p_tier_id bigint, p_module_id bigint,p_line_id bigint, p_day_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    total_roles INT;
BEGIN
    -- Calcolo il totale dei ruoli, escludendo status_id 400 e 500
    SELECT COUNT(fa.attendance_role_id)
    INTO total_roles
    FROM application_data.ft_attendance fa -- alias fa per la tabella
    WHERE fa.plant_id = p_plant_id
      AND fa.tier_id = p_tier_id
      AND fa.module_id = p_module_id
      AND fa.day_id = p_day_id
	  AND fa.line_id = p_line_id
      AND fa.status_id IN (SELECT at_status_id FROM application_data.lk_attendance_status where at_status_code not in  ('(U)','ABSENT', 'NOT_REQUIRED') );
    
    -- Ritorno il risultato
    RETURN total_roles;
END;
$function$
;

-- DROP FUNCTION application_data.create_future_partitions(int8,text)

CREATE OR REPLACE PROCEDURE application_data.create_future_partitions(
    p_user_id bigint, 
    p_user_fullname character varying
)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    -- Variabile nome procedura
    lp_procedure_name VARCHAR(100) := 'application_data.create_future_partitions';
    
    -- Variabile caller
    lp_operation_caller TEXT;

    -- 🧠 ROOT TABLE DISCOVERY CURSOR
    -- Trova direttamente le tabelle ROOT (partizionate per LISTA) nello schema.
    -- Non dipende dai figli esistenti.
    target_tables_cursor CURSOR FOR
        SELECT 
            c.relname::TEXT AS table_name
        FROM pg_partitioned_table pt
        JOIN pg_class c ON pt.partrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'application_data'
          AND c.relname LIKE 'ft_%'
          AND pt.partstrat = 'l'; -- Cerchiamo le tabelle partizionate per LISTA (i Padri)

    table_rec       RECORD;
    plant           RECORD;
    local_now       TIMESTAMPTZ;   
    local_time      TIME;
    base_month      DATE;          
    target_year     INT;
    target_month    INT;
    msg             TEXT;
    month_offset    INT;
    
    -- Variabile per la colonna range dedotta
    v_range_column  TEXT;
BEGIN
    -- Initialize caller
    lp_operation_caller := COALESCE(p_user_id::TEXT, 'Unknown') || ' -- ' || COALESCE(p_user_fullname, 'Unknown');

    -- Loop active plants
    FOR plant IN
        SELECT plant_id, plant_timezone, plant_code 
        FROM application_data.lk_plant
        WHERE plant_id IS NOT NULL 
          AND is_active = TRUE 
    LOOP
        local_now := now() AT TIME ZONE plant.plant_timezone;
        local_time := local_now::TIME;

        -- Time Gate: 00:00 - 00:59 local time
        IF local_time BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN

            base_month := (date_trunc('month', local_now))::date;

            -- Loop Month Offset (0 = Current, 1 = Next)
            FOR month_offset IN 0..1 LOOP
                
                target_year  := EXTRACT(YEAR  FROM (base_month + make_interval(months => month_offset)));
                target_month := EXTRACT(MONTH FROM (base_month + make_interval(months => month_offset)));

                -- Loop Tables (Metadata Discovery)
                FOR table_rec IN target_tables_cursor LOOP
                    
                    -- 🕵️ DETECT RANGE COLUMN STRATEGY
                    -- Controlliamo se la tabella padre ha la colonna 'target_date_iso' o 'day_id'
                    SELECT column_name INTO v_range_column
                    FROM information_schema.columns 
                    WHERE table_schema = 'application_data'
                      AND table_name = table_rec.table_name
                      AND column_name IN ('target_date_iso', 'day_id')
                    ORDER BY 
                        CASE column_name 
                            WHEN 'target_date_iso' THEN 1  -- Priorità alta
                            WHEN 'day_id' THEN 2           -- Priorità bassa
                        END
                    LIMIT 1;

                    -- Se non troviamo nessuna delle due colonne, saltiamo la tabella (o logghiamo errore)
                    IF v_range_column IS NULL THEN
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', CURRENT_TIMESTAMP),
                            lp_procedure_name,
                            'Skipping table ' || table_rec.table_name || ': No suitable range column (day_id/target_date_iso) found.',
                            lp_operation_caller
                        );
                        CONTINUE;
                    END IF;

                    BEGIN
                        -- Call helper function using the DISCOVERED table and column
                        PERFORM application_data.create_monthly_partition(
                            table_rec.table_name,   
                            v_range_column,         -- Colonna dedotta automaticamente
                            plant.plant_id,         
                            target_year,            
                            target_month       
                        );

                        -- Prepare Success Message
                        msg := format(
                            'Created monthly partition for table "%s" (key: %s), plant_id %s, timezone "%s", month %s-%s',
                            table_rec.table_name, 
                            v_range_column, 
                            plant.plant_id::TEXT, 
                            plant.plant_timezone, 
                            target_year::TEXT, 
                            target_month::TEXT
                        );

                        -- LOG SUCCESS
                        INSERT INTO application_data.log_operation (
                            operation_timestamp,
                            operation_src,
                            operation_msg,
                            operation_caller
                        ) VALUES (
                            timezone('UTC', CURRENT_TIMESTAMP),
                            lp_procedure_name,
                            msg,
                            lp_operation_caller
                        );

                        RAISE NOTICE '%', msg;

                    EXCEPTION
                        -- Ignore existing partitions
                        WHEN SQLSTATE '42P07' THEN
                            NULL; 
                            
                        WHEN OTHERS THEN
                            -- Error Message
                            msg := format(
                                'ERROR creating partition for table "%s", plant_id %s, month %s-%s: %s',
                                table_rec.table_name, 
                                plant.plant_id::TEXT, 
                                target_year::TEXT, 
                                target_month::TEXT, 
                                SQLERRM
                            );
                            
                            -- LOG ERROR
                            INSERT INTO application_data.log_error (
                                error_timestamp,
                                error_src,
                                error_msg,
                                error_caller
                            ) VALUES (
                                timezone('UTC', CURRENT_TIMESTAMP),
                                lp_procedure_name,
                                msg,
                                lp_operation_caller
                            );
                    END;

                END LOOP; -- Tables
            END LOOP; -- Months
        
        ELSE
            -- ⛔️ ELSE BRANCH: Skipped due to time window
            msg := format(
                'Skipped check for future MONTHLY partitions for Plant "%s" (ID: %s). Local Time (%s) is outside 00:00-00:59 window (TZ: %s).',
                COALESCE(plant.plant_code, 'N/A'),
                plant.plant_id::TEXT,
                local_time::TEXT,
                plant.plant_timezone
            );

            INSERT INTO application_data.log_operation (
                operation_timestamp,
                operation_src,
                operation_msg,
                operation_caller
            ) VALUES (
                timezone('UTC', CURRENT_TIMESTAMP),
                lp_procedure_name,
                msg,
                lp_operation_caller
            );
            
            RAISE NOTICE '%', msg;

        END IF; -- End Time Gate

    END LOOP; -- Plants
END;
$procedure$;

CREATE OR REPLACE PROCEDURE application_data.populate_ft_oee(
    IN p_date_min date DEFAULT NULL::date,
    IN p_date_max date DEFAULT NULL::date,
    IN p_plant_id bigint DEFAULT NULL::bigint,
    IN p_line_id bigint DEFAULT NULL::bigint,
    IN p_user_id bigint DEFAULT NULL::bigint,
    IN p_user_fullname character varying DEFAULT NULL::character varying
)
LANGUAGE plpgsql
AS $procedure$
/*
Purpose:
  Populate OEE support tables (ft_oee_shift, ft_oee) and update OEE KPI in ft_kpi_target.
  Calculation is daily (with shift detail support) and handles both scheduled mode and manual backfill mode.

How to call:
  1) Scheduled execution (process yesterday in plant local timezone, only during 00:00-00:59):
     CALL application_data.populate_ft_oee(NULL, NULL, NULL, NULL, 1, 'ETL Scheduler');
  2) Manual single-day recalculation for one line:
     CALL application_data.populate_ft_oee('2026-02-18', '2026-02-18', 100, 600, 1, 'Manual Backfill');
  3) Manual range recalculation for one plant/all lines:
     CALL application_data.populate_ft_oee('2026-02-11', '2026-02-18', 100, NULL, 1, 'Manual Backfill');
*/
DECLARE
    lp_step                 NUMERIC := 0;
    lp_procedure_name       TEXT := 'application_data.populate_ft_oee';
    lp_last_user            TEXT;
    lp_err_msg              TEXT;

    v_plant_rec             RECORD;
    v_line_rec              RECORD;
    v_plant_timezone        TEXT;
    v_local_time            TIME;
    v_date_min              DATE;
    v_date_max              DATE;
    v_day_id_min            NUMERIC(8);
    v_day_id_max            NUMERIC(8);
    v_yesterday_local       DATE;

    v_month_cursor          DATE;
    v_month_end             DATE;
    v_year                  INT;
    v_month                 INT;

    v_rows_deleted_shift    BIGINT := 0;
    v_rows_deleted_day      BIGINT := 0;
    v_rows_inserted_shift   BIGINT := 0;
    v_rows_inserted_day     BIGINT := 0;
    v_rows_updated_kpi      BIGINT := 0;
    v_oee_kpi_id            BIGINT;
    v_missing_threshold_count INT := 0;
    v_not_exceeded_count      INT := 0;
    v_passing_days            NUMERIC(8)[];
    v_passing_lines           BIGINT[];
    v_missing_days            NUMERIC(8)[];
    v_missing_lines           BIGINT[];
    v_missing_prods           BIGINT[];
    v_failing_days            NUMERIC(8)[];
    v_failing_lines           BIGINT[];
    v_failing_prods           BIGINT[];
    v_failing_thresholds      NUMERIC(18,6)[];
BEGIN
    lp_step := 0;

    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID and Fullname cannot be NULL.';
    END IF;
    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: p_date_min=' || COALESCE(p_date_min::TEXT, 'NULL') ||
        ', p_date_max=' || COALESCE(p_date_max::TEXT, 'NULL') ||
        ', p_plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', p_line_id=' || COALESCE(p_line_id::TEXT, 'NULL'),
        lp_last_user
    );

    lp_step := 1;
    FOR v_plant_rec IN
        SELECT plant_id, plant_code, plant_timezone
        FROM application_data.lk_plant
        WHERE is_active = TRUE
          AND is_deleted = FALSE
          AND (p_plant_id IS NULL OR plant_id = p_plant_id)
        ORDER BY plant_id
    LOOP
        v_plant_timezone := NULLIF(btrim(v_plant_rec.plant_timezone), '');
        IF v_plant_timezone IS NULL THEN
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'SKIP plant ' || COALESCE(btrim(v_plant_rec.plant_code), '?') ||
                ' (ID=' || v_plant_rec.plant_id::TEXT || '): missing plant_timezone in lk_plant.',
                lp_last_user
            );
            CONTINUE;
        END IF;

        -- Scheduled mode: timezone gate + yesterday local. Manual mode: explicit date/range.
        IF p_date_min IS NULL AND p_date_max IS NULL THEN
            SELECT (NOW() AT TIME ZONE v_plant_timezone)::TIME
            INTO v_local_time;

            IF v_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'SKIP plant ' || COALESCE(btrim(v_plant_rec.plant_code), '?') ||
                    ' (ID=' || v_plant_rec.plant_id::TEXT || '): local time ' || COALESCE(v_local_time::TEXT, '?') ||
                    ' (TZ=' || v_plant_timezone || ') is outside 00:00-00:59 window.',
                    lp_last_user
                );
                CONTINUE;
            END IF;

            v_yesterday_local := (timezone(v_plant_timezone, current_timestamp)::DATE - 1);
            v_date_min := v_yesterday_local;
            v_date_max := v_yesterday_local;
        ELSE
            v_date_min := COALESCE(p_date_min, p_date_max);
            v_date_max := p_date_max;
        END IF;

        IF v_date_min IS NULL THEN
            RAISE EXCEPTION 'Both p_date_min and p_date_max are NULL in manual mode.';
        END IF;

        v_day_id_min := to_char(v_date_min, 'YYYYMMDD')::NUMERIC(8);
        v_day_id_max := CASE
            WHEN v_date_max IS NULL THEN NULL
            ELSE to_char(v_date_max, 'YYYYMMDD')::NUMERIC(8)
        END;

        lp_step := 2;
        -- Ensure partitions exist for OEE support tables and KPI table.
        BEGIN
            PERFORM application_data.create_plant_partition('ft_oee_shift', 'day_id', v_plant_rec.plant_id);
        EXCEPTION WHEN OTHERS THEN
            IF SQLSTATE IN ('42P07', 'P0001') THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant partition ft_oee_shift_plant_' || v_plant_rec.plant_id::TEXT || ' already exists, continuing.',
                    lp_last_user
                );
            ELSE
                CALL application_data.log_error_write(
                    lp_procedure_name,
                    'create_plant_partition(ft_oee_shift) failed for plant_id=' || v_plant_rec.plant_id::TEXT || ': ' || SQLERRM,
                    lp_last_user
                );
            END IF;
        END;

        BEGIN
            PERFORM application_data.create_plant_partition('ft_oee', 'day_id', v_plant_rec.plant_id);
        EXCEPTION WHEN OTHERS THEN
            IF SQLSTATE IN ('42P07', 'P0001') THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant partition ft_oee_plant_' || v_plant_rec.plant_id::TEXT || ' already exists, continuing.',
                    lp_last_user
                );
            ELSE
                CALL application_data.log_error_write(
                    lp_procedure_name,
                    'create_plant_partition(ft_oee) failed for plant_id=' || v_plant_rec.plant_id::TEXT || ': ' || SQLERRM,
                    lp_last_user
                );
            END IF;
        END;

        BEGIN
            PERFORM application_data.create_plant_partition('ft_kpi_target', 'target_date_iso', v_plant_rec.plant_id);
        EXCEPTION WHEN OTHERS THEN
            IF SQLSTATE IN ('42P07', 'P0001') THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant partition ft_kpi_target_plant_' || v_plant_rec.plant_id::TEXT || ' already exists, continuing.',
                    lp_last_user
                );
            ELSE
                CALL application_data.log_error_write(
                    lp_procedure_name,
                    'create_plant_partition(ft_kpi_target) failed for plant_id=' || v_plant_rec.plant_id::TEXT || ': ' || SQLERRM,
                    lp_last_user
                );
            END IF;
        END;

        v_month_cursor := date_trunc('month', v_date_min)::DATE;
        v_month_end := date_trunc('month', COALESCE(v_date_max, v_date_min))::DATE;
        WHILE v_month_cursor <= v_month_end LOOP
            v_year := EXTRACT(YEAR FROM v_month_cursor)::INT;
            v_month := EXTRACT(MONTH FROM v_month_cursor)::INT;

            BEGIN
                PERFORM application_data.create_monthly_partition('ft_oee_shift', 'day_id', v_plant_rec.plant_id, v_year, v_month);
            EXCEPTION WHEN OTHERS THEN
                IF SQLSTATE IN ('42P07', 'P0001') THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Monthly partition ft_oee_shift_plant_' || v_plant_rec.plant_id::TEXT || '_' ||
                        v_year::TEXT || lpad(v_month::TEXT, 2, '0') || ' already exists, continuing.',
                        lp_last_user
                    );
                ELSE
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_monthly_partition(ft_oee_shift) failed for plant_id=' || v_plant_rec.plant_id::TEXT ||
                        ', ' || v_year::TEXT || '-' || lpad(v_month::TEXT, 2, '0') || ': ' || SQLERRM,
                        lp_last_user
                    );
                END IF;
            END;

            BEGIN
                PERFORM application_data.create_monthly_partition('ft_oee', 'day_id', v_plant_rec.plant_id, v_year, v_month);
            EXCEPTION WHEN OTHERS THEN
                IF SQLSTATE IN ('42P07', 'P0001') THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Monthly partition ft_oee_plant_' || v_plant_rec.plant_id::TEXT || '_' ||
                        v_year::TEXT || lpad(v_month::TEXT, 2, '0') || ' already exists, continuing.',
                        lp_last_user
                    );
                ELSE
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_monthly_partition(ft_oee) failed for plant_id=' || v_plant_rec.plant_id::TEXT ||
                        ', ' || v_year::TEXT || '-' || lpad(v_month::TEXT, 2, '0') || ': ' || SQLERRM,
                        lp_last_user
                    );
                END IF;
            END;

            BEGIN
                PERFORM application_data.create_monthly_partition('ft_kpi_target', 'target_date_iso', v_plant_rec.plant_id, v_year, v_month);
            EXCEPTION WHEN OTHERS THEN
                IF SQLSTATE IN ('42P07', 'P0001') THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Monthly partition ft_kpi_target_plant_' || v_plant_rec.plant_id::TEXT || '_' ||
                        v_year::TEXT || lpad(v_month::TEXT, 2, '0') || ' already exists, continuing.',
                        lp_last_user
                    );
                ELSE
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_monthly_partition(ft_kpi_target) failed for plant_id=' || v_plant_rec.plant_id::TEXT ||
                        ', ' || v_year::TEXT || '-' || lpad(v_month::TEXT, 2, '0') || ': ' || SQLERRM,
                        lp_last_user
                    );
                END IF;
            END;

            v_month_cursor := (v_month_cursor + INTERVAL '1 month')::DATE;
        END LOOP;

        ------------------------------------------------------------------
        -- STEP 2.8: OEE threshold check (lk_threshold)
        -- Run OEE calculations only for day/line where total_production > threshold
        -- for KPI code 'OEE'. Missing threshold or not exceeded -> skip and log.
        ------------------------------------------------------------------
        lp_step := 2.8;
        SELECT k.kpi_id
        INTO v_oee_kpi_id
        FROM application_data.lk_kpi k
        WHERE k.plant_id = v_plant_rec.plant_id
          AND k.kpi_code = 'OEE'
          AND k.is_deleted = FALSE;

        WITH threshold_status AS (
            SELECT
                fr.day_id,
                fr.line_id,
                SUM(fr.total_production)::BIGINT AS total_prod,
                (
                    SELECT t.threshold_value
                    FROM application_data.lk_threshold t
                    WHERE t.plant_id = v_plant_rec.plant_id
                      AND t.line_id = fr.line_id
                      AND t.kpi_id = v_oee_kpi_id
                      AND t.is_deleted = FALSE
                      AND t.is_active = TRUE
                      AND t.start_date_local::DATE <= to_date(fr.day_id::TEXT, 'YYYYMMDD')
                      AND (t.end_date_local IS NULL OR t.end_date_local::DATE >= to_date(fr.day_id::TEXT, 'YYYYMMDD'))
                    ORDER BY t.start_date_local DESC
                    LIMIT 1
                ) AS threshold_value
            FROM application_data.ft_rawdata fr
            WHERE fr.plant_id = v_plant_rec.plant_id
              AND fr.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR fr.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR fr.line_id = p_line_id)
            GROUP BY fr.day_id, fr.line_id
        )
        SELECT
            COALESCE(array_agg(day_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod > threshold_value), '{}'),
            COALESCE(array_agg(line_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod > threshold_value), '{}'),
            COALESCE(array_agg(day_id) FILTER (WHERE threshold_value IS NULL), '{}'),
            COALESCE(array_agg(line_id) FILTER (WHERE threshold_value IS NULL), '{}'),
            COALESCE(array_agg(total_prod) FILTER (WHERE threshold_value IS NULL), '{}'),
            COALESCE(array_agg(day_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}'),
            COALESCE(array_agg(line_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}'),
            COALESCE(array_agg(total_prod) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}'),
            COALESCE(array_agg(threshold_value) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}')
        INTO
            v_passing_days, v_passing_lines,
            v_missing_days, v_missing_lines, v_missing_prods,
            v_failing_days, v_failing_lines, v_failing_prods, v_failing_thresholds
        FROM threshold_status;

        v_missing_threshold_count := 0;
        IF array_length(v_missing_days, 1) > 0 THEN
            FOR i IN 1..array_length(v_missing_days, 1) LOOP
                v_missing_threshold_count := v_missing_threshold_count + 1;
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'OEE threshold missing: no active lk_threshold row found for plant_id=' || v_plant_rec.plant_id::TEXT ||
                    ', line_id=' || v_missing_lines[i]::TEXT ||
                    ', day_id=' || v_missing_days[i]::TEXT ||
                    '. total_production=' || v_missing_prods[i]::TEXT ||
                    '. OEE calculation skipped for this day/line.',
                    lp_last_user
                );
            END LOOP;
        END IF;

        v_not_exceeded_count := 0;
        IF array_length(v_failing_days, 1) > 0 THEN
            FOR i IN 1..array_length(v_failing_days, 1) LOOP
                v_not_exceeded_count := v_not_exceeded_count + 1;
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'OEE threshold not exceeded: total_production=' || v_failing_prods[i]::TEXT ||
                    ', threshold=' || v_failing_thresholds[i]::TEXT ||
                    ' for plant_id=' || v_plant_rec.plant_id::TEXT ||
                    ', line_id=' || v_failing_lines[i]::TEXT ||
                    ', day_id=' || v_failing_days[i]::TEXT ||
                    '. OEE calculation skipped for this day/line.',
                    lp_last_user
                );
            END LOOP;
        END IF;

        lp_step := 3;
        DELETE FROM application_data.ft_oee_shift s
        WHERE s.plant_id = v_plant_rec.plant_id
          AND s.day_id >= v_day_id_min
          AND (v_day_id_max IS NULL OR s.day_id <= v_day_id_max)
          AND (p_line_id IS NULL OR s.line_id = p_line_id)
          AND EXISTS (
              SELECT 1
              FROM unnest(v_passing_days, v_passing_lines) AS t(d, l)
              WHERE t.d = s.day_id AND t.l = s.line_id
          );
        GET DIAGNOSTICS v_rows_deleted_shift = ROW_COUNT;

        DELETE FROM application_data.ft_oee d
        WHERE d.plant_id = v_plant_rec.plant_id
          AND d.day_id >= v_day_id_min
          AND (v_day_id_max IS NULL OR d.day_id <= v_day_id_max)
          AND (p_line_id IS NULL OR d.line_id = p_line_id)
          AND EXISTS (
              SELECT 1
              FROM unnest(v_passing_days, v_passing_lines) AS t(dy, l)
              WHERE t.dy = d.day_id AND t.l = d.line_id
          );
        GET DIAGNOSTICS v_rows_deleted_day = ROW_COUNT;

        lp_step := 4;
        INSERT INTO application_data.ft_oee_shift (
            plant_id, line_id, day_id, production_date, shift_dwh_id,
            source_step_id, machine_id, component_id,
            ideal_cycle_time_ms, parallel_component_count_step, effective_step_cycle_time_ms,
            shift_working_duration_sec,
            good_first_pass, total_pcs,
            ideal_production_machine, ideal_production_step, oee_component,
            calc_ts, calc_caller
        )
        WITH raw_base AS (
            SELECT
                fr.plant_id,
                fr.line_id,
                fr.day_id::NUMERIC(8) AS day_id,
                fr.shift_dwh_id,
                fr.source_step_id,
                fr.machine_id,
                fr.component_id,
                fr.pass_number,
                COALESCE(fr.total_production, 0)::BIGINT AS total_production,
                COALESCE(lr.is_good, FALSE) AS is_good
            FROM application_data.ft_rawdata fr
            JOIN application_data.lk_result lr
              ON lr.result_id = fr.result_id
             AND lr.plant_id = fr.plant_id
             AND lr.line_id = fr.line_id
            WHERE fr.plant_id = v_plant_rec.plant_id
              AND fr.result_id IS NOT NULL
              AND fr.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR fr.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR fr.line_id = p_line_id)
              AND EXISTS (
                  SELECT 1
                  FROM unnest(v_passing_days, v_passing_lines) AS t(d, l)
                  WHERE t.d = fr.day_id AND t.l = fr.line_id
              )
        ),
        shift_agg AS (
            SELECT
                rb.plant_id, rb.line_id, rb.day_id, rb.shift_dwh_id, rb.source_step_id, rb.machine_id, rb.component_id,
                SUM(CASE WHEN rb.pass_number = 0 AND rb.is_good THEN rb.total_production ELSE 0 END)::BIGINT AS good_first_pass,
                SUM(rb.total_production)::BIGINT AS total_pcs
            FROM raw_base rb
            GROUP BY rb.plant_id, rb.line_id, rb.day_id, rb.shift_dwh_id, rb.source_step_id, rb.machine_id, rb.component_id
        ),
        step_capacity AS (
            SELECT
                sa.plant_id,
                sa.line_id,
                sa.day_id,
                sa.shift_dwh_id,
                sa.machine_id,
                COUNT(DISTINCT sa.component_id)::INT AS parallel_component_count_step,
                SUM(
                    CASE
                        WHEN c.ideal_cycle_time_ms > 0
                            THEN (27000::NUMERIC * 1000::NUMERIC) / c.ideal_cycle_time_ms::NUMERIC
                        ELSE 0::NUMERIC
                    END
                )::NUMERIC(18,3) AS ideal_production_step
            FROM shift_agg sa
            LEFT JOIN application_data.lk_component c
                   ON c.plant_id = sa.plant_id
                  AND c.line_id = sa.line_id
                  AND c.component_id = sa.component_id
                  AND c.machine_id = sa.machine_id
                  AND c.is_deleted = FALSE
                  AND c.is_active = TRUE
            GROUP BY sa.plant_id, sa.line_id, sa.day_id, sa.shift_dwh_id, sa.machine_id
        )
        SELECT
            sa.plant_id,
            sa.line_id,
            sa.day_id,
            to_date(sa.day_id::TEXT, 'YYYYMMDD') AS production_date,
            sa.shift_dwh_id,
            sa.source_step_id,
            sa.machine_id,
            sa.component_id,
            c.ideal_cycle_time_ms,
            sc.parallel_component_count_step,
            CASE
                WHEN sc.ideal_production_step > 0
                    THEN round((27000::NUMERIC * 1000::NUMERIC) / sc.ideal_production_step::NUMERIC, 3)
                ELSE NULL
            END AS effective_step_cycle_time_ms,
            27000::NUMERIC(20,5) AS shift_working_duration_sec,
            sa.good_first_pass,
            sa.total_pcs,
            CASE
                WHEN c.ideal_cycle_time_ms > 0
                    THEN round((27000::NUMERIC * 1000::NUMERIC) / c.ideal_cycle_time_ms::NUMERIC, 3)
                ELSE NULL
            END AS ideal_production_machine,
            CASE
                WHEN sc.ideal_production_step > 0
                    THEN sc.ideal_production_step
                ELSE NULL
            END AS ideal_production_step,
            CASE
                WHEN c.ideal_cycle_time_ms > 0
                    THEN round(
                        (sa.good_first_pass::NUMERIC /
                        NULLIF(((27000::NUMERIC * 1000::NUMERIC) / c.ideal_cycle_time_ms::NUMERIC), 0)) * 100::NUMERIC,
                        6
                    )
                ELSE NULL
            END AS oee_component,
            timezone('UTC', current_timestamp),
            lp_last_user
        FROM shift_agg sa
        LEFT JOIN application_data.lk_component c
               ON c.plant_id = sa.plant_id
              AND c.component_id = sa.component_id
              AND c.machine_id = sa.machine_id
              AND c.is_deleted = FALSE
        LEFT JOIN step_capacity sc
               ON sc.plant_id = sa.plant_id
              AND sc.line_id = sa.line_id
              AND sc.day_id = sa.day_id
              AND sc.shift_dwh_id = sa.shift_dwh_id
              AND sc.machine_id = sa.machine_id;
        GET DIAGNOSTICS v_rows_inserted_shift = ROW_COUNT;

        lp_step := 5;
        INSERT INTO application_data.ft_oee (
            plant_id, line_id, day_id, production_date, shift_count, observed_duration_sec,
            source_step_id, machine_id, machine_code, component_id, component_code,
            is_end_step, parallel_component_count_step, ideal_cycle_time_ms, effective_step_cycle_time_ms,
            good_first_pass, total_pcs, ideal_production_machine, ideal_production_step, oee_component,
            line_output_good, line_capacity_ideal, is_bottleneck_step,
            calc_ts, calc_caller
        )
        WITH shift_count AS (
            SELECT
                s.plant_id, s.line_id, s.day_id,
                COUNT(DISTINCT s.shift_dwh_id)::INT AS shift_count
            FROM application_data.ft_oee_shift s
            WHERE s.plant_id = v_plant_rec.plant_id
              AND s.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR s.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR s.line_id = p_line_id)
            GROUP BY s.plant_id, s.line_id, s.day_id
        ),
        day_component AS (
            SELECT
                s.plant_id, s.line_id, s.day_id, MIN(s.source_step_id)::INT AS source_step_id, s.machine_id, s.component_id,
                SUM(s.good_first_pass)::BIGINT AS good_first_pass,
                SUM(s.total_pcs)::BIGINT AS total_pcs,
                SUM(COALESCE(s.ideal_production_machine, 0))::NUMERIC(18,3) AS ideal_production_machine,
                SUM(COALESCE(s.ideal_production_step, 0))::NUMERIC(18,3) AS ideal_production_step,
                MAX(s.parallel_component_count_step)::INT AS parallel_component_count_step,
                MAX(s.ideal_cycle_time_ms)::INT AS ideal_cycle_time_ms,
                MAX(s.effective_step_cycle_time_ms)::NUMERIC(18,3) AS effective_step_cycle_time_ms
            FROM application_data.ft_oee_shift s
            WHERE s.plant_id = v_plant_rec.plant_id
              AND s.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR s.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR s.line_id = p_line_id)
            GROUP BY s.plant_id, s.line_id, s.day_id, s.machine_id, s.component_id
        ),
        step_cycle AS (
            SELECT
                dc.plant_id, dc.line_id, dc.day_id, dc.machine_id,
                MAX(dc.effective_step_cycle_time_ms) AS step_effective_cycle_time_ms
            FROM day_component dc
            GROUP BY dc.plant_id, dc.line_id, dc.day_id, dc.machine_id
        ),
        bottleneck AS (
            SELECT DISTINCT ON (sc.plant_id, sc.line_id, sc.day_id)
                sc.plant_id, sc.line_id, sc.day_id, sc.machine_id, sc.step_effective_cycle_time_ms
            FROM step_cycle sc
            WHERE sc.step_effective_cycle_time_ms IS NOT NULL
              AND sc.step_effective_cycle_time_ms > 0
            ORDER BY sc.plant_id, sc.line_id, sc.day_id, sc.step_effective_cycle_time_ms DESC, sc.machine_id
        ),
        end_output AS (
            SELECT DISTINCT ON (e.plant_id, e.line_id, e.day_id)
                e.plant_id,
                e.line_id,
                e.day_id,
                e.good_first_pass AS line_output_good
            FROM (
                SELECT
                    dc.plant_id,
                    dc.line_id,
                    dc.day_id,
                    dc.machine_id,
                    SUM(dc.good_first_pass)::BIGINT AS good_first_pass,
                    SUM(dc.total_pcs)::BIGINT AS total_pcs,
                    MAX(m.machine_sort)::INT AS machine_sort
                FROM day_component dc
                JOIN application_data.lk_machine m
                  ON m.plant_id = dc.plant_id
                 AND m.line_id = dc.line_id
                 AND m.machine_id = dc.machine_id
                 AND m.is_deleted = FALSE
                 AND m.is_end_step = TRUE
                GROUP BY dc.plant_id, dc.line_id, dc.day_id, dc.machine_id
            ) e
            ORDER BY
                e.plant_id,
                e.line_id,
                e.day_id,
                e.good_first_pass DESC,
                e.total_pcs DESC,
                e.machine_sort DESC NULLS LAST,
                e.machine_id
        )
        SELECT
            dc.plant_id,
            dc.line_id,
            dc.day_id,
            to_date(dc.day_id::TEXT, 'YYYYMMDD') AS production_date,
            COALESCE(sc.shift_count, 0) AS shift_count,
            (COALESCE(sc.shift_count, 0)::NUMERIC * 27000::NUMERIC)::NUMERIC(20,5) AS observed_duration_sec,
            dc.source_step_id,
            dc.machine_id,
            m.machine_code,
            dc.component_id,
            c.component_code,
            COALESCE(m.is_end_step, FALSE) AS is_end_step,
            dc.parallel_component_count_step,
            dc.ideal_cycle_time_ms,
            dc.effective_step_cycle_time_ms,
            dc.good_first_pass,
            dc.total_pcs,
            dc.ideal_production_machine,
            dc.ideal_production_step,
            CASE
                WHEN dc.ideal_production_machine > 0
                    THEN round((dc.good_first_pass::NUMERIC / dc.ideal_production_machine) * 100::NUMERIC, 6)
                ELSE NULL
            END AS oee_component,
            eo.line_output_good,
            CASE
                WHEN b.step_effective_cycle_time_ms > 0
                    THEN round(((COALESCE(sc.shift_count, 0)::NUMERIC * 27000::NUMERIC * 1000::NUMERIC) /
                               b.step_effective_cycle_time_ms), 3)
                ELSE NULL
            END AS line_capacity_ideal,
            (dc.machine_id = b.machine_id) AS is_bottleneck_step,
            timezone('UTC', current_timestamp),
            lp_last_user
        FROM day_component dc
        LEFT JOIN shift_count sc
               ON sc.plant_id = dc.plant_id
              AND sc.line_id = dc.line_id
              AND sc.day_id = dc.day_id
        LEFT JOIN bottleneck b
               ON b.plant_id = dc.plant_id
              AND b.line_id = dc.line_id
              AND b.day_id = dc.day_id
        LEFT JOIN end_output eo
               ON eo.plant_id = dc.plant_id
              AND eo.line_id = dc.line_id
              AND eo.day_id = dc.day_id
        LEFT JOIN application_data.lk_machine m
               ON m.plant_id = dc.plant_id
              AND m.line_id = dc.line_id
              AND m.machine_id = dc.machine_id
              AND m.is_deleted = FALSE
        LEFT JOIN application_data.lk_component c
               ON c.plant_id = dc.plant_id
              AND c.machine_id = dc.machine_id
              AND c.component_id = dc.component_id
              AND c.is_deleted = FALSE;
        GET DIAGNOSTICS v_rows_inserted_day = ROW_COUNT;

        lp_step := 6;
        WITH line_ratio AS (
            SELECT
                o.plant_id,
                o.line_id,
                o.day_id::NUMERIC(8) AS target_date_iso,
                MAX(o.line_output_good) AS line_output_good,
                MAX(o.line_capacity_ideal) AS line_capacity_ideal,
                CASE
                    WHEN MAX(o.line_capacity_ideal) > 0
                        THEN MAX(o.line_output_good)::NUMERIC / MAX(o.line_capacity_ideal)
                    ELSE NULL
                END AS oee_ratio
            FROM application_data.ft_oee o
            WHERE o.plant_id = v_plant_rec.plant_id
              AND o.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR o.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR o.line_id = p_line_id)
              AND EXISTS (
                  SELECT 1
                  FROM unnest(v_passing_days, v_passing_lines) AS t(d, l)
                  WHERE t.d = o.day_id AND t.l = o.line_id
              )
            GROUP BY o.plant_id, o.line_id, o.day_id
        )
        UPDATE application_data.ft_kpi_target tgt
           SET kpi_value = CASE
                               WHEN lr.oee_ratio IS NULL THEN NULL
                               ELSE round(lr.oee_ratio * 100::NUMERIC, 6)
                           END,
               last_modified = timezone('UTC', current_timestamp),
               last_user = lp_last_user
        FROM line_ratio lr
        JOIN application_data.lk_kpi k
          ON k.plant_id = lr.plant_id
         AND k.kpi_code = 'OEE'
         AND k.is_deleted = FALSE
        WHERE tgt.plant_id = lr.plant_id
          AND tgt.line_id = lr.line_id
          AND tgt.target_date_iso = lr.target_date_iso
          AND tgt.kpi_id = k.kpi_id;
        GET DIAGNOSTICS v_rows_updated_kpi = ROW_COUNT;

        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Plant=' || v_plant_rec.plant_id::TEXT ||
            ', range=[' || v_date_min::TEXT || ',' || COALESCE(v_date_max::TEXT, 'NULL') || '], ' ||
            'deleted_shift=' || v_rows_deleted_shift::TEXT ||
            ', deleted_day=' || v_rows_deleted_day::TEXT ||
            ', inserted_shift=' || v_rows_inserted_shift::TEXT ||
            ', inserted_day=' || v_rows_inserted_day::TEXT ||
            ', updated_kpi=' || v_rows_updated_kpi::TEXT ||
            ', skipped_missing_threshold=' || v_missing_threshold_count::TEXT ||
            ', skipped_threshold_not_exceeded=' || v_not_exceeded_count::TEXT,
            lp_last_user
        );
    END LOOP;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Completed (all selected plants).',
        lp_last_user
    );

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE=' || SQLSTATE || ', step=' || lp_step::TEXT;
        CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, lp_last_user);
        RAISE;
END;
$procedure$;

-- DROP FUNCTION application_data.create_monthly_partition(text, text, int8, int4, int4);

CREATE OR REPLACE FUNCTION application_data.create_monthly_partition(p_table_name text, p_range_column text, p_plant_id bigint, p_year integer, p_month integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    -- ✅ AGGIUNTO NOME FUNZIONE
    lp_function_name text := 'application_data.create_monthly_partition';
    
    partition_name text;
    start_date_int bigint;
    end_date_int bigint;
    full_table_name text;
    part_exists bool;
    ddl text;
BEGIN
    -- Partition Name construction
    partition_name := p_table_name || '_plant_' || p_plant_id::text || '_' ||
                      lpad(p_year::text, 4, '0') || lpad(p_month::text, 2, '0');

    full_table_name := 'application_data.' || partition_name;

    -- Check if partition already exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'application_data'
        AND table_name = partition_name
    ) INTO part_exists;

    IF part_exists THEN
        -- Standard SQLSTATE '42P07' (duplicate_table)
        RAISE EXCEPTION 'Partition already exists: %', full_table_name
            USING ERRCODE = '42P07'; 
    END IF;

    -- Calculate numeric ISO dates
    start_date_int := (p_year * 10000) + (p_month * 100) + 1;

    IF p_month = 12 THEN
        end_date_int := ((p_year + 1) * 10000) + 101;
    ELSE
        end_date_int := (p_year * 10000) + ((p_month + 1) * 100) + 1;
    END IF;

    -- Construct DDL
    ddl := 'CREATE TABLE application_data.' || quote_ident(partition_name) ||
           ' PARTITION OF application_data.' || quote_ident(p_table_name || '_plant_' || p_plant_id::text) ||
           ' FOR VALUES FROM (' || start_date_int::bigint || ') TO (' || end_date_int::bigint || ')';

    -- ✅ USO VARIABILE NEL LOG (NOTICE)
    RAISE NOTICE '[%] Executing partition creation for plant_id=%', lp_function_name, p_plant_id;
    
    EXECUTE ddl;
END;
$function$
;



-- DROP FUNCTION application_data.create_plant_partition(text, text, int8);

CREATE OR REPLACE FUNCTION application_data.create_plant_partition(p_table_name text, p_range_column text, p_plant_id bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    partition_name text;
    part_exists boolean;

 	ddl text;
BEGIN
    partition_name := p_table_name || '_plant_' || p_plant_id;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'application_data'
        AND table_name = partition_name
    ) INTO part_exists;

    IF part_exists THEN
        RAISE EXCEPTION 'LIST partition already exists: table "%", plant_id %, column "%"',
            p_table_name, p_plant_id, p_range_column
            USING ERRCODE = 'P0001';
    END IF;

    -- Se non esiste: crea
   /* EXECUTE format('CREATE TABLE application_data.%I 
                    PARTITION OF application_data.%I 
                    FOR VALUES IN (%s::bigint) 
                    PARTITION BY RANGE (%I)',
                   partition_name, p_table_name, p_plant_id, p_range_column); */

	ddl := 'CREATE TABLE application_data.' || quote_ident(partition_name) || ' PARTITION OF application_data.' || quote_ident(p_table_name) ||' FOR VALUES IN (' || p_plant_id::bigint || ')' || ' PARTITION BY RANGE (' || quote_ident(p_range_column) || ')';



    EXECUTE ddl;
	RAISE NOTICE 'plant_id tipo → %, valore → %', pg_typeof(p_plant_id), p_plant_id;
	RAISE NOTICE 'DDL: %', ddl;
   
END;
$function$
;


-- DROP PROCEDURE application_data.manage_ft_kpi_target(varchar, int8, int8, numeric, numeric, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_ft_kpi_target(operation_type character varying, p_target_id bigint, p_plant_id bigint, p_target_value_num numeric, p_kpi_value numeric, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_ft_kpi_target';
    lp_err_msg VARCHAR(2000);
BEGIN
    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

       -- Log the update operation
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Updated target_value_num and kpi_value for target_id: ' || p_target_id || ', plant_id: ' || p_plant_id,
        lp_last_user
    );
 CASE operation_type
        WHEN 'U' THEN
-- Update the target_value_num and kpi_value using target_id and plant_id as primary keys
    UPDATE application_data.ft_kpi_target
    SET 
        target_value_num = p_target_value_num,
        kpi_value = p_kpi_value,
        last_user = lp_last_user,
        last_modified = timezone('UTC', current_timestamp)
    WHERE target_id = p_target_id
      AND plant_id = p_plant_id;

 ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Capture errors and log them
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_ft_safety_cross(varchar, int8, int8, int8, int8, int8, int8, timestamp, text, int4, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_ft_safety_cross(operation_type character varying, p_safety_id bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_module_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_safety_category_id bigint DEFAULT NULL::bigint, p_safety_type_id bigint DEFAULT NULL::bigint, p_day_ts timestamp without time zone DEFAULT NULL::timestamp without time zone, p_comment_ds text DEFAULT NULL::text, p_day_lost integer DEFAULT NULL::integer, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_ft_safety_cross';
    lp_err_msg VARCHAR(2000);
    v_partition_name TEXT;
    v_partition_exists BOOLEAN;
    lp_year INT;
    lp_month INT;
    v_day_id INT4;
BEGIN
    lp_step := 0;

    -- 🪵 Log initial input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type=' || COALESCE(operation_type, 'NULL') ||
        ', safety_id=' || COALESCE(p_safety_id::TEXT, 'NULL') ||
        ', plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', module_id=' || COALESCE(p_module_id::TEXT, 'NULL') ||
        ', line_id=' || COALESCE(p_line_id::TEXT, 'NULL') ||
        ', safety_category_id=' || COALESCE(p_safety_category_id::TEXT, 'NULL') ||
        ', safety_type_id=' || COALESCE(p_safety_type_id::TEXT, 'NULL') ||
        ', day_ts=' || COALESCE(p_day_ts::TEXT, 'NULL') ||
        ', comment=' || COALESCE(p_comment_ds, 'NULL') ||
        ', day_lost=' || COALESCE(p_day_lost::TEXT, 'NULL') || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- 👤 Validate user
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID and Fullname cannot be NULL';
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;
	
	 -- ⏱ Extract partition date parts
            lp_year := EXTRACT(YEAR FROM p_day_ts)::INT;
            lp_month := EXTRACT(MONTH FROM p_day_ts)::INT;
            v_day_id := TO_CHAR(p_day_ts::timestamp, 'YYYYMMDD')::INT4;

            -- 📦 Partition name
            v_partition_name := format('ft_safety_cross_plant_%s_%s%02s', p_plant_id, lp_year, lp_month);

            -- 🧪 Check partition existence
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = 'application_data'
                  AND table_name = v_partition_name
            )
            INTO v_partition_exists;

            -- 🧱 Create partition if missing
            IF NOT v_partition_exists THEN
                BEGIN
                    PERFORM application_data.create_monthly_partition(
                        'ft_safety_cross',
                        'day_id',
                        p_plant_id,
                        lp_year,
                        lp_month
                    );

                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'ℹ️ Partition created: ' || v_partition_name,
                        lp_last_user
                    );

                EXCEPTION WHEN OTHERS THEN
                    lp_err_msg := '❌ Partition creation failed: ' || v_partition_name || ' — ' || SQLERRM;
                    INSERT INTO application_data.log_error (
                        error_timestamp, error_src, error_msg, error_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        lp_err_msg,
                        lp_last_user
                    );
                END;
            ELSE
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'ℹ️ Partition already exists: ' || v_partition_name,
                    lp_last_user
                );
            END IF;
  

   -- 🎯 Switch based on operation type
    CASE operation_type
        WHEN 'I' THEN
            lp_step := 1;

            IF p_plant_id IS NULL OR p_module_id IS NULL OR p_line_id IS NULL
                OR p_safety_category_id IS NULL OR p_safety_type_id IS NULL OR p_day_ts IS NULL THEN
                RAISE EXCEPTION 'Missing mandatory fields for INSERT';
            END IF;

  -- 🟢 INSERT into ft_safety_cross
            INSERT INTO application_data.ft_safety_cross (
                plant_id,
                module_id,
                line_id,
                safety_category_id,
                safety_type_id,
                day_id,
                day_ts,
                comment_ds,
                day_lost,
                creation_ts,
                creator_user,
                last_modified,
                last_user
            ) VALUES (
                p_plant_id,
                p_module_id,
                p_line_id,
                p_safety_category_id,
                p_safety_type_id,
                v_day_id,
                TO_CHAR(p_day_ts, 'YYYY-MM-DD HH24:MI')::timestamp,
                p_comment_ds,
                p_day_lost,
                timezone('UTC', current_timestamp),
                lp_last_user,
                timezone('UTC', current_timestamp),
                lp_last_user
            );

           
        WHEN 'U' THEN
            lp_step := 2;

            UPDATE application_data.ft_safety_cross
            SET
                module_id = COALESCE(p_module_id, module_id),
                line_id = COALESCE(p_line_id, line_id),
                safety_category_id = COALESCE(p_safety_category_id, safety_category_id),
                safety_type_id = COALESCE(p_safety_type_id, safety_type_id),
                day_id = COALESCE(TO_CHAR(p_day_ts::timestamp, 'YYYYMMDD')::INT4, day_id),
                day_ts = COALESCE(TO_CHAR(p_day_ts::timestamp, 'YYYY-MM-DD HH24:MI')::timestamp, day_ts),
                comment_ds = COALESCE(p_comment_ds, comment_ds),
                day_lost = COALESCE(p_day_lost, day_lost),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE safety_id = p_safety_id;

        WHEN 'D' THEN
            lp_step := 3;
            DELETE FROM application_data.ft_safety_cross
            WHERE safety_id = p_safety_id;

        ELSE
            RAISE EXCEPTION 'Invalid operation_type: %', operation_type;
    END CASE;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := '❌ ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', STEP=' || lp_step;
    INSERT INTO application_data.log_error (
        error_timestamp,
        error_src,
        error_msg,
        error_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_err_msg,
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );
    RAISE;
END;
$procedure$
;




 -- DROP PROCEDURE application_data.manage_lk_action(varchar, int8, varchar, varchar, text, int8, int8, int8, int8, int8, int8, int8, int8, varchar, varchar, int8, int8, int8, int8, bool, bool, bool, bool, bool, text, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_action(p_operation_type character varying, p_action_id bigint DEFAULT NULL::bigint, p_action_cd character varying DEFAULT NULL::character varying, p_action_html_ds character varying DEFAULT NULL::character varying, p_action_ds text DEFAULT NULL::text, p_module_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_action_priority_id bigint DEFAULT NULL::bigint, p_action_status_id bigint DEFAULT NULL::bigint, p_kpi_category_id bigint DEFAULT NULL::bigint, p_opening_tier_id bigint DEFAULT NULL::bigint, p_assign_tier_id bigint DEFAULT NULL::bigint, p_action_owner character varying DEFAULT NULL::character varying, p_action_raiser character varying DEFAULT NULL::character varying, p_opening_day_id bigint DEFAULT NULL::bigint, p_closure_day_id bigint DEFAULT NULL::bigint, p_owner_closure_day_id bigint DEFAULT NULL::bigint, p_due_date_day_id bigint DEFAULT NULL::bigint, p_is_escalated boolean DEFAULT false, p_is_no_escalation boolean DEFAULT false, p_is_on_time boolean DEFAULT NULL::boolean, p_is_on_hold boolean DEFAULT NULL::boolean, p_is_top_action boolean DEFAULT NULL::boolean, p_meeting_id text DEFAULT NULL::text, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    procedure_start_ts timestamp :=timezone('UTC', current_timestamp);
    lp_last_user TEXT := p_user_id::TEXT || ' -- ' || p_user_fullname;
    lp_procedure_name TEXT := 'application_data.manage_lk_action';
    lp_log_message TEXT;
    lp_err_msg TEXT;
    lp_plant_timezone TEXT;
    
    -- UTC calculated from local_ts
    lp_opening_utc_ts TIMESTAMP;
    lp_closure_utc_ts TIMESTAMP;
    lp_owner_closure_utc_ts TIMESTAMP;
    lp_due_date_utc_ts TIMESTAMP;

    -- local timestamp
    lp_opening_local_ts TIMESTAMP;
    lp_closure_local_ts TIMESTAMP;
    lp_owner_closure_local_ts TIMESTAMP;
    lp_due_date_local_ts TIMESTAMP;


    -- UTC timestamps
    lp_creation_utc_ts TIMESTAMP := timezone('UTC', current_timestamp);
    lp_last_modified_utc_ts TIMESTAMP := timezone('UTC', current_timestamp);
    lp_creation_local_ts TIMESTAMP;
    lp_creation_day_local_id INT;
    lp_last_modified_local_ts TIMESTAMP;
    lp_last_modified_local_day_id INT;
	lp_step INT;
    
	lp_action_status_id BIGINT;

BEGIN
   
   -- Log input
    lp_log_message :=
        'Input: [operation_type:' || p_operation_type ||
        ', p_action_id:' || COALESCE(p_action_id::TEXT, 'NULL') ||
        ', p_action_cd:' || COALESCE(p_action_cd, 'NULL') ||
        ', p_action_html_ds:' || COALESCE(p_action_html_ds, 'NULL') ||
        ', p_action_ds:' || COALESCE(p_action_ds, 'NULL') ||
        ', p_plant_id:' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', p_module_id:' || COALESCE(p_module_id::TEXT, 'NULL') ||
        ', p_line_id:' || COALESCE(p_line_id::TEXT, 'NULL') ||
        ', p_action_priority_id:' || COALESCE(p_action_priority_id::TEXT, 'NULL') ||
        ', p_action_status_id:' || COALESCE(p_action_status_id::TEXT, 'NULL') ||
        ', p_kpi_category_id:' || COALESCE(p_kpi_category_id::TEXT, 'NULL') ||
        ', p_opening_tier_id:' || COALESCE(p_opening_tier_id::TEXT, 'NULL') ||
  		', p_assign_tier_id:' || COALESCE(p_assign_tier_id::TEXT, 'NULL') ||
        ', p_action_owner:' || COALESCE(p_action_owner::TEXT, 'NULL') ||
        ', p_action_raiser:' || COALESCE(p_action_raiser::TEXT, 'NULL') ||
        ', p_opening_day_id:' || COALESCE(p_opening_day_id::TEXT, 'NULL') || 
        ', p_closure_day_id:' || COALESCE(p_closure_day_id::TEXT, 'NULL') || 
        ', p_owner_closure_day_id:' || COALESCE(p_owner_closure_day_id::TEXT, 'NULL') || 
        ', p_due_date_day_id:' || COALESCE(p_due_date_day_id::TEXT, 'NULL') ||
		', p_is_escalated:' || COALESCE(p_is_escalated::TEXT, 'NULL') ||
		', p_is_no_escalation:' || COALESCE(p_is_no_escalation::TEXT, 'NULL') ||
		', p_is_on_time:' || COALESCE(p_is_on_time::TEXT, 'NULL') ||
		', p_is_on_hold:' || COALESCE(p_is_on_hold::TEXT, 'NULL') ||
		', p_is_top_action:' || COALESCE(p_is_top_action::TEXT, 'NULL') ||
		', p_meeting_id:' || COALESCE(p_meeting_id, 'NULL') ||
        ', p_user_id:' || COALESCE(p_user_id::TEXT, 'NULL') ||
        ', p_user_fullname:' || COALESCE(p_user_fullname::TEXT, 'NULL') || ']';
        

  lp_step:=1;
   INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        procedure_start_ts,
        lp_procedure_name,
        lp_log_message,
        lp_last_user
    );
  lp_step:=2;
    -- Get timezone
    SELECT plant_timezone INTO lp_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;
  
    lp_step:=3;
    -- Timestamp conversions
    IF p_opening_day_id IS NOT NULL THEN
      	
        lp_opening_utc_ts := (TO_DATE(p_opening_day_id::TEXT, 'YYYYMMDD')::timestamp at time zone lp_plant_timezone)::timestamptz AT TIME ZONE 'UTC';
        lp_opening_local_ts := TO_DATE(p_opening_day_id::TEXT, 'YYYYMMDD')::timestamp;
    END IF;

    lp_step:=4;
    IF p_closure_day_id IS NOT NULL THEN

        lp_closure_utc_ts :=  (TO_DATE(p_closure_day_id::TEXT, 'YYYYMMDD')::timestamp at time zone lp_plant_timezone)::timestamptz AT TIME ZONE 'UTC'; 
        lp_closure_local_ts := TO_DATE(p_closure_day_id::TEXT, 'YYYYMMDD')::timestamp;
    END IF;

    lp_step:=5;
    IF p_owner_closure_day_id IS NOT NULL THEN
        lp_owner_closure_utc_ts :=  (TO_DATE(p_owner_closure_day_id::TEXT, 'YYYYMMDD')::timestamp at time zone lp_plant_timezone)::timestamptz AT TIME ZONE 'UTC';
        lp_owner_closure_local_ts := TO_DATE(p_owner_closure_day_id::TEXT, 'YYYYMMDD')::timestamp;
    END IF;

    lp_step:=5;
    IF p_due_date_day_id IS NOT NULL THEN
        lp_due_date_utc_ts := (TO_DATE(p_due_date_day_id::TEXT, 'YYYYMMDD')::timestamp  at time zone lp_plant_timezone)::timestamptz AT TIME ZONE 'UTC';
        lp_due_date_local_ts := TO_DATE(p_due_date_day_id::TEXT, 'YYYYMMDD')::timestamp;
    END IF;

    lp_step:=6;
    lp_creation_local_ts := (procedure_start_ts AT TIME ZONE 'UTC' AT TIME ZONE lp_plant_timezone)::timestamp;
    lp_creation_day_local_id := TO_CHAR(lp_creation_local_ts, 'YYYYMMDD')::INT;

    lp_step:=7;
    lp_last_modified_local_ts := (procedure_start_ts AT TIME ZONE 'UTC' AT TIME ZONE lp_plant_timezone)::timestamp;
    lp_last_modified_local_day_id := TO_CHAR(lp_last_modified_local_ts, 'YYYYMMDD')::INT;

    lp_step:=8;
    -- Operation logic
    IF p_operation_type = 'I' THEN
        IF p_action_cd IS NULL OR p_action_ds IS NULL OR p_plant_id IS NULL OR 
           p_module_id IS NULL OR p_line_id IS NULL OR p_action_priority_id IS NULL OR
           p_action_status_id IS NULL OR p_kpi_category_id IS NULL OR
           p_opening_tier_id IS NULL OR p_action_raiser IS NULL OR p_action_owner IS NULL THEN
            RAISE EXCEPTION 'Mandatory fields are missing!';
        END IF;

        lp_step:=9;
       insert
		into
		application_data.lk_action (
	    plant_id,
		action_id,
		action_cd,
		action_html_ds,
		action_ds,
		module_id,
		line_id,
		action_priority_id,
		action_status_id,
		kpi_category_id,
		opening_tier_id,
		assign_tier_id,
		action_owner,
		action_raiser,
		opening_day_local_id,
		opening_local_ts,
		opening_utc_ts,
		closure_day_local_id,
		closure_local_ts,
		closure_utc_ts,
		owner_closure_day_local_id,
		owner_closure_local_ts,
		owner_closure_utc_ts,
		due_date_day_local_id,
		due_date_local_ts,
		due_date_utc_ts,
		creation_day_local_id,
		creation_local_ts,
		creation_utc_ts,
		creator_user,
		last_modified_local_day_id,
		last_modified_local_ts,
		last_modified_utc_ts,
		last_user,
		is_escalated,
		is_no_escalation,
		is_on_time,
		is_on_hold,
		is_top_action,
		meeting_id)
		values (
		p_plant_id,
		p_action_id,
		p_action_cd,
		p_action_html_ds,
		p_action_ds,
		p_module_id,
		p_line_id,
		p_action_priority_id,
		p_action_status_id,
		p_kpi_category_id,
		p_opening_tier_id,
		p_assign_tier_id,
		p_action_owner,
		p_action_raiser,
		p_opening_day_id,
		lp_opening_local_ts,
		lp_opening_utc_ts,
		p_closure_day_id,
		lp_closure_local_ts,
		lp_closure_utc_ts,
		p_owner_closure_day_id,
		lp_owner_closure_local_ts,
		lp_owner_closure_utc_ts,
		p_due_date_day_id,
		lp_due_date_local_ts,
		lp_due_date_utc_ts,
		lp_creation_day_local_id,
		lp_creation_local_ts,
		lp_creation_utc_ts,
		lp_last_user,
		lp_last_modified_local_day_id,
		lp_last_modified_local_ts,
		lp_last_modified_utc_ts,
		lp_last_user,
		p_is_escalated,
		p_is_no_escalation,
		p_is_on_time,
		p_is_on_hold,
		p_is_top_action,
		p_meeting_id
		);

    lp_step:=10;
    ELSIF p_operation_type = 'U' THEN
		
		if ( p_closure_day_id is not null and 
		p_action_status_id not in ( select action_status_id 
									from application_data.lk_action_status	
								    where action_status_cd in ('<#ClosedbyRaiser/>','<#CompletedbyOwner/>') ) )
		then lp_action_status_id := (select action_status_id 
									from application_data.lk_action_status	
								    where action_status_cd = '<#ClosedbyRaiser/>');
		else lp_action_status_id := p_action_status_id;
		 	
		end if;	
		
        UPDATE application_data.lk_action
        SET
			action_cd = COALESCE(p_action_cd, action_cd),
            action_html_ds = COALESCE(p_action_html_ds, action_html_ds),
            action_ds = COALESCE(p_action_ds, action_ds),
            module_id = COALESCE(p_module_id, module_id),
            line_id = COALESCE(p_line_id, line_id),
            action_priority_id = COALESCE(p_action_priority_id, action_priority_id),
            action_status_id = COALESCE(lp_action_status_id, action_status_id),
            kpi_category_id = COALESCE(p_kpi_category_id, kpi_category_id),
            opening_tier_id = COALESCE(p_opening_tier_id, opening_tier_id),
 			assign_tier_id = COALESCE(p_assign_tier_id, opening_tier_id),
            action_owner = COALESCE(p_action_owner, action_owner),
            action_raiser = COALESCE(p_action_raiser, action_raiser),
            meeting_id = COALESCE(p_meeting_id, meeting_id),
         
			last_user = lp_last_user,
      
            closure_day_local_id = p_closure_day_id,
            closure_local_ts = lp_closure_local_ts, 
            closure_utc_ts = lp_closure_utc_ts,
      
            owner_closure_day_local_id = p_owner_closure_day_id,  
            owner_closure_local_ts = lp_owner_closure_local_ts,
            owner_closure_utc_ts = lp_owner_closure_utc_ts,
      
            due_date_day_local_id = p_due_date_day_id,
            due_date_local_ts = lp_due_date_local_ts, 
            due_date_utc_ts = lp_due_date_utc_ts,
      
            last_modified_utc_ts = procedure_start_ts,
            last_modified_local_day_id = lp_last_modified_local_day_id,
            last_modified_local_ts = lp_last_modified_local_ts

        WHERE action_id = p_action_id AND plant_id = p_plant_id;

   lp_step:=11;
    ELSIF p_operation_type = 'D' THEN
        DELETE FROM application_data.lk_action
        WHERE action_id = p_action_id AND plant_id = p_plant_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation type: %', p_operation_type;
    END IF;

EXCEPTION WHEN OTHERS THEN
 lp_err_msg := 'ERROR at step ' || lp_step::TEXT || ' ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_err_msg,
        lp_last_user
    );
    RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_action_files(in varchar, inout varchar, in int8, in numeric, in varchar, in varchar, in varchar, in varchar, in int8, in bool, in numeric, in varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_action_files(p_operation_type character varying, INOUT out_flag character varying, p_plant_id bigint DEFAULT NULL::bigint, p_file_id numeric DEFAULT NULL::numeric, p_file_name character varying DEFAULT NULL::character varying, p_file_size character varying DEFAULT NULL::character varying, p_mimetype character varying DEFAULT NULL::character varying, p_relativeurl character varying DEFAULT NULL::character varying, p_action_id bigint DEFAULT NULL::bigint, p_is_deleted boolean DEFAULT NULL::boolean, p_user_id numeric DEFAULT NULL::numeric, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_log_message TEXT;
	procedure_ts timestamp := timezone('UTC', current_timestamp);
    lp_procedure_name TEXT := 'application_data.manage_lk_action_files';
  	lp_error_msg VARCHAR(2000);
	lp_step numeric;
  	lp_user	varchar;
BEGIN
	out_flag := 'ok';
	lp_user := p_user_id::TEXT || ' -- ' || p_user_fullname;
    -- Prepare input log message
    lp_log_message := 'Input: [operation_type: ' || COALESCE(p_operation_type, 'NULL') || 
					  ', plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
                      ', file_id: ' || COALESCE(p_file_id::TEXT, 'NULL') ||
                      ', file_name: ' || COALESCE(p_file_name, 'NULL') ||
                      ', file_size: ' || COALESCE(p_file_size, 'NULL') ||
                      ', mimeType: ' || COALESCE(p_mimetype, 'NULL') ||
                      ', relativeUrl: ' || COALESCE(p_relativeurl, 'NULL') ||
                      ', action_id: ' || COALESCE(p_action_id::TEXT, 'NULL') ||
                      ', is_deleted: ' || COALESCE(p_is_deleted::TEXT, 'NULL') ||
					  ', user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') ||
                      ', user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']';

    -- Log the input
	lp_step:=1;
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        procedure_ts,
        lp_procedure_name,
        lp_log_message,
        lp_user
    );

    -- Main operation
    IF p_operation_type = 'I' THEN
	lp_step:=2;
        INSERT INTO application_data.lk_action_files (
            plant_id, file_id, file_name, file_size, mimetype, relativeurl, action_id, user_fullname, upload_timestamp, is_deleted)
        VALUES (
            p_plant_id, p_file_id, p_file_name, p_file_size, p_mimetype, p_relativeurl, p_action_id, lp_user, procedure_ts, FALSE)
        ON CONFLICT (file_id) DO NOTHING;

		lp_step:=3;
        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            'Inserted file_id: ' || p_file_id || 'associated with plant_id: '|| p_plant_id,
            lp_user
        );

    ELSIF p_operation_type = 'D' THEN
		lp_step:=4;
        DELETE FROM application_data.lk_action_files WHERE file_id = p_file_id AND plant_id=p_plant_id;

		lp_step:=5;
        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            'Deleted file_id: ' || p_file_id || 'associated with plant_id: '|| p_plant_id,
            lp_user
        );

    ELSIF p_operation_type = 'LD' THEN
		lp_step:=6;
        UPDATE application_data.lk_action_files
        SET is_deleted = TRUE
        WHERE file_id = p_file_id AND plant_id=p_plant_id;

		lp_step:=7;
        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
          	procedure_ts,
            lp_procedure_name,
            'Logical delete file_id: ' || p_file_id || 'associated with plant_id: '|| p_plant_id,
            lp_user
        );

    ELSE
		lp_step:=8;
        RAISE EXCEPTION 'Invalid action. Use INSERT or DELETE';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
 	 lp_error_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
           		'Step: ' || lp_step::text || ', ' || 
				'Input: [operation_type: ' || COALESCE(p_operation_type, 'NULL') || ', ' ||
 					  	', plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
						', file_id: ' || COALESCE(p_file_id::TEXT, 'NULL') ||
						', file_name: ' || COALESCE(p_file_name, 'NULL') ||
						', file_size: ' || COALESCE(p_file_size, 'NULL') ||
						', mimeType: ' || COALESCE(p_mimetype, 'NULL') ||
						', relativeUrl: ' || COALESCE(p_relativeurl, 'NULL') ||
						', action_id: ' || COALESCE(p_action_id::TEXT, 'NULL') ||
						', is_deleted: ' || COALESCE(p_is_deleted::TEXT, 'NULL') ||
						', user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') ||
						', user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']';
  	--Debug Version
        out_flag := lp_error_msg;
       INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_error_msg,
            lp_user
        );
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_attendance_role(varchar, int8, varchar, varchar, int8, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_attendance_role(operation_type character varying, p_attendance_role_id bigint DEFAULT NULL::bigint, p_attendance_role_code character varying DEFAULT NULL::character varying, p_attendance_role_ds character varying DEFAULT NULL::character varying, p_plant_id bigint DEFAULT NULL::bigint, p_is_active boolean DEFAULT NULL::boolean, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
declare
    lp_last_user VARCHAR;                 -- Last user info (combines ID and Fullname)
    lp_step NUMERIC;                      -- Step for debugging/logging
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_attendance_role'; -- Procedure name
    lp_err_msg VARCHAR(2000);             -- Error message
	v_attendance_role_id NUMERIC;			  --attendance_role id associated with the role 
BEGIN
    lp_step := 0;
   -- Validate user inputs

    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

 	lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;
    -- Log the operation input
	INSERT INTO application_data.log_operation (
	    operation_timestamp,
	    operation_src,
	    operation_msg,
	    operation_caller
	) VALUES (
	    timezone('UTC', current_timestamp),
	    lp_procedure_name,
	    (
	        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
	        'p_attendance_role_id: ' || COALESCE(p_attendance_role_id::TEXT, 'NULL') || ', ' ||
	        'p_attendance_role_code: ' || COALESCE(p_attendance_role_code, 'NULL') || ', ' ||
	        'p_attendance_role_ds: ' || COALESCE(p_attendance_role_ds, 'NULL') || ', ' ||
	        'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
	        'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ', ' ||
	        'p_user_id: ' || p_user_id::TEXT || ', ' ||
	        'p_user_fullname: ' || p_user_fullname::TEXT || ']'
	    ),
	    lp_last_user
	);

    -- Main CASE block to handle operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_attendance_role_code IS NULL  OR p_attendance_role_ds IS NULL OR p_plant_id IS NULL THEN
                lp_err_msg := 'ERROR: Required fields (attendance_role_code, attendance_role_ds, plant_id) cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_attendance_role (
                attendance_role_code,
                attendance_role_ds,
                plant_id,
                is_modify,
                is_active,
                is_deleted,
                creation_ts,
                creator_user,
                last_modified,
 				last_user
            ) VALUES (
                p_attendance_role_code,
                p_attendance_role_ds,
                p_plant_id,
                TRUE, 
                p_is_active,
                FALSE,
                timezone('UTC', current_timestamp),
                lp_last_user,
                timezone('UTC', current_timestamp),
				lp_last_user
            );

		-- insert new attendance_role into the map_attendance_tier map
		
		SELECT attendance_role_id into v_attendance_role_id
		FROM application_data.lk_attendance_role
		WHERE plant_id = p_plant_id
		AND attendance_role_code=p_attendance_role_code;

		  PERFORM 1
            FROM application_data.map_attendance_tier
            WHERE attendance_role_id = v_attendance_role_id AND plant_id = p_plant_id;
            IF NOT FOUND THEN
                INSERT INTO application_data.map_attendance_tier
							(plant_id,
							tier_id,
							attendance_role_id,
							is_active,
							is_assigned,
							au_user_id,
							au_change_ts
							)
				SELECT  p_plant_id,
						t.tier_id,
						v_attendance_role_id,
						p_is_active,
						false,
						p_user_id,
 						timezone('UTC', current_timestamp)
				FROM application_data.lk_tier t 
				WHERE plant_id=p_plant_id;
	
            END IF;

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;

            -- Ensure the record is modifiable
            PERFORM 1
            FROM application_data.lk_attendance_role
            WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_modify = FALSE).';
            END IF;

            UPDATE application_data.lk_attendance_role
            SET
                attendance_role_code = COALESCE(p_attendance_role_code, attendance_role_code),
                attendance_role_ds = COALESCE(p_attendance_role_ds, attendance_role_ds),
                is_active = COALESCE(p_is_active, is_active), 
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id;

			
			UPDATE application_data.map_attendance_tier
            SET  is_active = COALESCE(p_is_active, is_active),
				 is_assigned = case when p_is_active= false then false else is_assigned end
			WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id;
							
 
        WHEN 'LD' THEN
            -- Logical Deletion
            lp_step := 3;

            -- Ensure the record is modifiable
            PERFORM 1
            FROM application_data.lk_attendance_role
            WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';
            END IF;

            UPDATE application_data.lk_attendance_role
            SET
		     	attendance_role_code= attendance_role_code||'***'||attendance_role_id ||'***',
                is_deleted = TRUE,
                is_active = FALSE,
                is_modify = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id;

			UPDATE application_data.map_attendance_tier
            SET  is_active = FALSE,
				 is_assigned = FALSE
			WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id;


        WHEN 'D' THEN
            -- Physical Deletion
            lp_step := 4;

            -- Ensure the record is modifiable
            PERFORM 1
            FROM application_data.lk_attendance_role
            WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';
            END IF;

            DELETE FROM application_data.lk_attendance_role
            WHERE attendance_role_id = p_attendance_role_id AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Log errors
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;



-- DROP PROCEDURE application_data.manage_lk_component(varchar, int8, varchar, varchar, int8, int8, int8, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_component(p_operation_type character varying, p_component_id bigint DEFAULT NULL::bigint, p_component_code character varying DEFAULT NULL::character varying, p_component_ds character varying DEFAULT NULL::character varying, p_plant_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_machine_id bigint DEFAULT NULL::bigint, p_is_active boolean DEFAULT NULL::boolean, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
declare
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_component';
    lp_err_msg VARCHAR(2000);
    lp_log_message TEXT;
BEGIN
    lp_step := 0;

    -- Validate mandatory user fields
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Create log message with all input parameters
    lp_log_message := 
        'Operation Type: ' || p_operation_type || ', ' ||
        'Component ID: ' || COALESCE(p_component_id::TEXT, 'NULL') || ', ' ||
        'Component Code: ' || COALESCE(p_component_code, 'NULL') || ', ' ||
        'Component DS: ' || COALESCE(p_component_ds, 'NULL') || ', ' ||
        'Plant ID: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
        'Line ID: ' || COALESCE(p_line_id::TEXT, 'NULL') || ', ' ||
        'Machine ID: ' || COALESCE(p_machine_id::TEXT, 'NULL') || ', ' ||
      --'Component Type ID: ' || COALESCE(p_component_type_id::TEXT, 'NULL') || ', ' ||
        'Is Active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ', ' ||
        'User ID: ' || p_user_id || ', ' ||
        'User Fullname: ' || p_user_fullname;

    -- Logging the operation
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_log_message,
        lp_last_user
    );

    -- Perform actions based on the operation type
    CASE p_operation_type
        WHEN 'I' THEN
            -- Insert a new record
            lp_step := 1;

            -- Validate required fields
            IF p_component_code IS NULL OR p_component_ds IS NULL OR p_plant_id IS NULL 
               OR p_line_id IS NULL OR p_machine_id IS NULL THEN
                lp_err_msg := 'ERROR: Required values cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_component (
                component_code,
                component_ds,
                plant_id,
                line_id,
                machine_id,
                component_type_id,
                is_active,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_component_code,
                p_component_ds,
                p_plant_id,
                p_line_id,					
                p_machine_id,
                null, 						-- component_type_id is not currently stored,
                p_is_active,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

        WHEN 'U' THEN
            -- Update an existing record
            lp_step := 2;

            -- Validate Component ID and Plant ID
            IF p_component_id IS NULL OR p_plant_id IS NULL OR p_machine_id IS NULL THEN
                lp_err_msg := 'ERROR: Component ID , Plant ID , Machine Id cannot be NULL for update.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            UPDATE application_data.lk_component
            SET 
                component_code = COALESCE(p_component_code, component_code),
                component_ds = COALESCE(p_component_ds, component_ds),
                line_id = COALESCE(p_line_id, line_id),
                machine_id = COALESCE(p_machine_id, machine_id),
               -- component_type_id = COALESCE(p_component_type_id, component_type_id),
                is_active = COALESCE(p_is_active, is_active),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE component_id = p_component_id
              AND plant_id = p_plant_id;

        WHEN 'LD' THEN
            -- Logical Delete (soft delete)
            lp_step := 3;

            -- Validate Component ID and Plant ID
            IF p_component_id IS NULL OR p_plant_id IS NULL OR p_machine_id IS NULL THEN
                lp_err_msg := 'ERROR: Component ID , Plant ID , Machine Id cannot be NULL for update.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            UPDATE application_data.lk_component
            SET 
				component_code = component_code||'***'||component_id||'***',
				is_deleted = TRUE,
                is_active = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE component_id = p_component_id
              AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Delete (hard delete)
            lp_step := 4;

            -- Validate Component ID and Plant ID
            IF p_component_id IS NULL OR p_plant_id IS NULL THEN
                lp_err_msg := 'ERROR: Component ID and Plant ID cannot be NULL for deletion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            DELETE FROM application_data.lk_component
            WHERE component_id = p_component_id
              AND plant_id = p_plant_id;

        ELSE
            -- Invalid Operation Type
            RAISE EXCEPTION 'ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Delete).';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Capture errors and log them
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', Step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.manage_lk_department(varchar, int8, varchar, varchar, int8, bool, bool, text, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_department(operation_type character varying, p_department_id bigint DEFAULT NULL::bigint, p_department_code character varying DEFAULT NULL::character varying, p_department_ds character varying DEFAULT NULL::character varying, p_plant_id bigint DEFAULT NULL::bigint, p_is_support_function boolean DEFAULT NULL::boolean, p_is_active boolean DEFAULT NULL::boolean, p_queue_link text DEFAULT NULL::text, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;                 -- Last user info (combines ID and Fullname)
    lp_step NUMERIC;                      -- Step for debugging/logging
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_department'; -- Procedure name
    lp_err_msg VARCHAR(2000);             -- Error message
	v_department_id NUMERIC;			  -- department id associated with the department 
BEGIN
    lp_step := 0;

    -- Log the operation input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_department_id: ' || COALESCE(p_department_id::TEXT, 'NULL') || ', ' ||
            'p_department_code: ' || COALESCE(p_department_code, 'NULL') || ', ' ||
            'p_department_ds: ' || COALESCE(p_department_ds, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_is_support_function: ' || COALESCE(p_is_support_function::TEXT, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ', ' ||
            'p_queue_link: ' || COALESCE(p_queue_link, 'NULL') || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Main CASE block to handle operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_department_code IS NULL  OR p_department_ds IS NULL OR p_plant_id IS NULL THEN
                lp_err_msg := 'ERROR: Required fields (department_code, department_ds, plant_id) cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_department (
                department_code,
                department_ds,
                plant_id,
                is_support_function,
                is_modify,
                is_active,
                is_deleted,
                queue_link,
                creation_ts,
                creator_user,
                last_modified,
 				last_user
            ) VALUES (
                p_department_code,
                p_department_ds,
                p_plant_id,
                p_is_support_function,
                TRUE, -- Default is_modify to TRUE
                COALESCE(p_is_active, TRUE),
                FALSE, -- Default is_deleted to FALSE
                CASE WHEN p_queue_link='null' then null else p_queue_link end,
                timezone('UTC', current_timestamp),
                lp_last_user,
                timezone('UTC', current_timestamp),
				lp_last_user
            );

		-- insert new department into the map_attendance_tier map
		
		SELECT department_id into v_department_id
		FROM application_data.lk_department
		WHERE plant_id = p_plant_id
		AND department_code=p_department_code;

		  PERFORM 1
            FROM application_data.map_attendance_tier
            WHERE department_id = v_department_id AND plant_id = p_plant_id;
            IF NOT FOUND THEN
                INSERT INTO application_data.map_attendance_tier
							(plant_id,
							tier_id,
							department_id,
							is_active
							)
				SELECT  p_plant_id,
						t.tier_id,
						v_department_id,
						false
				FROM application_data.lk_tier t 
				WHERE plant_id=p_plant_id;
	
            END IF;

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;

            -- Ensure the record is modifiable
            PERFORM 1
            FROM application_data.lk_department
            WHERE department_id = p_department_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';
            END IF;

            UPDATE application_data.lk_department
            SET
                department_code = COALESCE(p_department_code, department_code),
                department_ds = COALESCE(p_department_ds, department_ds),
                is_support_function = COALESCE(p_is_support_function, is_support_function),
                is_active = COALESCE(p_is_active, is_active),
                queue_link = COALESCE(p_queue_link, queue_link),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE department_id = p_department_id AND plant_id = p_plant_id;

        WHEN 'LD' THEN
            -- Logical Deletion
            lp_step := 3;

            -- Ensure the record is modifiable
            PERFORM 1
            FROM application_data.lk_department
            WHERE department_id = p_department_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';
            END IF;

            UPDATE application_data.lk_department
            SET
                is_deleted = TRUE,
                is_active = FALSE,
                is_modify = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE department_id = p_department_id AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Deletion
            lp_step := 4;

            -- Ensure the record is modifiable
            PERFORM 1
            FROM application_data.lk_department
            WHERE department_id = p_department_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';
            END IF;

            DELETE FROM application_data.lk_department
            WHERE department_id = p_department_id AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Log errors
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_external_link(varchar, int8, text, varchar, text, int8, int8, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_external_link(operation_type character varying, p_url_id bigint DEFAULT NULL::bigint, p_url_code text DEFAULT NULL::text, p_url_sh_ds character varying DEFAULT NULL::character varying, p_url_ds text DEFAULT NULL::text, p_plant_id bigint DEFAULT NULL::bigint, p_tier_id bigint DEFAULT NULL::bigint, p_is_active boolean DEFAULT true, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;                 -- Last user info (combines ID and Fullname)
    lp_step NUMERIC;                      -- Step for debugging/logging
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_external_link'; -- Procedure name
    lp_err_msg VARCHAR(2000);             -- Error message
BEGIN
    lp_step := 0;

    -- Log the operation input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_url_id: ' || COALESCE(p_url_id::TEXT, 'NULL') || ', ' ||
            'p_url_code: ' || COALESCE(p_url_code, 'NULL') || ', ' ||
            'p_url_sh_ds: ' || COALESCE(p_url_sh_ds, 'NULL') || ', ' ||
            'p_url_ds: ' || COALESCE(p_url_ds, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
			'p_tier_id: ' || COALESCE(p_tier_id::TEXT, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') ||
            'p_user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Main CASE block to handle operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_url_code IS NULL OR p_url_sh_ds IS NULL OR p_plant_id IS NULL  OR p_tier_id IS NULL   THEN
                lp_err_msg := 'ERROR: Required fields (url_code, url_sh_ds, plant_id tier_id) cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_external_link (
                plant_id,
				tier_id,
                url_code,
                url_sh_ds,
                url_ds,
                is_active,
                is_deleted,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_plant_id,
				p_tier_id,
                p_url_code,
                p_url_sh_ds,
                p_url_ds,
                COALESCE(p_is_active, true),
                false,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;

            UPDATE application_data.lk_external_link
            SET
                url_code = COALESCE(p_url_code, url_code),
                url_sh_ds = COALESCE(p_url_sh_ds, url_sh_ds),
                url_ds = COALESCE(p_url_ds, url_ds),
				tier_id = COALESCE(p_tier_id, tier_id),
                is_active = COALESCE(p_is_active, is_active),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE url_id = p_url_id AND plant_id = p_plant_id;

        WHEN 'LD' THEN
            -- Logical Deletion
            lp_step := 3;

            UPDATE application_data.lk_external_link
            SET
                is_deleted = true,
                is_active = false,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE url_id = p_url_id AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Deletion
            lp_step := 4;

            DELETE FROM application_data.lk_external_link
            WHERE url_id = p_url_id AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Log errors
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_files(varchar, numeric, int8, varchar, varchar, varchar, varchar, varchar, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_files(IN p_action character varying, IN p_id numeric, IN p_plant_id bigint, IN p_name character varying DEFAULT NULL::character varying, IN p_size character varying DEFAULT NULL::character varying, IN p_mimetype character varying DEFAULT NULL::character varying, IN p_relativeurl character varying DEFAULT NULL::character varying, IN p_source character varying DEFAULT NULL::character varying, IN p_username character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_action = 'I' THEN
        INSERT INTO application_data.lk_files (id,plant_id,name, size, mimeType, relativeUrl, is_processed, is_deleted ,"source", username, upload_timestamp)
        VALUES (p_id, p_plant_id, p_name, p_size, p_mimeType, p_relativeUrl,false , false, p_source, p_username, timezone('UTC', current_timestamp) )
        ON CONFLICT (id) DO NOTHING;  -- Prevents duplicate IDs

    ELSIF p_action = 'D' THEN
        DELETE FROM application_data.lk_files WHERE id = p_id;

	 ELSIF p_action = 'LD' THEN
      UPDATE application_data.lk_files SET is_deleted=true WHERE id = p_id; 

    ELSE
        RAISE EXCEPTION 'Invalid action. Use INSERT or DELETE';
    END IF;
END;
$procedure$
;


-- DROP PROCEDURE application_data.manage_lk_issue(varchar, int8, varchar, varchar, text, int8, int8, int8, int8, int8, int8, int8, text, int8, int8, int8, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_issue(p_operation_type character varying, p_issue_id bigint DEFAULT NULL::bigint, p_issue_cd character varying DEFAULT NULL::character varying, p_issue_sh_ds character varying DEFAULT NULL::character varying, p_issue_ds text DEFAULT NULL::text, p_plant_id bigint DEFAULT NULL::bigint, p_module_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_kpi_category_id bigint DEFAULT NULL::bigint, p_opening_tier_id bigint DEFAULT NULL::bigint, p_start_day_local_id bigint DEFAULT NULL::bigint, p_end_day_local_id bigint DEFAULT NULL::bigint, p_comment_ds text DEFAULT NULL::text, p_shift_id bigint DEFAULT NULL::bigint, p_priority_id bigint DEFAULT NULL::bigint, p_status_id bigint DEFAULT NULL::bigint, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    procedure_ts timestamp :=timezone('UTC', current_timestamp);
    lp_procedure_name TEXT := 'application_data.manage_lk_issue';
    lp_last_user TEXT := p_user_id::TEXT || ' -- ' || p_user_fullname;
    lp_err_msg TEXT;
    lp_log_message TEXT;
    lp_step INT;

    lp_plant_timezone TEXT;

    -- UTC and local timestamp conversions
    lp_start_day_utc_ts TIMESTAMP;
    lp_end_day_utc_ts TIMESTAMP;

    -- Local day ID conversions
    lp_start_day_local_ts timestamp;
    lp_end_day_local_ts timestamp;

    -- Creation and last modified metadata
    lp_creation_local_ts TIMESTAMP;
	lp_creation_utc_ts TIMESTAMP;
    lp_creation_day_local_id INT;
    lp_last_modified_local_ts TIMESTAMP;
    lp_last_modified_local_day_id INT;
BEGIN
    lp_step := 0;

    -- 1. Log input params
    lp_log_message :=
        'Input: [operation_type=' || p_operation_type ||
        ', p_issue_id:' || COALESCE(p_issue_id::TEXT, 'NULL') ||
        ', p_issue_cd:' || COALESCE(p_issue_cd::TEXT, 'NULL') ||
        ', p_issue_sh_ds:' || COALESCE(p_issue_sh_ds::TEXT, 'NULL') ||
        ', p_issue_ds:' || COALESCE(p_issue_ds::TEXT, 'NULL') ||
        ', p_plant_id:' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', p_module_id:' || COALESCE(p_module_id::TEXT, 'NULL') ||
        ', p_line_id:' || COALESCE(p_line_id::TEXT, 'NULL') ||
        ', p_kpi_category_id:' || COALESCE(p_kpi_category_id::TEXT, 'NULL') ||
        ', p_opening_tier_id:' || COALESCE(p_opening_tier_id::TEXT, 'NULL') ||
        ', p_start_day_local_id:' || COALESCE(p_start_day_local_id::TEXT, 'NULL') ||
        ', p_end_day_local_id:' || COALESCE(p_end_day_local_id::TEXT, 'NULL') ||
        ', p_comment_ds:' || COALESCE(p_comment_ds::TEXT, 'NULL') ||
        ', p_shift_id:' || COALESCE(p_shift_id::TEXT, 'NULL') ||
		', p_priority_id:' || COALESCE(p_priority_id::TEXT, 'NULL') ||
		', p_status_id:' || COALESCE(p_status_id::TEXT, 'NULL') ||
        ', p_user_id:' || COALESCE(p_user_id::TEXT, 'NULL') ||
        ', p_user_fullname:' || COALESCE(p_user_fullname::TEXT, 'NULL') ||
        ']';
     lp_step := 1;
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        procedure_ts,
        lp_procedure_name,
        lp_log_message,
        lp_last_user
    );

     lp_step := 2;
    -- 2. Get plant timezone
    SELECT plant_timezone INTO lp_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;
    
     lp_step := 3;
    -- 3. Convert start timestamps and day ids
    IF p_start_day_local_id IS NOT NULL THEN
        lp_start_day_utc_ts := (TO_DATE(p_start_day_local_id::TEXT, 'YYYYMMDD')::timestamp at time zone lp_plant_timezone)::timestamptz AT TIME ZONE 'UTC';
        lp_start_day_local_ts :=  TO_DATE(p_start_day_local_id::TEXT, 'YYYYMMDD')::timestamp;
    END IF;

    lp_step := 4;
     -- 3. Convert end timestamps and day ids
    IF p_end_day_local_id IS NOT NULL THEN
        lp_end_day_utc_ts := (TO_DATE(p_end_day_local_id::TEXT, 'YYYYMMDD')::timestamp at time zone lp_plant_timezone)::timestamptz AT TIME ZONE 'UTC';
        lp_end_day_local_ts := TO_CHAR(p_end_day_local_id, 'YYYYMMDD')::INT;
    END IF;
    
    lp_step := 5;
    -- 5. Compute current creation and update timestamps
    lp_creation_local_ts := procedure_ts AT TIME ZONE 'UTC' AT TIME ZONE lp_plant_timezone;
	lp_creation_day_local_id := to_char(procedure_ts,'YYYYMMDD')::INT;

    lp_last_modified_local_ts := procedure_ts AT TIME ZONE 'UTC' AT TIME ZONE lp_plant_timezone;
    lp_last_modified_local_day_id := to_char(procedure_ts,'YYYYMMDD')::INT;

    lp_step := 6;
    -- 6. Operation logic
    IF p_operation_type = 'I' THEN
        IF p_issue_cd IS NULL OR p_issue_ds IS NULL OR p_plant_id IS NULL OR
           p_module_id IS NULL OR p_line_id IS NULL OR p_kpi_category_id IS NULL OR
           p_opening_tier_id IS NULL OR p_start_day_local_id IS NULL THEN
            RAISE EXCEPTION 'Mandatory fields are missing!';
        END IF;
        
    lp_step := 7;
       insert
	into
		application_data.lk_issue (
	    plant_id,
		module_id,
		line_id,
		issue_id,
		issue_cd,
		issue_sh_ds,
		issue_ds,
		kpi_category_id,
		opening_tier_id,
		start_day_local_id,
		start_local_ts,
		start_utc_ts,
		end_day_local_id,
		end_local_ts,
		end_utc_ts,
	--	time_loss_ss,
		comment_ds,
		creation_day_local_id,
		creation_local_ts,
		creation_utc_ts,
		creator_user,
		last_modified_utc_ts,
		last_modified_local_day_id,
		last_modified_local_ts,
		issue_priority_id,
		issue_status_id,
		last_user,
		shift_id)
	values (
		p_plant_id,
		p_module_id,
		p_line_id,
		p_issue_id,
		p_issue_cd,
		p_issue_sh_ds,
		p_issue_ds,
		p_kpi_category_id,
		p_opening_tier_id,
		p_start_day_local_id,
		lp_start_day_local_ts,
		lp_start_day_utc_ts,
		p_end_day_local_id,
		lp_end_day_local_ts,
		lp_end_day_utc_ts,
	--	p_time_loss_ss,
		p_comment_ds,
		lp_creation_day_local_id,
		lp_creation_local_ts,
		procedure_ts,
		lp_last_user,
		procedure_ts,
		lp_last_modified_local_day_id,
		lp_last_modified_local_ts,
		p_priority_id,
		p_status_id,
		lp_last_user,
		p_shift_id
		);

    ELSIF p_operation_type = 'U' THEN
        UPDATE application_data.lk_issue
        SET
			issue_cd = COALESCE(p_issue_cd, issue_cd),
            issue_sh_ds = COALESCE(p_issue_sh_ds, issue_sh_ds),
            issue_ds = COALESCE(p_issue_ds, issue_ds),
            module_id = COALESCE(p_module_id, module_id),
            line_id = COALESCE(p_line_id, line_id),
            kpi_category_id = COALESCE(p_kpi_category_id, kpi_category_id),
            opening_tier_id = COALESCE(p_opening_tier_id, opening_tier_id),
            comment_ds = COALESCE(p_comment_ds, comment_ds), 
            start_day_local_id = COALESCE(p_start_day_local_id, start_day_local_id),
            start_local_ts = COALESCE(lp_start_day_local_ts, start_local_ts),
            start_utc_ts = COALESCE(lp_start_day_utc_ts, start_utc_ts),
            end_day_local_id = COALESCE(p_end_day_local_id, end_day_local_id),
            end_local_ts = COALESCE(lp_end_day_local_ts, end_local_ts),
            end_utc_ts = COALESCE(lp_end_day_utc_ts, end_utc_ts),
            last_modified_utc_ts = procedure_ts,
            last_modified_local_day_id = lp_last_modified_local_day_id,
            last_modified_local_ts = lp_last_modified_local_ts,
            last_user = lp_last_user,
            shift_id = COALESCE(p_shift_id, shift_id),
			issue_priority_id = COALESCE(p_priority_id, issue_priority_id),
			issue_status_id = COALESCE(p_status_id, issue_status_id)
        WHERE plant_id = p_plant_id AND issue_id = p_issue_id;

    ELSIF p_operation_type = 'D' THEN
        DELETE FROM application_data.lk_issue
        WHERE plant_id = p_plant_id AND issue_id = p_issue_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation_type: %, must be I, U, or D.', p_operation_type;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR at step ' || lp_step::TEXT || ' ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_issue_files(in varchar, inout varchar, in int8, in numeric, in varchar, in varchar, in varchar, in varchar, in int8, in bool, in numeric, in varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_issue_files(p_operation_type character varying, INOUT out_flag character varying, p_plant_id bigint DEFAULT NULL::bigint, p_file_id numeric DEFAULT NULL::numeric, p_file_name character varying DEFAULT NULL::character varying, p_file_size character varying DEFAULT NULL::character varying, p_mimetype character varying DEFAULT NULL::character varying, p_relativeurl character varying DEFAULT NULL::character varying, p_issue_id bigint DEFAULT NULL::bigint, p_is_deleted boolean DEFAULT NULL::boolean, p_user_id numeric DEFAULT NULL::numeric, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
	procedure_ts timestamp := timezone('UTC', current_timestamp);
    lp_log_message TEXT;
    lp_procedure_name TEXT := 'application_data.manage_lk_issue_files';
  	lp_error_msg VARCHAR(2000);
	lp_step numeric;
  	lp_user	varchar;
BEGIN
	out_flag := 'ok';
	lp_user := p_user_id::TEXT || ' -- ' || p_user_fullname;
    -- Prepare input log message
    lp_log_message := 'Input: [operation_type: ' || COALESCE(p_operation_type, 'NULL') || 
					  ', plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
                      ', file_id: ' || COALESCE(p_file_id::TEXT, 'NULL') ||
                      ', file_name: ' || COALESCE(p_file_name, 'NULL') ||
                      ', file_size: ' || COALESCE(p_file_size, 'NULL') ||
                      ', mimeType: ' || COALESCE(p_mimetype, 'NULL') ||
                      ', relativeUrl: ' || COALESCE(p_relativeurl, 'NULL') ||
                      ', issue_id: ' || COALESCE(p_issue_id::TEXT, 'NULL') ||
                      ', is_deleted: ' || COALESCE(p_is_deleted::TEXT, 'NULL') ||
					  ', user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') ||
                      ', user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']';

    -- Log the input
	lp_step:=1;
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        procedure_ts,
        lp_procedure_name,
        lp_log_message,
        lp_user
    );

    -- Main operation
    IF p_operation_type = 'I' THEN
	lp_step:=2;
        INSERT INTO application_data.lk_issue_files (
            plant_id, file_id, file_name, file_size, mimeType, relativeUrl, issue_id, user_fullname, upload_timestamp, is_deleted)
        VALUES (
            p_plant_id, p_file_id, p_file_name, p_file_size, p_mimeType, p_relativeUrl, p_issue_id, lp_user, procedure_ts, FALSE)
        ON CONFLICT (file_id) DO NOTHING;

		lp_step:=3;
        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            'Inserted file_id: ' || p_file_id || 'associated with plant_id: '|| p_plant_id,
            lp_user
        );

    ELSIF p_operation_type = 'D' THEN
		lp_step:=4;
        DELETE FROM application_data.lk_issue_files WHERE file_id = p_file_id AND plant_id=p_plant_id;

		lp_step:=5;
        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            'Deleted file_id: ' || p_file_id || 'associated with plant_id: '|| p_plant_id,
            lp_user
        );

    ELSIF p_operation_type = 'LD' THEN
		lp_step:=6;
        UPDATE application_data.lk_issue_files
        SET is_deleted = TRUE
        WHERE file_id = p_file_id AND plant_id=p_plant_id;

		lp_step:=7;
        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            'Logical delete file_id: ' || p_file_id || 'associated with plant_id: '|| p_plant_id,
            lp_user
        );

    ELSE
		lp_step:=8;
        RAISE EXCEPTION 'Invalid action. Use INSERT or DELETE';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
 	 lp_error_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
           		'Step: ' || lp_step::text || ', ' || 
				'Input: [operation_type: ' || COALESCE(p_operation_type, 'NULL') || ', ' ||
 					  	', plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
						', file_id: ' || COALESCE(p_file_id::TEXT, 'NULL') ||
						', file_name: ' || COALESCE(p_file_name, 'NULL') ||
						', file_size: ' || COALESCE(p_file_size, 'NULL') ||
						', mimeType: ' || COALESCE(p_mimetype, 'NULL') ||
						', relativeUrl: ' || COALESCE(p_relativeurl, 'NULL') ||
						', issue_id: ' || COALESCE(p_issue_id::TEXT, 'NULL') ||
						', is_deleted: ' || COALESCE(p_is_deleted::TEXT, 'NULL') ||
						', user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') ||
						', user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']';
  	--Debug Version
        out_flag := lp_error_msg;
       INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            lp_error_msg,
            lp_user
        );
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_kpi(varchar, int8, varchar, varchar, int8, int8, int8, int8, int8, int8, int4, varchar, varchar, numeric, numeric, int4, int4, bool, bool, int4, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_kpi(operation_type character varying, p_kpi_id bigint DEFAULT NULL::bigint, p_kpi_code character varying DEFAULT NULL::character varying, p_kpi_ds character varying DEFAULT NULL::character varying, p_kpi_type_id bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_kpi_group_id bigint DEFAULT NULL::bigint, p_kpi_category_id bigint DEFAULT NULL::bigint, p_aggregation_rule_id bigint DEFAULT NULL::bigint, p_kpi_uom_id bigint DEFAULT NULL::bigint, p_kpi_sort integer DEFAULT NULL::integer, p_color_up_target_cd character varying DEFAULT NULL::character varying, p_color_down_target_cd character varying DEFAULT NULL::character varying, p_def_value numeric DEFAULT NULL::numeric, p_def_target numeric DEFAULT NULL::numeric, p_is_zero_display integer DEFAULT NULL::integer, p_is_automatic_value integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean, p_is_main_kpi boolean DEFAULT NULL::boolean, p_target_tendency_id integer DEFAULT NULL::integer, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;                 -- Last user info (combines ID and Fullname)
    lp_step NUMERIC;                      -- Step for debugging/logging
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_kpi'; -- Procedure name
    lp_err_msg VARCHAR(2000);             -- Error message
	lp_kpi_id_main NUMERIC;
BEGIN
    lp_step := 0;
	lp_kpi_id_main := 0;
    -- Log the operation input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_kpi_id: ' || COALESCE(p_kpi_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_code: ' || COALESCE(p_kpi_code, 'NULL') || ', ' ||
            'p_kpi_ds: ' || COALESCE(p_kpi_ds, 'NULL') || ', ' ||
			'p_kpi_type_id: ' || COALESCE(p_kpi_type_id::TEXT, 'NULL') || ', ' ||
 			'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_group_id: ' || COALESCE(p_kpi_group_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_category_id: ' || COALESCE(p_kpi_category_id::TEXT, 'NULL') || ', ' ||
            'p_aggregation_rule_id: ' || COALESCE(p_aggregation_rule_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_uom_id: ' || COALESCE(p_kpi_uom_id::TEXT, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || 
			'p_is_main_kpi: ' || COALESCE(p_is_main_kpi::TEXT, 'NULL') ||
 			'p_user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

	SELECT kpi_id INTO lp_kpi_id_main
	FROM application_data.lk_kpi kpi
	WHERE kpi_category_id=p_kpi_category_id
	AND kpi.kpi_type_id = p_kpi_type_id
	AND is_main_kpi = TRUE;

    -- Main CASE block to handle operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_kpi_code IS NULL OR p_plant_id IS NULL OR p_kpi_group_id IS NULL OR
               p_kpi_category_id IS NULL OR p_target_tendency_id IS NULL THEN
                lp_err_msg := 'ERROR: Required fields (kpi_code, plant_id, kpi_group_id, kpi_category_id, aggregation_rule_id, kpi_uom_id,target_tendency_id) cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;
		

            INSERT INTO application_data.lk_kpi (
                kpi_code,
                kpi_ds,
                plant_id,
				kpi_type_id,
                kpi_group_id,
                kpi_category_id,
                aggregation_rule_id,
                kpi_uom_id,
                kpi_sort,
                color_up_target_cd,
                color_down_target_cd,
                def_value,
                def_target,
                is_zero_display,
                is_automatic_value,
                is_active,
				is_main_kpi,
				target_tendency_id,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_kpi_code,
                p_kpi_ds,
                p_plant_id,
				p_kpi_type_id,
                p_kpi_group_id,
                p_kpi_category_id,
                coalesce(p_aggregation_rule_id,200),
                coalesce(p_kpi_uom_id,101),
                p_kpi_sort,
                p_color_up_target_cd,
                p_color_down_target_cd,
                p_def_value,
                p_def_target,
                COALESCE(p_is_zero_display, 1),
                COALESCE(p_is_automatic_value, 0),
                COALESCE(p_is_active, TRUE),
				COALESCE(p_is_main_kpi, FALSE),
				p_target_tendency_id,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

				IF (lp_kpi_id_main <> 0  AND p_is_main_kpi = TRUE ) THEN
			     UPDATE application_data.lk_kpi
            	 SET is_main_kpi= FALSE
				 WHERE kpi_id=lp_kpi_id_main;
				END IF;

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;
            UPDATE application_data.lk_kpi
            SET
                kpi_code = COALESCE(p_kpi_code, kpi_code),
                kpi_ds = COALESCE(p_kpi_ds, kpi_ds),
                kpi_group_id = COALESCE(p_kpi_group_id, kpi_group_id),
                kpi_category_id = COALESCE(p_kpi_category_id, kpi_category_id),
                aggregation_rule_id = COALESCE(p_aggregation_rule_id, aggregation_rule_id),
                kpi_uom_id = COALESCE(p_kpi_uom_id, kpi_uom_id),
                kpi_sort = COALESCE(p_kpi_sort, kpi_sort),
                color_up_target_cd = COALESCE(p_color_up_target_cd, color_up_target_cd),
                color_down_target_cd = COALESCE(p_color_down_target_cd, color_down_target_cd),
                def_value = COALESCE(p_def_value, def_value),
                def_target = COALESCE(p_def_target, def_target),
                is_zero_display = COALESCE(p_is_zero_display, is_zero_display),
                is_automatic_value = COALESCE(p_is_automatic_value, is_automatic_value),
                is_active = COALESCE(p_is_active, is_active),
				is_main_kpi = COALESCE(p_is_main_kpi, is_main_kpi),
				target_tendency_id= COALESCE(p_target_tendency_id,target_tendency_id),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE kpi_id = p_kpi_id ; --AND plant_id = p_plant_id;

			IF (lp_kpi_id_main <> 0  AND p_is_main_kpi = TRUE AND lp_kpi_id_main<>p_kpi_id ) THEN
			     UPDATE application_data.lk_kpi
            	 SET is_main_kpi= FALSE
				 WHERE kpi_id=lp_kpi_id_main;
			END IF;
			

        WHEN 'LD' THEN
            -- Logical Deletion
            lp_step := 3;
            UPDATE application_data.lk_kpi
            SET
                is_deleted = TRUE,
                is_active = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE kpi_id = p_kpi_id;-- AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Deletion
            lp_step := 4;
            DELETE FROM application_data.lk_kpi
            WHERE kpi_id = p_kpi_id;-- AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation_type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Log errors
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_kpi_category(varchar, int8, varchar, varchar, int4, int8, int8, varchar, bool);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_kpi_category(
    IN operation_type character varying,
    IN p_kpi_category_id bigint DEFAULT NULL::bigint,
    IN p_kpi_category_code character varying DEFAULT NULL::character varying,
    IN p_kpi_category_ds character varying DEFAULT NULL::character varying,
    IN p_kpi_category_sort integer DEFAULT NULL::integer,
    IN p_kpi_jira_category_id character varying DEFAULT NULL::character varying,
    IN p_plant_id bigint DEFAULT NULL::bigint,
    IN p_user_id bigint DEFAULT NULL::bigint,
    IN p_user_fullname character varying DEFAULT NULL::character varying,
    IN p_is_active boolean DEFAULT NULL::boolean
)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_kpi_category';
    lp_err_msg VARCHAR(2000);
BEGIN
    lp_step := 0;

    -- Log the operation
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_kpi_category_id: ' || COALESCE(p_kpi_category_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_category_code: ' || COALESCE(p_kpi_category_code, 'NULL') || ', ' ||
            'p_kpi_category_ds: ' || COALESCE(p_kpi_category_ds, 'NULL') || ', ' ||
            'p_kpi_category_sort: ' || COALESCE(p_kpi_category_sort::TEXT, 'NULL') || ', ' ||
            'p_kpi_jira_category_id: ' || COALESCE(p_kpi_jira_category_id, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Check if last_user details are provided
    IF p_user_fullname IS NULL OR p_user_id IS NULL OR p_plant_id IS NULL  THEN
        lp_err_msg := 'ERROR: User ID, Fullname or Plant cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Main CASE block for operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_kpi_category_code IS NULL OR p_kpi_category_sort IS NULL OR p_plant_id IS NULL THEN
                lp_err_msg := 'ERROR: kpi_category_code, kpi_category_sort and plant_id cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_kpi_category (
                kpi_category_code,
                kpi_category_ds,
                kpi_category_sort,
                plant_id,
                is_active,
                kpi_jira_category_id,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_kpi_category_code,
                p_kpi_category_ds,
                p_kpi_category_sort,
                p_plant_id,
                COALESCE(p_is_active, TRUE),
                p_kpi_jira_category_id,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;
            UPDATE application_data.lk_kpi_category
            SET
                kpi_category_code = COALESCE(p_kpi_category_code, kpi_category_code),
                kpi_category_ds = COALESCE(p_kpi_category_ds, kpi_category_ds),
                kpi_category_sort = COALESCE(p_kpi_category_sort, kpi_category_sort),
                is_active = COALESCE(p_is_active, is_active),
                kpi_jira_category_id = COALESCE(p_kpi_jira_category_id, kpi_jira_category_id),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE kpi_category_id = p_kpi_category_id AND plant_id = p_plant_id;

        WHEN 'LD' THEN
            -- Logical Deletion Operation
            lp_step := 3;
            UPDATE application_data.lk_kpi_category
            SET
                is_deleted = TRUE,
                is_active = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE kpi_category_id = p_kpi_category_id AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Deletion Operation
            lp_step := 4;
            DELETE FROM application_data.lk_kpi_category
            WHERE kpi_category_id = p_kpi_category_id AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.manage_lk_kpi_group(varchar, int8, varchar, varchar, int4, int8, int8, int8, varchar, bool);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_kpi_group(operation_type character varying, p_kpi_group_id bigint DEFAULT NULL::bigint, p_kpi_group_code character varying DEFAULT NULL::character varying, p_kpi_group_ds character varying DEFAULT NULL::character varying, p_kpi_group_sort integer DEFAULT NULL::integer, p_plant_id bigint DEFAULT NULL::bigint, p_kpi_category_id bigint DEFAULT NULL::bigint, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying, p_is_active boolean DEFAULT NULL::boolean)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_kpi_group';
    lp_err_msg VARCHAR(2000);
BEGIN
    lp_step := 0;

    -- Log the operation
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_kpi_group_id: ' || COALESCE(p_kpi_group_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_group_code: ' || COALESCE(p_kpi_group_code, 'NULL') || ', ' ||
            'p_kpi_group_ds: ' || COALESCE(p_kpi_group_ds, 'NULL') || ', ' ||
            'p_kpi_group_sort: ' || COALESCE(p_kpi_group_sort::TEXT, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_kpi_category_id: ' || COALESCE(p_kpi_category_id::TEXT, 'NULL') || ', ' ||
            'p_user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Check if last_user details are provided
    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Main CASE block for operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_kpi_group_code IS NULL OR p_kpi_group_sort IS NULL OR p_kpi_group_ds IS NULL OR p_plant_id IS NULL OR p_kpi_category_id IS NULL THEN
                lp_err_msg := 'ERROR: kpi_group_code, kpi_group_ds, kpi_group_sort, plant_id, and kpi_category_id cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_kpi_group (
                kpi_group_code,
                kpi_group_ds,
                kpi_group_sort,
                plant_id,
                kpi_category_id,
                is_active,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_kpi_group_code,
                p_kpi_group_ds,
                p_kpi_group_sort,
                p_plant_id,
                p_kpi_category_id,
                COALESCE(p_is_active, FALSE),
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;
            UPDATE application_data.lk_kpi_group
            SET
                kpi_group_code = COALESCE(p_kpi_group_code, kpi_group_code),
                kpi_group_ds = COALESCE(p_kpi_group_ds, kpi_group_ds),
                kpi_group_sort = COALESCE(p_kpi_group_sort, kpi_group_sort),
				kpi_category_id = COALESCE(p_kpi_category_id, kpi_category_id),    
				is_active = COALESCE(p_is_active, is_active),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE kpi_group_id = p_kpi_group_id AND plant_id = p_plant_id; --AND kpi_category_id = p_kpi_category_id;

        WHEN 'LD' THEN
            -- Logical Deletion Operation
            lp_step := 3;
            UPDATE application_data.lk_kpi_group
            SET
                is_deleted = TRUE,
                is_active = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE kpi_group_id = p_kpi_group_id AND plant_id = p_plant_id AND kpi_category_id = p_kpi_category_id;

        WHEN 'D' THEN
            -- Physical Deletion Operation
            lp_step := 4;
            DELETE FROM application_data.lk_kpi_group
            WHERE kpi_group_id = p_kpi_group_id AND plant_id = p_plant_id AND kpi_category_id = p_kpi_category_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_line(varchar, int8, varchar, varchar, varchar, int8, varchar, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_line(operation_type character varying, p_line_id bigint DEFAULT NULL::bigint, p_line_code character varying DEFAULT NULL::character varying, p_line_code_erp character varying DEFAULT NULL::character varying, p_line_ds character varying DEFAULT NULL::character varying, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying, p_is_active boolean DEFAULT NULL::boolean, p_module_id bigint DEFAULT NULL::bigint, p_process_key character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:		
-- @Company:    Decisyon
-- @Project:    SQDIP
-- @Version:	
-- @Date:		
-- @ChangeHis:
--
-- @Description: 
--    Procedure to manage the line lookup table, allowing for create, update, and logical delete operations according
--      to the value of param operation_type.
-- 
--    Params:
--      - operation_type (character varying):                   The type of operation to be performed (CREATE, UPDATE, DELETE).
--      - p_line_id (bigint, DEFAULT NULL):                     The ID of the line.
--      - p_line_code (character varying, DEFAULT NULL):        The code of the line.
--      - p_line_code_erp (character varying, DEFAULT NULL):    The ERP code of the line.
--      - p_process_key (character varying, DEFAULT NULL):      The ProcessKey used to bind the line to a specific DWH source schema (matches DWH [Process].ProcessKey).
--      - p_line_ds (character varying, DEFAULT NULL):          The description of the line.
--     
--      - p_user_id (bigint, DEFAULT NULL):                     Identifier of the last user who modified the company.
--      - p_user_fullname (character varying, DEFAULT NULL):    Fullname of the last user who modified the company.
--      - p_is_active (boolean, DEFAULT NULL):                  Indicator if the line is active.
--      - p_module_id (bigint, DEFAULT NULL):                   The ID of the module associated with the line.
-- ============================================================================================================
DECLARE
    lp_last_user varchar;
    -- plant_id for tenant purpose
    lp_plant_id bigint;	
	lp_kpi_safety_id bigint; 
	lp_line_id bigint;
    -- Params to log errors
    lp_step numeric;
    lp_procedure_name varchar(50) := 'application_data.manage_lk_line';
    lp_err_msg varchar(2000);
	v_image_ref varchar;

  -- Cursor declaration for rows in lk_tier filtered by plant_id
    tier_cursor CURSOR FOR
    SELECT tier_id
    FROM application_data.lk_tier
    WHERE plant_id = lp_plant_id
    AND is_active = true
    AND is_deleted = false
    ORDER BY tier_sort;

    -- Variable to hold current row from cursor
    v_tier_id BIGINT;

BEGIN
    lp_step := 0;
    --Log operation
    Insert into application_data.log_operation (
        operation_timestamp,
	    operation_src,
	    operation_msg,
	    operation_caller
    ) values (
        timezone('UTC',current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_line_id: '  || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_line_code: '  || COALESCE(p_line_code, 'NULL') || ', ' ||
            'p_line_code_erp: '  || COALESCE(p_line_code_erp, 'NULL') || ', ' ||
            'p_process_key: '  || COALESCE(p_process_key, 'NULL') || ', ' ||
            'p_line_ds: '  || COALESCE(p_line_ds, 'NULL') || ', ' ||
            'p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_module_id: ' || COALESCE(p_module_id::text, 'NULL') || ', ' || ']',
        p_user_id::text || ' -- ' || p_user_fullname
    );
    
    -- Check if last_user is NULL
    lp_step := 0.1;
    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        lp_err_msg := 'ERROR LAST USER FULLNAME AND ID CANNOT BE NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_last_user := p_user_id::text || ' -- ' || p_user_fullname;
 
   -- Retrieve plant_id 
    SELECT plant_id 
    INTO lp_plant_id
    FROM application_data.lk_module md 
    WHERE md.module_id = p_module_id;

	-- Retrieve id kpi safety 
    SELECT kpi_id 
    INTO lp_kpi_safety_id
    FROM application_data.lk_kpi kpi 
    WHERE kpi.kpi_code = 'safety events' and kpi.plant_id=lp_plant_id;
    
    -- Main CASE block to handle different operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insertion Operation
            lp_step := 1;
            -- Check if any of the required values are NULL
            IF p_line_code IS NULL OR p_line_ds IS NULL OR p_module_id IS NULL THEN
                lp_err_msg := 'ERROR VALUES CANNOT BE NULL TO INSERT A NEW LINE';
            END IF;

            lp_step := 1.1;

            -- currently we don't define an image in the line although we have the field
                v_image_ref := NULL;
           
            -- Insert a new record into the lk_line table
            -- Get id next value
            lp_step := 1.2;

            -- Create new line
            lp_step := 1.3;
            INSERT INTO application_data.lk_line (
                line_code,
                line_code_erp,
                process_key,
                line_ds,
                module_id,
                plant_id,
                image_ref,
                creation_ts,
                creator_user,
                last_user,
                last_modified,
				is_active
            ) VALUES (
                p_line_code, 
                p_line_code_erp, 
                p_process_key,
                p_line_ds, 
                p_module_id, 
                lp_plant_id,
                v_image_ref, 
                timezone('UTC',current_timestamp), 
                lp_last_user, 
                lp_last_user, 
                timezone('UTC',current_timestamp),
				p_is_active
            );

			select
				line_id into lp_line_id
			from
				application_data.lk_line
			where
				line_code = p_line_code
				and plant_id = lp_plant_id;

        
  BEGIN
    -- Open cursor
    OPEN tier_cursor;

		LOOP
        -- Fetch next row
        FETCH tier_cursor INTO v_tier_id;
        EXIT WHEN NOT FOUND;

	            -- call the procedure
	            CALL application_data.manage_assoc_module_line_tier_kpi(
	                'I',                      -- action type (Insert)
	                NULL,                     -- parameter left NULL as per your example
	                lp_kpi_safety_id,         -- lp_kpi_safety_id
	                v_tier_id,                -- current tier_id from cursor
	                lp_line_id,                -- lp_line_id
	                p_module_id,              -- p_module_id
	                lp_plant_id,               -- lp_plant_id
	                TRUE,                     -- always true
	                p_user_id,                -- p_user_id
	                p_user_fullname           -- p_user_fullname
	            );
	    
          END LOOP;

    -- Close cursor
     CLOSE tier_cursor;
	 
	 INSERT INTO application_data.sh_lk_line_pattern_default
	(plant_id, line_id, week_day_id,au_user_id,au_change_type,au_change_day_id,au_change_ts)
	SELECT
	 lp_plant_id,
	 lp_line_id,
	 generate_series(1, 7),
	1111111111111,
	'I',
	to_char(timezone('UTC',current_timestamp),'YYYYMMDD')::INT,
	timezone('UTC',current_timestamp);

	END;
		
        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;
            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_line
            WHERE line_id = p_line_id AND is_editable = false;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR IS_EDITABLE CANNOT BE FALSE';
            END IF;

            v_image_ref := NULL;
      
            -- Update the record in the lk_line table
            lp_step := 2.1;
            UPDATE application_data.lk_line
            SET
                module_id  = COALESCE(p_module_id, module_id),						-- Update module_id if provided
				line_code = COALESCE(p_line_code, line_code),						-- Update line_code if provided
				line_code_erp = COALESCE(p_line_code_erp, line_code_erp),			-- Update line_code_erp if provided
				process_key = COALESCE(p_process_key, process_key),					-- Update process_key if provided
				line_ds = COALESCE(p_line_ds, line_ds),								-- Update line_ds if provided
				image_ref = COALESCE(v_image_ref, image_ref),						-- Update image_ref if provided
				last_user = lp_last_user,											-- Update last_user
				last_modified = timezone('UTC',current_timestamp),					-- Set last_modified to current timestamp
				is_active = COALESCE(p_is_active, is_active)						-- Update is_active if provided
            WHERE line_id = p_line_id;

        WHEN 'LD' THEN
            -- Logical Deletion Operation
            lp_step := 3;
            UPDATE application_data.lk_line
            SET 
				line_code= line_code||'***'||line_id||'***',
				is_deleted=true,
				is_active=false,
				is_editable=false
 			 WHERE line_id = p_line_id;

        WHEN 'D' THEN
            -- Physical Deletion Operation
            -- Delete the record from the lk_line table
            lp_step := 4;
            DELETE FROM application_data.lk_line WHERE line_id = p_line_id;
        ELSE
            -- Invalid operation type
            RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';
    END CASE;
EXCEPTION
    WHEN OTHERS THEN
        -- Catch all exceptions and log them
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
            'lp_step: ' || lp_step::text || ', ' ||
            'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_line_code: ' || COALESCE(p_line_code, 'NULL') || ', ' ||
            'p_line_code_erp: ' || COALESCE(p_line_code_erp, 'NULL') || ', ' ||
            'p_process_key: '  || COALESCE(p_process_key, 'NULL') || ', ' ||
            'p_line_ds: ' || COALESCE(p_line_ds, 'NULL') || ', ' ||
            'V_image_ref: ' || COALESCE(V_image_ref, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_module_id: ' || COALESCE(p_module_id::text, 'NULL') || ', ' || ']';
		begin	       
          	INSERT INTO application_data.log_error (
	            error_timestamp,
	            error_src, 
	            error_msg,
                error_caller
	        ) VALUES (
	            timezone('UTC',current_timestamp),
	            lp_procedure_name,
	            lp_err_msg,
                p_user_id::text || ' -- ' || p_user_fullname
	        );
	       	commit;
	    end;
        RAISE;
END;
$procedure$
;



-- DROP PROCEDURE application_data.manage_lk_machine(varchar, int8, varchar, varchar, int8, int8, int8, bool, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_machine(p_operation_type character varying, p_machine_id bigint DEFAULT NULL::bigint, p_machine_code character varying DEFAULT NULL::character varying, p_machine_ds character varying DEFAULT NULL::character varying, p_machine_sort bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_is_active boolean DEFAULT NULL::boolean, p_fpy_active boolean DEFAULT NULL::boolean, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_machine';
    lp_err_msg VARCHAR(2000);
    lp_log_message TEXT;
    v_line_id INT8;
    v_component_id INT8;
    i INT;
    cur_component CURSOR FOR 
        SELECT component_id FROM application_data.lk_component 
        WHERE machine_id = p_machine_id
          AND plant_id = p_plant_id;
          
    -- Variables for lk_machine_target
    lp_new_machine_id BIGINT;
    lp_start_date_local TIMESTAMP WITHOUT TIME ZONE;
    lp_start_date_utc TIMESTAMP WITHOUT TIME ZONE;
    lp_start_date_id NUMERIC(8);
    lp_plant_timezone VARCHAR;
BEGIN
    lp_step := 0;

    -- Validate mandatory user fields
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Create log message with all input parameters
    lp_log_message := 
        'Operation Type: ' || COALESCE(p_operation_type::TEXT,'NULL') || ', ' ||
        'Machine ID: ' || COALESCE(p_machine_id::TEXT, 'NULL') || ', ' ||
        'Machine Code: ' || COALESCE(p_machine_code::TEXT, 'NULL') || ', ' ||
        'Machine DS: ' || COALESCE(p_machine_ds::TEXT, 'NULL') || ', ' ||
		'Machine Sort: ' || COALESCE(p_machine_sort::TEXT, 'NULL') || ', ' || 
        'Plant ID: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
        'Line ID: ' || COALESCE(p_line_id::TEXT, 'NULL') || ', ' ||
        'Is Active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ', ' ||
        'FPY Active: ' || COALESCE(p_fpy_active::TEXT, 'NULL') || ', ' ||
        'User ID: ' ||  COALESCE(p_user_id::TEXT, 'NULL')  || ', ' ||
        'User Fullname: ' || COALESCE(p_user_fullname::TEXT, 'NULL') ;

    -- Logging the operation
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_log_message,
        lp_last_user
    );

    -- Perform actions based on the operation type
    CASE p_operation_type
        WHEN 'I' THEN
            -- Insert a new record
            lp_step := 1;

            -- Validate required fields
            IF p_machine_code IS NULL OR p_machine_ds IS NULL OR p_plant_id IS NULL OR p_line_id IS NULL  OR p_machine_sort IS NULL THEN
                lp_err_msg := 'ERROR: Required values cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_machine (
                machine_code,
                machine_ds,
				machine_sort,
                plant_id,
                line_id,
                is_active,
                fpy_active,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_machine_code,
                p_machine_ds,
				p_machine_sort,
                p_plant_id,
                p_line_id,
                p_is_active,
                COALESCE(p_fpy_active, true),
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            ) RETURNING machine_id INTO lp_new_machine_id;


/* ***********   This section has been commented. It's not needed create the target record when a machine is created ***************************

            -- Get the plant's timezone
            SELECT plant_timezone INTO lp_plant_timezone
            FROM application_data.lk_plant
            WHERE plant_id = p_plant_id;

            IF lp_plant_timezone IS NULL THEN
                RAISE EXCEPTION 'ERROR: Plant timezone not found for plant_id %', p_plant_id;
            END IF;


			-- Convert CURRENT_TIMESTAMP to local timezone
 			SELECT  CURRENT_TIMESTAMP AT TIME ZONE lp_plant_timezone
            INTO lp_start_date_local;

			SELECT  CURRENT_TIMESTAMP AT TIME ZONE 'UTC'
            INTO lp_start_date_utc;
            -- Convert to YYYYMMDD format
            SELECT TO_CHAR(lp_start_date_local, 'YYYYMMDD')::NUMERIC(8)
            INTO lp_start_date_id;

            -- Insert into `lk_machine_target`
            INSERT INTO application_data.lk_machine_target (
                machine_id, line_id, plant_id, target_value, start_date_local, start_date_utc, start_date_id, end_date_local,end_date_utc, end_date_id, 
                creation_ts, creator_user, last_modified, last_user, is_active
            ) VALUES (
                lp_new_machine_id, p_line_id, p_plant_id, 0.0, lp_start_date_local, lp_start_date_utc, lp_start_date_id, NULL, NULL, NULL, 
                timezone('UTC', current_timestamp), lp_last_user, 
                timezone('UTC', current_timestamp), lp_last_user,
				false
            );

*/

        WHEN 'U' THEN
            -- Update an existing record
            lp_step := 2;

            SELECT line_id INTO v_line_id
            FROM application_data.lk_machine 
            WHERE machine_id = p_machine_id
              AND plant_id = p_plant_id;

            -- Validate Machine ID and Plant ID
            lp_step := 2.1;
            IF p_machine_id IS NULL OR p_plant_id IS NULL THEN
                lp_err_msg := 'ERROR: Machine ID and Plant ID cannot be NULL for update.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            UPDATE application_data.lk_machine
            SET 
                machine_code = COALESCE(p_machine_code, machine_code),
                machine_ds = COALESCE(p_machine_ds, machine_ds),
				machine_sort = COALESCE(p_machine_sort, machine_sort),
                line_id = COALESCE(p_line_id, line_id),
                is_active = COALESCE(p_is_active, is_active),
                fpy_active = COALESCE(p_fpy_active, fpy_active),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE machine_id = p_machine_id
              AND plant_id = p_plant_id;

            -- Process components if the line_id has changed
            lp_step := 2.2;
            IF p_line_id <> v_line_id THEN  
                i := 2;                
                OPEN cur_component;
                LOOP
                    FETCH cur_component INTO v_component_id;
                    EXIT WHEN NOT FOUND;
                    i := i + 1;
                    lp_step := ('2.' || i)::NUMERIC;
                    CALL application_data.manage_lk_component(
                        'U', v_component_id, NULL, NULL, p_plant_id, p_line_id, p_machine_id, NULL, p_user_id, p_user_fullname
                    );
                    RAISE NOTICE 'Processing component_id: %', v_component_id;
                END LOOP;
            END IF;

        WHEN 'LD' THEN
            -- Logical Delete (soft delete)
            lp_step := 3;

            UPDATE application_data.lk_machine
            SET 
				machine_code = machine_code||'***'||machine_id||'***',
				is_deleted = TRUE,
                is_active = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE machine_id = p_machine_id
              AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Delete (hard delete)
            lp_step := 4;

            DELETE FROM application_data.lk_machine
            WHERE machine_id = p_machine_id
              AND plant_id = p_plant_id;

        ELSE
            -- Invalid Operation Type
            RAISE EXCEPTION 'ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Delete).';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Capture errors and log them
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', Step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_machine_target(varchar, int8, int8, int8, int8, int8, numeric, numeric, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_machine_target(IN p_operation_type character varying, IN p_machine_target_id bigint DEFAULT NULL::bigint, IN p_machine_id bigint DEFAULT NULL::bigint, IN p_line_id bigint DEFAULT NULL::bigint, IN p_kpi_id bigint DEFAULT NULL::bigint, IN p_plant_id bigint DEFAULT NULL::bigint, IN p_target_value numeric DEFAULT NULL::numeric, IN p_target_weight numeric DEFAULT NULL::numeric, IN p_user_id bigint DEFAULT NULL::bigint, IN p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_machine_target';
    lp_err_msg VARCHAR(2000);
    lp_start_date_local TIMESTAMP WITHOUT TIME ZONE;
	lp_start_date_utc TIMESTAMP WITHOUT TIME ZONE;
    lp_start_date_id NUMERIC(8);
    lp_end_date_local TIMESTAMP WITHOUT TIME ZONE;
	lp_end_date_utc TIMESTAMP WITHOUT TIME ZONE;
    lp_end_date_id NUMERIC(8);
    lp_plant_timezone VARCHAR;
	lp_current_timestamp TIMESTAMP WITHOUT TIME ZONE;
	lp_current_start_date TIMESTAMP WITHOUT TIME ZONE;
BEGIN
    lp_step := 0;
	lp_current_timestamp := CURRENT_TIMESTAMP;
	 Insert into application_data.log_operation (
        operation_timestamp,
	    operation_src,
	    operation_msg,
	    operation_caller
    ) values (
        timezone('UTC',current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(p_operation_type::text, 'NULL') || ', ' ||
	 		'p_machine_target_id: '  || COALESCE(p_machine_target_id::text, 'NULL') || ', ' ||
            'p_machine_id: '  || COALESCE(p_machine_id::text, 'NULL') || ', ' ||
            'p_plant_id: '  || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
			'p_kpi_id: '  || COALESCE(p_kpi_id::text, 'NULL') || ', ' ||
			'p_line_id: '  || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_target_value: '  || COALESCE(p_target_value::text, 'NULL') || ', ' ||
			'p_target_weight: '  || COALESCE(p_target_weight::text, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname::text, 'NULL') || ', ]',
        p_user_id::text || ' -- ' || p_user_fullname::text
    );
    -- Validate mandatory fields
		lp_step := 1;
     IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

		lp_step := 2;
    IF p_machine_id IS NULL OR p_plant_id IS NULL  OR p_line_id IS NULL OR p_target_value IS NULL THEN
        lp_err_msg := 'ERROR: Machine ID, Plant ID, Line ID and Target Value cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
	
		  lp_step := 3;
    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

		  lp_step := 4;
    -- Get the plant's timezone
    SELECT plant_timezone INTO lp_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;

		  lp_step := 5;
    IF lp_plant_timezone IS NULL THEN
        RAISE EXCEPTION 'ERROR: Plant timezone not found for plant_id %', p_plant_id;
    END IF;

		  lp_step := 6;
    CASE p_operation_type
        WHEN 'I' THEN
			PERFORM 1 FROM 		
			application_data.lk_machine_target
  			WHERE machine_id = p_machine_id
            AND plant_id = p_plant_id
			AND line_id = p_line_id
			AND kpi_id = p_kpi_id;
				IF FOUND THEN
		            -- Assign next day's midnight as start_date
		            SELECT DATE_TRUNC('day', (lp_current_timestamp AT TIME ZONE lp_plant_timezone) + INTERVAL '1 day'),
						   DATE_TRUNC('day', (lp_current_timestamp AT TIME ZONE lp_plant_timezone) + INTERVAL '1 day')::TIMESTAMP AT TIME ZONE lp_plant_timezone  AT TIME ZONE 'UTC'
		            INTO lp_start_date_local,lp_start_date_utc;
		
						lp_step := 7;
		            -- Convert start_date to YYYYMMDD format
		            SELECT TO_CHAR(lp_start_date_local, 'YYYYMMDD')::NUMERIC(8) INTO lp_start_date_id;
		
						lp_step := 8;			
					-- Set the end date for the existing record
					lp_end_date_local := lp_start_date_local - INTERVAL '1 second';
					lp_end_date_utc := lp_start_date_utc - INTERVAL '1 second';
		
							lp_step := 9;
					-- Set the end date id for the existing record
					lp_end_date_id := TO_CHAR(lp_start_date_local - INTERVAL '1 second', 'YYYYMMDD')::NUMERIC(8);
	
							lp_step := 10;	
					SELECT max(start_date_local) INTO lp_current_start_date
					FROM application_data.lk_machine_target
					WHERE machine_id = p_machine_id
					AND plant_id = p_plant_id
					AND line_id = p_line_id
					AND kpi_id = p_kpi_id
					AND end_date_local IS NULL
					AND end_date_utc IS NULL
					AND end_date_id IS NULL; 

						IF 
						lp_current_start_date >= lp_start_date_local
						THEN 
						 RAISE EXCEPTION 'IT IS NOT POSSIBLE TO ENTER A NEW TARGET. THERE IS ALREADY A NEW TARGET THAT WILL BE ACTIVATED SOON.
										  PLEASE CHECK THE TARGET YOU ARE SETTING ';
						END IF;
				
				ELSE 
							lp_step := 11;	
					    -- Assign start_date as first day of current local year
						SELECT	DATE_TRUNC('year', (lp_current_timestamp AT TIME ZONE lp_plant_timezone)),
	 							DATE_TRUNC('year', (lp_current_timestamp AT TIME ZONE lp_plant_timezone))::TIMESTAMP AT TIME ZONE lp_plant_timezone AT TIME ZONE 'UTC'
		      			INTO	lp_start_date_local,lp_start_date_utc;
		
						lp_step := 12;
		            -- Convert start_date to YYYYMMDD format
		            SELECT TO_CHAR(lp_start_date_local, 'YYYYMMDD')::NUMERIC(8) INTO lp_start_date_id;
				END IF; 	
			
           

        -- Close existing active records (set end_date as previous midnight)
            UPDATE application_data.lk_machine_target
            SET 
                end_date_local = lp_end_date_local, 
				end_date_utc = lp_end_date_utc, 
                end_date_id = lp_end_date_id
            WHERE machine_id = p_machine_id
              AND plant_id = p_plant_id
			  AND line_id = p_line_id
			  AND kpi_id = p_kpi_id
              AND end_date_local IS NULL
			  AND end_date_utc IS NULL
			  AND end_date_id IS NULL;

				  lp_step := 13;
            -- Insert new record with start_date as next midnight
          insert
			into
			application_data.lk_machine_target (
		    machine_id,
			plant_id,
			line_id ,
			kpi_id,
			target_value,
			target_weight,
			start_date_local,
			start_date_utc ,
			start_date_id,
			end_date_local,
			end_date_utc,
			end_date_id,
			is_active,
			is_deleted,
			creation_ts,
			creator_user,
			last_modified,
			last_user)
			VALUES (
			p_machine_id,
			p_plant_id,
			p_line_id ,
			p_kpi_id,
			p_target_value,
			coalesce(p_target_weight,1),
			lp_start_date_local,
			lp_start_date_utc,
			lp_start_date_id,
			null,
			null ,
			null,
			false,
			false,
			timezone('UTC',
			current_timestamp),
			lp_last_user,
			timezone('UTC',
			current_timestamp),
			lp_last_user);

				  lp_step := 14;
        WHEN 'U' THEN
            -- Only update target_value
            UPDATE application_data.lk_machine_target
            SET target_value = coalesce(p_target_value,target_value),
				target_weight= coalesce(p_target_weight,1),
				kpi_id = p_kpi_id,
                last_modified = timezone('UTC', current_timestamp),
                last_user = lp_last_user
             WHERE machine_id = p_machine_id
              AND plant_id = p_plant_id
			  AND line_id = p_line_id
			  AND machine_target_id = p_machine_target_id
              AND end_date_local IS NULL
			  AND end_date_utc IS NULL
			  AND end_date_id IS NULL;
        WHEN 'D' THEN
            -- Physical delete
            DELETE FROM application_data.lk_machine_target
             WHERE machine_id = p_machine_id
               AND plant_id = p_plant_id
			   AND line_id = p_line_id
			   AND machine_target_id = p_machine_target_id;
        WHEN 'LD' THEN
            -- Logical delete
            UPDATE application_data.lk_machine_target
               SET is_deleted = true,
                   is_active = false,
                   last_modified = timezone('UTC', current_timestamp),
                   last_user = lp_last_user
             WHERE machine_id = p_machine_id
               AND plant_id = p_plant_id
			   AND line_id = p_line_id
			   AND machine_target_id = p_machine_target_id;
        ELSE
            RAISE EXCEPTION 'ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), D (Delete), LD (Logical Delete).';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Capture errors and log them
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', Step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_module(varchar, int8, varchar, varchar, int8, varchar, int8, varchar, bool);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_module(operation_type character varying, p_module_id bigint DEFAULT NULL::bigint, p_module_code character varying DEFAULT NULL::character varying, p_module_ds character varying DEFAULT NULL::character varying, p_plant_id bigint DEFAULT NULL::bigint, p_creator_user character varying DEFAULT NULL::character varying, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying, p_is_active boolean DEFAULT NULL::boolean)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:		
-- @Company:    Decisyon
-- @Project:    SQDIP
-- @Version:	
-- @Date:		
-- @ChangeHis:
--
-- @Description: 
--    Procedure to manage the module lookup table, allowing for create, update, and logical delete operations according
--      to the value of param operation_type.
-- 
--    Params:
--      - operation_type (character varying):                   The type of operation to be performed (CREATE, UPDATE, DELETE).
--      - p_module_id (bigint, DEFAULT NULL):               	The ID of the module.
--      - p_module_code (character varying, DEFAULT NULL):  	The code of the module.
--      - p_module_ds (character varying, DEFAULT NULL):    	The description of the module.
--      - p_plant_id (bigint, DEFAULT NULL):                    The ID of the plant associated with the module.
--      - p_creator_user (character varying, DEFAULT NULL):     The user who created the module.
--      - p_user_id (bigint, DEFAULT NULL):                     Identifier of the last user who modified the company.
--      - p_user_fullname (character varying, DEFAULT NULL):    Fullname of the last user who modified the company.
--      - p_is_active (boolean, DEFAULT NULL):                  Indicator if the module is active.
--      - p_image_ref (character varying, DEFAULT NULL):        Reference to an image associated with the module.
-- ============================================================================================================
DECLARE
    -- Params to log errors
	step 			numeric;
	procedure_name	varchar(50) := 'application_data.manage_lk_module';
	err_msg			varchar(2000);
	p_last_user 	varchar;
	v_creator_user 	varchar;
	v_module_id 	int8;
	v_start_procedure timestamp;

BEGIN
    step := 0;
	v_start_procedure := timezone('UTC',current_timestamp);
    --Log operation
    Insert into application_data.log_operation (
        operation_timestamp,
	    operation_src,
	    operation_msg,
	    operation_caller
    ) values (
        timezone('UTC',current_timestamp),
        procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_module_id: '  || COALESCE(p_module_id::text, 'NULL') || ', ' ||
            'p_module_code: '  || COALESCE(p_module_code, 'NULL') || ', ' ||
            'p_module_ds: '  || COALESCE(p_module_ds, 'NULL') || ', ' ||
            'p_creator_user: '  || COALESCE(p_creator_user, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: '  || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_plant_id: '  || COALESCE(p_plant_id::text, 'NULL') || ', ' || ']',
        p_user_id::text || ' -- ' || p_user_fullname
    );


    -- Check if last_user is NULL
    step := 0.1;
    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        err_msg := 'ERROR LAST USER FULLNAME AND ID CANNOT BE NULL.';
        RAISE EXCEPTION '%', err_msg;
    END IF;
	v_creator_user := p_user_id::text || ' -- ' || p_user_fullname;
    p_last_user := p_user_id::text || ' -- ' || p_user_fullname;

    -- Main CASE block to handle different operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert operation
            step := 1;
            -- Check if any required values are NULL
            IF p_module_code IS NULL OR p_module_ds IS NULL OR p_creator_user IS NULL OR p_plant_id IS NULL THEN
                RAISE EXCEPTION 'ERROR VALUES CANNOT BE NULL TO INSERT A NEW MODULE';
            END IF;
            -- Insert a new record into the lk_module table
            INSERT INTO application_data.lk_module (
                module_code,
				module_ds,
				creator_user,
				last_user,
				plant_id,
				is_active
			--	image_ref
            ) VALUES (
                p_module_code, 
                p_module_ds, 
                v_creator_user, 
                p_last_user, 
                p_plant_id,
				p_is_active
             --   p_image_ref
            ) RETURNING module_id INTO v_module_id;

			-- Initialization insert Undefined line associated with the new Module into lk_line table
			step := 1.1;
			INSERT INTO application_data.lk_line (
				line_code,
				line_code_erp,
				line_ds,
				plant_id,
				module_id,
				creation_ts,
				creator_user,
				is_active,
				is_deleted,
				is_editable,
				last_modified,
				last_user
			) VALUES (
				'(U)',
				'(U)',
				'<#Undefined/>',
				p_plant_id,
				v_module_id,
				v_start_procedure,
				'1111111111111 -- Administrator',
				false,
				false,
				false,
				v_start_procedure,
				'1111111111111 -- Administrator'
			);
        WHEN 'U' THEN
            -- Update operation
            step := 2;
            
            -- Check if the record is editable
            PERFORM 1 
            FROM application_data.lk_module
            WHERE module_id = p_module_id
                AND is_editable = false;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR IS_EDITABLE CANNOT BE FALSE';
            END IF;
            
            -- Update the record in the lk_module table
            UPDATE application_data.lk_module
            SET
                module_code = COALESCE(p_module_code, module_code),				-- Update module_code if provided
				module_ds = COALESCE(p_module_ds, module_ds),					-- Update module_ds if provided
				last_user = p_last_user,										-- Update last_user
				last_modified = timezone('UTC',current_timestamp),				-- Set last_modified to current timestamp
				is_active = COALESCE(p_is_active, is_active)					-- Update is_active if provided
				--image_ref = COALESCE(p_image_ref, image_ref)					-- Update image_ref if provided
            WHERE module_id = p_module_id;
		
	  WHEN 'LD' THEN
            -- Logical Deletion Operation
            UPDATE application_data.lk_module
            SET 
				module_code= module_code||'***'||module_id||'***',
				is_deleted=true,
				is_active=false,
				is_editable=false
			WHERE module_id = p_module_id;
        WHEN 'D' THEN
            -- Physical Deletion Operation
            -- Delete the record from the lk_module table
            DELETE FROM application_data.lk_module WHERE module_id = p_module_id;
        ELSE
            -- Invalid operation type
            RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';
    END CASE;
EXCEPTION
    WHEN OTHERS THEN
        -- Catch all exceptions and log them
        err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
            'Step: ' || step::text || ', ' ||
            'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_module_id: ' || COALESCE(p_module_id::text, 'NULL') || ', ' ||
            'p_module_code: ' || COALESCE(p_module_code, 'NULL') || ', ' ||
            'p_module_ds: ' || COALESCE(p_module_ds, 'NULL') || ', ' ||
            'p_creator_user: ' || COALESCE(p_creator_user, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname, 'NULL') || ', ' ||           
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || ', ' || ']';
        begin
            INSERT INTO application_data.log_error (
                error_timestamp,
                error_src, 
                error_msg,
                error_caller
            ) VALUES (
                timezone('UTC',current_timestamp),
                procedure_name,
                err_msg,
                p_user_id::text || ' -- ' || p_user_fullname
            );
            commit;
        end;
        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.manage_lk_plant(in varchar, inout varchar, inout int8, in varchar, in varchar, in int8, in varchar, in varchar, in float8, in float8, in bool, in int8);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_plant(operation_type character varying, INOUT out_flag character varying, INOUT p_plant_id bigint DEFAULT NULL::bigint, p_plant_code character varying DEFAULT NULL::character varying, p_plant_ds character varying DEFAULT NULL::character varying, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying, p_plant_timezone character varying DEFAULT NULL::character varying, p_latitude double precision DEFAULT NULL::numeric, p_longitude double precision DEFAULT NULL::numeric, p_is_active boolean DEFAULT NULL::boolean, p_organization_id bigint DEFAULT NULL::bigint)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:		
-- @Company:    Decisyon
-- @Project:    SQDIP
-- @Version:	
-- @Date:		
-- @ChangeHis:
--
-- @Description: 
--    Procedure to manage the plant lookup table, allowing for create, update, and  delete operations according
--      to the value of param operation_type.
-- 
--    Params:
--      - operation_type (character varying):                   The type of operation to be performed (CREATE, UPDATE, DELETE).
--      - p_plant_id (bigint, DEFAULT NULL):                    The ID of the plant.
--      - p_plant_code (character varying, DEFAULT NULL):       The code of the plant.
--      - p_plant_ds (character varying, DEFAULT NULL):         The description of the plant.
--      - p_creator_user (character varying, DEFAULT NULL):     The user who created the plant.
--      - p_user_id (bigint, DEFAULT NULL):                     Identifier of the last user who modified the company.
--      - p_user_fullname (character varying, DEFAULT NULL):    Fullname of the last user who modified the company.
--      - p_plant_timezone (character varying, DEFAULT NULL):   The timezone of the plant.
--      - p_latitude (numeric, DEFAULT NULL):                   The latitude of the plant location.
--      - p_longitude (numeric, DEFAULT NULL):                  The longitude of the plant location.
--      - p_is_active (boolean, DEFAULT NULL):                  Indicator if the plant is active.
-- 		- p_organization_id (numeric, DEFAULT NULL):            The p_organization_id associated with the plant.
-- ============================================================================================================
DECLARE 
    p_last_user 	varchar;
	v_plant_id 		int8;
    v_start_procedure timestamp;
    -- Params to log errors
    step 			numeric;
	procedure_name	varchar(50) := 'application_data.manage_lk_plant';
	err_msg			varchar(2000);
    v_kpi_category_id int8;
    v_kpi_group_id int8;
	v_latitude numeric;
	v_longitude numeric;
	v_module_id int8;

BEGIN
    step := 0;
	out_flag := '';
	v_start_procedure := timezone('UTC',current_timestamp);
    --Log operation
    Insert into application_data.log_operation (
        operation_timestamp,
	    operation_src,
	    operation_msg,
	    operation_caller
    ) values (
        timezone('UTC',current_timestamp),
        procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type::text, 'NULL') || ', ' ||
            'p_plant_id: '  || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
            'p_plant_code: '  || COALESCE(p_plant_code::text, 'NULL') || ', ' ||
            'p_plant_ds: '  || COALESCE(p_plant_ds::text, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname::text, 'NULL') || ', ' ||
            'p_plant_timezone: '  || COALESCE(p_plant_timezone::text, 'NULL') || ', ' ||
            'p_latitude: '  || COALESCE(p_latitude::text, 'NULL') || ', ' ||
            'p_longitude: '  || COALESCE(p_longitude::text, 'NULL') || ', ' ||
            'p_organization_id: '  || COALESCE(p_organization_id::text, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ']',
        p_user_id::text || ' -- ' || p_user_fullname::text
    );


    -- Check if last_user is NULL
    step := 0.1;
    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        err_msg := 'ERROR LAST USER FULLNAME AND ID CANNOT BE NULL.';
        RAISE EXCEPTION '%', err_msg;
    END IF;
    p_last_user := p_user_id::text || ' -- ' || p_user_fullname;


    -- Main CASE block to handle different operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert operation
            step := 1;
            -- Check if any required values are NULL
            IF p_plant_code IS NULL OR p_plant_ds IS NULL THEN
                RAISE EXCEPTION 'ERROR VALUES CANNOT BE NULL TO INSERT A NEW PLANT';
            END IF;

            -- Insert new record into lk_plant table
            step := 1.1;
		
            INSERT INTO application_data.lk_plant (
                plant_code,
				plant_ds,
				creator_user,
				last_user,
				plant_timezone,
				latitude,
				longitude,
				is_active
            ) VALUES (
                p_plant_code, 
                p_plant_ds, 
                p_last_user, 
                p_last_user, 
                p_plant_timezone, 
                p_latitude, 
                p_longitude,
				p_is_active
            )   RETURNING plant_id INTO p_plant_id;
		
		-- Initialization insert department into lk_department table
		 step := 1.2;
		SELECT plant_id into v_plant_id 
		FROM application_data.lk_plant
		WHERE plant_code= p_plant_code;

	
		-- Initialization insert tier into lk_tier table
		 step := 1.3;
		INSERT INTO application_data.lk_tier (tier_code, tier_ds, plant_id, creation_ts, creator_user, is_active, is_deleted, is_editable, last_modified, last_user, tier_sort, frequency_id,tier_meeting_color) VALUES('TIER-1', '1° TIER', v_plant_id,  v_start_procedure, '1111111111111 -- Administrator', true, false, true, v_start_procedure, '1111111111111 -- Administrator', 1, 100,'#05668D');
		INSERT INTO application_data.lk_tier (tier_code, tier_ds, plant_id, creation_ts, creator_user, is_active, is_deleted, is_editable, last_modified, last_user, tier_sort, frequency_id,tier_meeting_color) VALUES('TIER-2', '2° TIER', v_plant_id,  v_start_procedure, '1111111111111 -- Administrator', true, false, true,  v_start_procedure, '1111111111111 -- Administrator', 2, 100,'#427AA1');
		INSERT INTO application_data.lk_tier (tier_code, tier_ds, plant_id, creation_ts, creator_user, is_active, is_deleted, is_editable, last_modified, last_user, tier_sort, frequency_id,tier_meeting_color) VALUES('TIER-3', '3° TIER', v_plant_id,  v_start_procedure, '1111111111111 -- Administrator', true, false, true, v_start_procedure, '1111111111111 -- Administrator', 3, 100,'#679436');
		INSERT INTO application_data.lk_tier (tier_code, tier_ds, plant_id, creation_ts, creator_user, is_active, is_deleted, is_editable, last_modified, last_user, tier_sort, frequency_id,tier_meeting_color) VALUES('TIER-4', '4° TIER', v_plant_id,  v_start_procedure, '1111111111111 -- Administrator', true, false, true, v_start_procedure, '1111111111111 -- Administrator', 4, 100,'#A5BE00');		
	
	
		-- Initialization insert module into lk_module table
		step := 1.31;
		INSERT INTO application_data.lk_module (
			module_code,
			module_ds,
			plant_id,
			creation_ts,
			creator_user,
			is_active,
			is_deleted,
			is_editable,
			last_modified,
			last_user
		) VALUES (
			'(U)',
			'<#Undefined/>',
			v_plant_id,
			v_start_procedure,
			'1111111111111 -- Administrator',
	        false,
			false,
			false,
			v_start_procedure,
			'1111111111111 -- Administrator'
		) RETURNING module_id INTO v_module_id;

		-- Initialization insert line into lk_line table
		step := 1.32;
		INSERT INTO application_data.lk_line (
			line_code,
			line_code_erp,
			line_ds,
			plant_id,
			module_id,
			creation_ts,
			creator_user,
			is_active,
			is_deleted,
			is_editable,
			last_modified,
			last_user
		) VALUES (
			'(U)',
			'(U)',
			'<#Undefined/>',
			v_plant_id,
			v_module_id,
			v_start_procedure,
			'1111111111111 -- Administrator',
			false,
			false,
			false,
			v_start_procedure,
			'1111111111111 -- Administrator'
		);


		-- Initialization insert Kpi_category into lk_kpi_category

		INSERT INTO application_data.lk_kpi_category
		(kpi_category_code, kpi_category_ds, kpi_category_sort, plant_id, is_active, is_deleted,  creator_user,  last_user, kpi_category_icon)
		VALUES('SAFETY', 'SAFETY', 1, v_plant_id, true, false, '1111111111111 -- Administrator',  '1111111111111 -- Administrator', '../content/resources/T0T/YLTCFBO/287011703985214/Safety.png');
		INSERT INTO application_data.lk_kpi_category
		(kpi_category_code, kpi_category_ds, kpi_category_sort, plant_id, is_active, is_deleted,  creator_user,  last_user, kpi_category_icon)
		VALUES('QUALITY', 'QUALITY', 2, v_plant_id, true, false,  '1111111111111 -- Administrator',  '1111111111111 -- Administrator', '../content/resources/T0T/YLTCFBO/960281627984412/quality.png');
		INSERT INTO application_data.lk_kpi_category
		(kpi_category_code, kpi_category_ds, kpi_category_sort, plant_id, is_active, is_deleted,  creator_user,  last_user, kpi_category_icon)
		VALUES('DELIVERY', 'DELIVERY', 3, v_plant_id, true, false, '1111111111111 -- Administrator', '1111111111111 -- Administrator', '../content/resources/T0T/YLTCFBO/311118262599102/Delivery.png');
		INSERT INTO application_data.lk_kpi_category
		(kpi_category_code, kpi_category_ds, kpi_category_sort, plant_id, is_active, is_deleted,  creator_user,  last_user, kpi_category_icon)
		VALUES('INVENTORY', 'INVENTORY', 4, v_plant_id, true, false, '1111111111111 -- Administrator',  '1111111111111 -- Administrator', '../content/resources/T0T/YLTCFBO/365861491388327/Inventory.png');
		INSERT INTO application_data.lk_kpi_category
		(kpi_category_code, kpi_category_ds, kpi_category_sort, plant_id, is_active, is_deleted,  creator_user,  last_user, kpi_category_icon)
		VALUES('PRODUCTIVITY', 'PRODUCTIVITY', 5, v_plant_id, true, false,  '1111111111111 -- Administrator',  '1111111111111 -- Administrator', '../content/resources/T0T/YLTCFBO/802407349059910/Productivity.png');

 		step := 1.4;
		SELECT kpi_category_id INTO v_kpi_category_id FROM application_data.lk_kpi_category WHERE kpi_category_code = 'SAFETY' AND plant_id=v_plant_id ;

		INSERT INTO application_data.lk_kpi_group
		(kpi_group_code, kpi_group_ds, kpi_group_sort, plant_id, kpi_category_id, is_active, is_deleted, creator_user, last_user)
		VALUES('<#DefaultSafetyGroup/>', 'Default Safety Group', 1, v_plant_id, v_kpi_category_id, true, false, '1111111111111 -- Administrator', '1111111111111 -- Administrator');

		step := 1.5;
		SELECT kpi_group_id INTO v_kpi_group_id FROM application_data.lk_kpi_group WHERE kpi_group_code = '<#DefaultSafetyGroup/>' AND plant_id=v_plant_id ;

		INSERT INTO application_data.lk_kpi (
		    kpi_code,
		    kpi_ds,
		    plant_id,
		    kpi_group_id,
		    kpi_category_id,
		    aggregation_rule_id,
		    kpi_uom_id,
		    kpi_sort,
		    color_up_target_cd,
		    color_down_target_cd,
		    def_value,
		    def_target,
		    is_zero_display,
		    is_automatic_value,
		    is_active,
		    is_deleted,
		    creator_user,
		    last_user,
		    target_tendency_id,
		    kpi_type_id,
		    is_main_kpi
		)
		VALUES (
		    'safety events',
		    'safety events',
		    v_plant_id,
		    v_kpi_group_id,
		    v_kpi_category_id,
		    (SELECT aggregation_rule_id FROM application_data.lk_aggregation_rule WHERE aggregation_rule_code = '<#SUM/>'),
		    (SELECT kpi_uom_id FROM application_data.lk_kpi_uom WHERE kpi_uom_code = '<#CountUom/>'),
		    1,
		    NULL,
		    NULL,
		    NULL,
		    NULL,
		    1,
		    1,
		    TRUE,
		    FALSE,
		    '1111111111111 -- Administrator',
		    '1111111111111 -- Administrator',
		    (SELECT target_tendency_id FROM application_data.lk_target_tendency WHERE target_tendency_code = 0),
		    (SELECT kpi_type_id FROM application_data.lk_kpi_type WHERE kpi_type_code = 'DONUT'),
		    TRUE
		);

-- Nuovo step per la creazione partizioni
        step := 1.6;
        BEGIN
            -- Utilizziamo v_plant_id (o p_plant_id) recuperato precedentemente
            PERFORM application_data.setup_new_plant_partitions(v_plant_id, 1111111111111, 'Administrator');
        EXCEPTION WHEN OTHERS THEN
            -- Opzione A: Logga l'errore e continua (se vuoi che il plant resti comunque creato)
            -- RAISE NOTICE 'Errore durante la creazione partizioni per il plant %: %', v_plant_id, SQLERRM;
            
            -- Opzione B: Rilancia l'errore per fare rollback di tutto (scelta consigliata per coerenza dati)
            err_msg := 'CRITICAL ERROR during setup_new_plant_partitions: ' || SQLERRM;
            RAISE EXCEPTION '%', err_msg;
        END;

WHEN 'SET_ORGANIZATION' THEN
            -- Update operation
            -- Check if the record is editable
           step := 1.7;
            PERFORM 1
            FROM application_data.lk_plant
            WHERE plant_code = p_plant_code
               AND is_editable = false;

            IF FOUND THEN
                RAISE EXCEPTION 'ERROR IS_EDITABLE CANNOT BE FALSE';
            END IF;
          
            -- Update the record in the lk_plant table
             step := 1.8;
            UPDATE application_data.lk_plant
            SET
				organization_id =  COALESCE(p_organization_id, organization_id)-- Update organization_id if p_organization_id is not null
            WHERE plant_code = p_plant_code;		

        WHEN 'U' THEN
            -- Update operation
            step := 2;
            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_plant
            WHERE plant_id = p_plant_id
                AND is_editable = false;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR IS_EDITABLE CANNOT BE FALSE';
            END IF;
            
			--check if p_longitude and p_latitude are -1 then replace with null
			IF (p_latitude = -1) THEN v_latitude:=NULL; ELSE v_latitude := p_latitude; END IF;
            IF (p_longitude = -1) THEN v_longitude:=NULL; ELSE v_longitude := p_longitude; END IF;

            -- Update the record in the lk_plant table
            UPDATE application_data.lk_plant
            SET
                plant_code = COALESCE(p_plant_code, plant_code),				-- Update plant_code if provided
				plant_ds = COALESCE(p_plant_ds, plant_ds),						-- Update plant_ds if provided
				last_user = p_last_user,										-- Update last_user
				last_modified = timezone('UTC',current_timestamp),				-- Set last_modified to current timestamp
				is_active = COALESCE(p_is_active, is_active),					-- Update is_active if provided
				plant_timezone = COALESCE(p_plant_timezone, plant_timezone),	-- Update plant_timezone if provided
				latitude = v_latitude,											-- Update latitude if provided
				longitude = v_longitude											-- Update longitude if provided
            WHERE plant_id = p_plant_id;

		WHEN 'LD' THEN
            -- Logical Deletion Operation
            UPDATE application_data.lk_plant
            SET is_deleted=true,
				is_active=false,
				is_editable=false
			WHERE plant_id = p_plant_id;

        WHEN 'D' THEN
           step := 3;
            -- Physical deletion operation
            -- Delete the record from the lk_plant table
			DELETE FROM application_data.lk_tier WHERE plant_id = p_plant_id;
            DELETE FROM application_data.lk_plant WHERE plant_id = p_plant_id;
        ELSE
            -- Invalid operation type
            RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';
    END CASE;
EXCEPTION
    WHEN OTHERS THEN
        -- Catch all exceptions and log them
        err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
            'Step: ' || step::text || ', ' ||
            'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
            'p_plant_code: ' || COALESCE(p_plant_code, 'NULL') || ', ' ||
            'p_plant_ds: ' || COALESCE(p_plant_ds, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname, 'NULL') || ', ' ||           
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_plant_timezone: ' || COALESCE(p_plant_timezone, 'NULL') || ', ' ||
            'p_latitude: ' || COALESCE(p_latitude::text, 'NULL') || ', ' ||
            'p_longitude: ' || COALESCE(p_longitude::text, 'NULL') || ', ' ||
   			 'p_organization_id: '  || COALESCE(p_organization_id::text, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ']';
	out_flag := err_msg;
        begin
            INSERT INTO application_data.log_error (
                error_timestamp,
                error_src, 
                error_msg,
                error_caller
            ) VALUES (
                timezone('UTC',current_timestamp),
                procedure_name,
                err_msg,
                p_user_id::text || ' -- ' || p_user_fullname
            );
            commit;
        end;
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_threshold(varchar, int8, int8, int8, int8, numeric, text, text, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_threshold(
    IN p_operation_type character varying,
    IN p_threshold_id bigint DEFAULT NULL::bigint,
    IN p_plant_id bigint DEFAULT NULL::bigint,
    IN p_line_id bigint DEFAULT NULL::bigint,
    IN p_kpi_id bigint DEFAULT NULL::bigint,
    IN p_threshold_value numeric DEFAULT NULL::numeric,
    IN p_start_date_local text DEFAULT NULL,
    IN p_end_date_local text DEFAULT NULL,
    IN p_is_active boolean DEFAULT true,
    IN p_user_id bigint DEFAULT NULL::bigint,
    IN p_user_fullname character varying DEFAULT NULL::character varying
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user TEXT;
    lp_step NUMERIC := 0;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_threshold';
    lp_err_msg VARCHAR(2000);

    lp_plant_timezone VARCHAR;
    lp_current_timestamp TIMESTAMP WITHOUT TIME ZONE := CURRENT_TIMESTAMP;

    lp_start_date_local TIMESTAMP WITHOUT TIME ZONE;
    lp_start_date_utc   TIMESTAMP WITHOUT TIME ZONE;
    lp_start_date_id    NUMERIC(8);

    lp_end_date_local   TIMESTAMP WITHOUT TIME ZONE;
    lp_end_date_utc     TIMESTAMP WITHOUT TIME ZONE;
    lp_end_date_id      NUMERIC(8);

    lp_current_start_date TIMESTAMP WITHOUT TIME ZONE;
    lp_min_start_date     TIMESTAMP WITHOUT TIME ZONE;
    lp_updated_start_date TIMESTAMP WITHOUT TIME ZONE;
    lp_next_start_date    TIMESTAMP WITHOUT TIME ZONE;
    lp_current_end_date_local TIMESTAMP WITHOUT TIME ZONE;
    effective_new_start   TIMESTAMP WITHOUT TIME ZONE;
    effective_new_end     TIMESTAMP WITHOUT TIME ZONE;
    lp_updated_kpi_id    bigint;

    lp_start_date_local_user TIMESTAMP WITHOUT TIME ZONE;
    lp_end_date_local_user   TIMESTAMP WITHOUT TIME ZONE;
BEGIN
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [p_operation_type: ' || COALESCE(p_operation_type::text, 'NULL') || ', ' ||
            'p_threshold_id: ' || COALESCE(p_threshold_id::text, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
            'p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_kpi_id: ' || COALESCE(p_kpi_id::text, 'NULL') || ', ' ||
            'p_threshold_value: ' || COALESCE(p_threshold_value::text, 'NULL') || ', ' ||
            'p_start_date_local: ' || COALESCE(p_start_date_local, 'NULL') || ', ' ||
            'p_end_date_local: ' || COALESCE(p_end_date_local, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname::text, 'NULL') || ']',
        COALESCE(p_user_id::TEXT, 'Unknown') || ' -- ' || COALESCE(p_user_fullname::TEXT, 'Unknown')
    );

    lp_step := 1;
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    lp_step := 2;
    IF p_plant_id IS NULL THEN
        lp_err_msg := 'ERROR: Plant ID cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_step := 2.1;
    IF p_line_id IS NULL THEN
        lp_err_msg := 'ERROR: Line ID cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_step := 2.2;
    IF p_kpi_id IS NULL THEN
        lp_err_msg := 'ERROR: KPI ID cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_step := 3;
    SELECT plant_timezone
    INTO lp_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;

    IF lp_plant_timezone IS NULL OR btrim(lp_plant_timezone) = '' THEN
        lp_err_msg := 'ERROR: Plant timezone not found for plant_id ' || p_plant_id::text || '.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_start_date_local_user := NULL;
    lp_end_date_local_user := NULL;
    IF NULLIF(btrim(COALESCE(p_start_date_local, '')), '') IS NOT NULL THEN
        BEGIN
            lp_start_date_local_user := (NULLIF(btrim(p_start_date_local), ''))::timestamp without time zone;
        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'Invalid p_start_date_local: ' || COALESCE(p_start_date_local, '');
            RAISE EXCEPTION '%', lp_err_msg;
        END;
    END IF;
    IF NULLIF(btrim(COALESCE(p_end_date_local, '')), '') IS NOT NULL THEN
        BEGIN
            lp_end_date_local_user := (NULLIF(btrim(p_end_date_local), ''))::timestamp without time zone;
        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'Invalid p_end_date_local: ' || COALESCE(p_end_date_local, '');
            RAISE EXCEPTION '%', lp_err_msg;
        END;
        IF lp_end_date_local_user = date_trunc('day', lp_end_date_local_user) THEN
            lp_end_date_local_user := date_trunc('day', lp_end_date_local_user) + INTERVAL '1 day' - INTERVAL '1 second';
        END IF;
    END IF;

    CASE p_operation_type
        WHEN 'I' THEN
            lp_step := 10;
            IF p_threshold_value IS NULL THEN
                lp_err_msg := 'ERROR: threshold_value cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 11;
            IF lp_start_date_local_user IS NOT NULL THEN
                lp_start_date_local := lp_start_date_local_user;
                lp_start_date_utc := timezone('UTC', (lp_start_date_local_user AT TIME ZONE lp_plant_timezone));
            ELSE
                SELECT
                    DATE_TRUNC('day', (lp_current_timestamp AT TIME ZONE lp_plant_timezone) + INTERVAL '1 day'),
                    DATE_TRUNC('day', (lp_current_timestamp AT TIME ZONE lp_plant_timezone) + INTERVAL '1 day')::TIMESTAMP AT TIME ZONE lp_plant_timezone AT TIME ZONE 'UTC'
                INTO lp_start_date_local, lp_start_date_utc;
            END IF;

            lp_step := 12;
            lp_start_date_id := TO_CHAR(lp_start_date_local, 'YYYYMMDD')::NUMERIC(8);

            lp_step := 13;
            IF lp_end_date_local_user IS NOT NULL THEN
                IF lp_end_date_local_user <= lp_start_date_local THEN
                    lp_err_msg := 'ERROR: end_date_local must be greater than start_date_local.';
                    RAISE EXCEPTION '%', lp_err_msg;
                END IF;
                lp_end_date_local := lp_end_date_local_user;
                lp_end_date_utc := timezone('UTC', (lp_end_date_local_user AT TIME ZONE lp_plant_timezone));
                lp_end_date_id := TO_CHAR(lp_end_date_local, 'YYYYMMDD')::NUMERIC(8);
            ELSE
                lp_end_date_local := NULL;
                lp_end_date_utc := NULL;
                lp_end_date_id := NULL;
            END IF;

            -- Data antecedente non ammessa: data di inizio >= data minima già presente sulla linea
            lp_step := 13.5;
            SELECT MIN(t.start_date_local)
            INTO lp_min_start_date
            FROM application_data.lk_threshold t
            WHERE t.plant_id = p_plant_id
              AND t.line_id = p_line_id
              AND t.kpi_id = p_kpi_id
              AND t.is_deleted = false
              AND t.is_active = true;

            IF lp_min_start_date IS NOT NULL AND lp_start_date_local < lp_min_start_date THEN
                lp_err_msg := 'ERROR: Start date not allowed. There is already a record with start date ' ||
                    to_char(lp_min_start_date, 'YYYY-MM-DD') ||
                    '. It is not permitted to insert intervals with a start date earlier than the minimum existing start date for this line.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            -- Intervalli non sovrapponibili (né totalmente né parzialmente)
            lp_step := 13.6;
            IF EXISTS (
                SELECT 1
                FROM application_data.lk_threshold t
                WHERE t.plant_id = p_plant_id
                  AND t.line_id = p_line_id
                  AND t.kpi_id = p_kpi_id
                  AND t.is_deleted = false
                  AND t.is_active = true
                  AND t.end_date_local IS NOT NULL
                  AND (t.start_date_local < COALESCE(lp_end_date_local, 'infinity'::timestamp))
                  AND (t.end_date_local > lp_start_date_local)
            ) THEN
                lp_err_msg := 'ERROR: Invalid interval. Overlap (full or partial) with an existing record for the same line and KPI. Validity intervals must not overlap.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            -- Non inserire data di inizio <= a quella del record aperto (se esiste)
            lp_step := 14;
            SELECT max(t.start_date_local)
            INTO lp_current_start_date
            FROM application_data.lk_threshold t
            WHERE t.plant_id = p_plant_id
              AND t.line_id = p_line_id
              AND t.kpi_id = p_kpi_id
              AND t.is_deleted = false
              AND t.is_active = true
              AND t.end_date_local IS NULL
              AND t.end_date_utc IS NULL
              AND t.end_date_id IS NULL;

            IF lp_current_start_date IS NOT NULL AND lp_start_date_local <= lp_current_start_date THEN
                lp_err_msg := 'ERROR: Cannot insert a new threshold starting at ' ||
                    lp_start_date_local::text || '. There is already an open record starting at ' ||
                    lp_current_start_date::text || '.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 15;
            UPDATE application_data.lk_threshold
            SET
                end_date_local = (lp_start_date_local - INTERVAL '1 second'),
                end_date_utc   = (lp_start_date_utc - INTERVAL '1 second'),
                end_date_id    = TO_CHAR(lp_start_date_local - INTERVAL '1 second', 'YYYYMMDD')::NUMERIC(8),
                last_modified  = timezone('UTC', current_timestamp),
                last_user      = lp_last_user
            WHERE plant_id = p_plant_id
              AND line_id = p_line_id
              AND kpi_id = p_kpi_id
              AND is_deleted = false
              AND is_active = true
              AND end_date_local IS NULL
              AND end_date_utc IS NULL
              AND end_date_id IS NULL;

            lp_step := 16;
            INSERT INTO application_data.lk_threshold (
                plant_id,
                line_id,
                kpi_id,
                threshold_value,
                start_date_local,
                start_date_utc,
                end_date_local,
                end_date_utc,
                start_date_id,
                end_date_id,
                is_active,
                is_deleted,
                creation_ts,
                creator_user,
                last_modified,
                last_user
            ) VALUES (
                p_plant_id,
                p_line_id,
                p_kpi_id,
                p_threshold_value,
                lp_start_date_local,
                lp_start_date_utc,
                lp_end_date_local,
                lp_end_date_utc,
                lp_start_date_id,
                lp_end_date_id,
                COALESCE(p_is_active, true),
                false,
                timezone('UTC', current_timestamp),
                lp_last_user,
                timezone('UTC', current_timestamp),
                lp_last_user
            );

        WHEN 'U' THEN
            lp_step := 20;
            IF p_threshold_id IS NULL THEN
                lp_err_msg := 'ERROR: threshold_id cannot be NULL for update.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 21;
            SELECT start_date_local, end_date_local, kpi_id
            INTO lp_updated_start_date, lp_current_end_date_local, lp_updated_kpi_id
            FROM application_data.lk_threshold
            WHERE plant_id = p_plant_id AND line_id = p_line_id AND threshold_id = p_threshold_id;

            effective_new_start := COALESCE(lp_start_date_local_user, lp_updated_start_date);
            effective_new_end   := COALESCE(lp_end_date_local_user, lp_current_end_date_local);

            IF effective_new_end IS NOT NULL AND effective_new_end <= effective_new_start THEN
                lp_err_msg := 'ERROR: end_date_local must be greater than start_date_local.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 22;
            IF EXISTS (
                SELECT 1
                FROM application_data.lk_threshold t
                WHERE t.plant_id = p_plant_id
                  AND t.line_id = p_line_id
                  AND t.kpi_id = lp_updated_kpi_id
                  AND t.threshold_id <> p_threshold_id
                  AND t.is_deleted = false
                  AND t.is_active = true
                  AND (t.start_date_local < COALESCE(effective_new_end, 'infinity'::timestamp))
                  AND (COALESCE(t.end_date_local, 'infinity'::timestamp) > effective_new_start)
            ) THEN
                lp_err_msg := 'ERROR: Invalid interval. The new validity interval would overlap (fully or partially) with another existing record for this line and KPI.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            SELECT MIN(t.start_date_local) INTO lp_next_start_date
            FROM application_data.lk_threshold t
            WHERE t.plant_id = p_plant_id
              AND t.line_id = p_line_id
              AND t.kpi_id = lp_updated_kpi_id
              AND t.threshold_id <> p_threshold_id
              AND t.is_deleted = false
              AND t.is_active = true
              AND t.start_date_local > effective_new_start;

            IF lp_next_start_date IS NOT NULL AND (effective_new_end IS NULL OR effective_new_end >= lp_next_start_date) THEN
                lp_err_msg := 'ERROR: End date must be strictly before the start of the next record (starting at ' ||
                    lp_next_start_date::text || '). It cannot equal or exceed that time.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 23;
            IF lp_start_date_local_user IS NOT NULL THEN
                lp_start_date_local := lp_start_date_local_user;
                lp_start_date_utc := timezone('UTC', (lp_start_date_local_user AT TIME ZONE lp_plant_timezone));
                lp_start_date_id := TO_CHAR(lp_start_date_local, 'YYYYMMDD')::NUMERIC(8);
            END IF;

            IF lp_end_date_local_user IS NOT NULL THEN
                lp_end_date_local := lp_end_date_local_user;
                lp_end_date_utc := timezone('UTC', (lp_end_date_local_user AT TIME ZONE lp_plant_timezone));
                lp_end_date_id := TO_CHAR(lp_end_date_local, 'YYYYMMDD')::NUMERIC(8);
            ELSE
                lp_end_date_local := NULL;
                lp_end_date_utc := NULL;
                lp_end_date_id := NULL;
            END IF;

            UPDATE application_data.lk_threshold
            SET
                threshold_value   = COALESCE(p_threshold_value, threshold_value),
                start_date_local = CASE WHEN lp_start_date_local_user IS NOT NULL THEN lp_start_date_local ELSE start_date_local END,
                start_date_utc   = CASE WHEN lp_start_date_local_user IS NOT NULL THEN lp_start_date_utc   ELSE start_date_utc END,
                start_date_id    = CASE WHEN lp_start_date_local_user IS NOT NULL THEN lp_start_date_id    ELSE start_date_id END,
                end_date_local   = COALESCE(lp_end_date_local_user, end_date_local),
                end_date_utc    = CASE WHEN lp_end_date_local_user IS NOT NULL THEN lp_end_date_utc ELSE end_date_utc END,
                end_date_id     = CASE WHEN lp_end_date_local_user IS NOT NULL THEN lp_end_date_id  ELSE end_date_id END,
                is_active       = COALESCE(p_is_active, is_active),
                last_modified   = timezone('UTC', current_timestamp),
                last_user       = lp_last_user
            WHERE plant_id = p_plant_id
              AND line_id = p_line_id
              AND threshold_id = p_threshold_id;

        WHEN 'LD' THEN
            lp_step := 30;
            IF p_threshold_id IS NULL THEN
                lp_err_msg := 'ERROR: threshold_id cannot be NULL for logical delete.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            UPDATE application_data.lk_threshold
            SET
                is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = lp_last_user
            WHERE plant_id = p_plant_id
              AND line_id = p_line_id
              AND threshold_id = p_threshold_id;

        WHEN 'D' THEN
            lp_step := 40;
            IF p_threshold_id IS NULL THEN
                lp_err_msg := 'ERROR: threshold_id cannot be NULL for physical delete.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            DELETE FROM application_data.lk_threshold
            WHERE plant_id = p_plant_id
              AND line_id = p_line_id
              AND threshold_id = p_threshold_id;

        ELSE
            lp_step := 90;
            lp_err_msg := 'ERROR: Invalid operation_type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Physical Delete).';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        BEGIN
            CALL application_data.log_error_write(
                lp_procedure_name,
                lp_err_msg,
                COALESCE(p_user_id::TEXT, 'Unknown') || ' -- ' || COALESCE(p_user_fullname::TEXT, 'Unknown')
            );
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    lp_err_msg,
                    COALESCE(p_user_id::TEXT, 'Unknown') || ' -- ' || COALESCE(p_user_fullname::TEXT, 'Unknown')
                );
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
        RAISE;
END;
$procedure$
;

-- ========== application_data.manage_lk_target, fn_audit_lk_target, sync_ft_kpi_target_from_lk_target (see deploy_lk_target.sql) ==========
-- DROP PROCEDURE IF EXISTS application_data.manage_lk_target(varchar, int8, int8, int8, int8, numeric, text, text, int8, varchar, bool, bool);
CREATE OR REPLACE PROCEDURE application_data.manage_lk_target(
    IN p_operation_type   character varying,
    IN p_target_id        bigint DEFAULT NULL::bigint,
    IN p_plant_id         bigint DEFAULT NULL::bigint,
    IN p_line_id          bigint DEFAULT NULL::bigint,
    IN p_kpi_id           bigint DEFAULT NULL::bigint,
    IN p_target_value_num numeric DEFAULT NULL::numeric,
    IN p_start_date_local text DEFAULT NULL,
    IN p_end_date_local   text DEFAULT NULL,
    IN p_user_id          bigint DEFAULT NULL::bigint,
    IN p_user_fullname    character varying DEFAULT NULL::character varying,
    IN p_is_active        bool DEFAULT NULL,
    IN p_is_deleted       bool DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description:
--   Load and manage rows in application_data.lk_target (KPI target per plant, line, kpi with
--   validity interval). Operations: I=Insert, U=Update, D=Delete.
--
-- @Notes:
--   - Date params: p_start_date_local, p_end_date_local (text); timezone from application_data.lk_plant.
--   - Validity intervals must not overlap (fully or partially) per (plant_id, line_id, kpi_id).
--   - Overlap checked with daterange and && operator.
--   - p_target_id required for U and D; p_start_date_local required for I.
--   - After each I/U/D operation on lk_target, sync_ft_kpi_target_from_lk_target is executed.
-- ============================================================================================================
DECLARE
    lp_last_user       TEXT;
    lp_step            NUMERIC := 0;
    lp_procedure_name  VARCHAR(50) := 'application_data.manage_lk_target';
    lp_err_msg         VARCHAR(2000);
    lp_plant_timezone   VARCHAR(100);
    lp_start_date_local_ts timestamp without time zone;
    lp_start_date_utc_ts   timestamp without time zone;
    lp_start_date_id_val   numeric(8);
    lp_end_date_local_ts   timestamp without time zone;
    lp_end_date_utc_ts     timestamp without time zone;
    lp_end_date_id_val     numeric(8);
    lp_sync_start_date_id  numeric(8);
    lp_sync_end_date_id    numeric(8);
    lp_delete_plant_id     bigint;
    lp_delete_line_id      bigint;
    lp_delete_kpi_id       bigint;
    lp_current_timestamp   timestamp without time zone := current_timestamp;
BEGIN
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [p_operation_type: ' || COALESCE(p_operation_type::text, 'NULL') ||
        ', p_target_id: ' || COALESCE(p_target_id::text, 'NULL') ||
        ', p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') ||
        ', p_line_id: ' || COALESCE(p_line_id::text, 'NULL') ||
        ', p_kpi_id: ' || COALESCE(p_kpi_id::text, 'NULL') ||
        ', p_target_value_num: ' || COALESCE(p_target_value_num::text, 'NULL') ||
        ', p_start_date_local: ' || COALESCE(p_start_date_local, 'NULL') ||
        ', p_end_date_local: ' || COALESCE(p_end_date_local, 'NULL') ||
        ', p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || ', p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') ||
        ', p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', p_is_deleted: ' || COALESCE(p_is_deleted::text, 'NULL') || ']',
        COALESCE(p_user_id::TEXT, 'Unknown') || ' -- ' || COALESCE(p_user_fullname::TEXT, 'Unknown')
    );

    lp_step := 1;
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    lp_step := 2;
    IF p_plant_id IS NULL THEN
        lp_err_msg := 'ERROR: Plant ID cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    IF p_line_id IS NULL THEN
        lp_err_msg := 'ERROR: Line ID cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    IF p_kpi_id IS NULL THEN
        lp_err_msg := 'ERROR: KPI ID cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    SELECT plant_timezone INTO lp_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;

    IF lp_plant_timezone IS NULL OR btrim(lp_plant_timezone) = '' THEN
        lp_err_msg := 'ERROR: Plant timezone not found for plant_id ' || p_plant_id::text || '.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_start_date_local_ts := NULL;
    lp_end_date_local_ts   := NULL;
    IF NULLIF(btrim(COALESCE(p_start_date_local, '')), '') IS NOT NULL THEN
        BEGIN
            lp_start_date_local_ts := (NULLIF(btrim(p_start_date_local), ''))::timestamp without time zone;
        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'Invalid p_start_date_local: ' || COALESCE(p_start_date_local, '');
            RAISE EXCEPTION '%', lp_err_msg;
        END;
    END IF;
    IF NULLIF(btrim(COALESCE(p_end_date_local, '')), '') IS NOT NULL THEN
        BEGIN
            lp_end_date_local_ts := (NULLIF(btrim(p_end_date_local), ''))::timestamp without time zone;
        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'Invalid p_end_date_local: ' || COALESCE(p_end_date_local, '');
            RAISE EXCEPTION '%', lp_err_msg;
        END;
        IF lp_end_date_local_ts = date_trunc('day', lp_end_date_local_ts) THEN
            lp_end_date_local_ts := date_trunc('day', lp_end_date_local_ts) + INTERVAL '1 day' - INTERVAL '1 second';
        END IF;
    END IF;

    CASE p_operation_type
        WHEN 'I' THEN
            lp_step := 10;
            IF p_target_value_num IS NULL THEN
                lp_err_msg := 'ERROR: target_value_num cannot be NULL for insert.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;
            IF lp_start_date_local_ts IS NULL THEN
                lp_err_msg := 'ERROR: p_start_date_local cannot be NULL for insert.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_start_date_utc_ts := (lp_start_date_local_ts AT TIME ZONE lp_plant_timezone) AT TIME ZONE 'UTC';
            lp_start_date_id_val := TO_CHAR(lp_start_date_local_ts, 'YYYYMMDD')::numeric(8);

            IF lp_end_date_local_ts IS NOT NULL THEN
                IF lp_end_date_local_ts <= lp_start_date_local_ts THEN
                    lp_err_msg := 'ERROR: end_date_local must be greater than start_date_local.';
                    RAISE EXCEPTION '%', lp_err_msg;
                END IF;
                lp_end_date_utc_ts := (lp_end_date_local_ts AT TIME ZONE lp_plant_timezone) AT TIME ZONE 'UTC';
                lp_end_date_id_val := TO_CHAR(lp_end_date_local_ts, 'YYYYMMDD')::numeric(8);
            ELSE
                lp_end_date_local_ts := NULL;
                lp_end_date_utc_ts   := NULL;
                lp_end_date_id_val  := NULL;
            END IF;

            lp_step := 11;
            IF EXISTS (
                SELECT 1
                FROM application_data.lk_target t
                WHERE t.plant_id = p_plant_id
                  AND t.line_id = p_line_id
                  AND t.kpi_id = p_kpi_id
                  AND t.is_deleted = false
                  AND daterange(
                        to_date(t.start_date_id::text, 'YYYYMMDD'),
                        COALESCE(to_date(t.end_date_id::text, 'YYYYMMDD'), 'infinity'::date),
                        '[]'
                      ) && daterange(
                        to_date(lp_start_date_id_val::text, 'YYYYMMDD'),
                        COALESCE(to_date(lp_end_date_id_val::text, 'YYYYMMDD'), 'infinity'::date),
                        '[]'
                      )
            ) THEN
                lp_err_msg := 'ERROR: Invalid interval. Overlap (full or partial) with an existing record for the same plant, line and KPI. Validity intervals must not overlap.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_target (
                plant_id, line_id, kpi_id, target_value_num,
                start_date_local, start_date_utc, end_date_local, end_date_utc,
                start_date_id, end_date_id,
                is_active, is_deleted,
                creation_ts, creator_user, last_modified, last_user
            ) VALUES (
                p_plant_id, p_line_id, p_kpi_id, p_target_value_num,
                lp_start_date_local_ts, lp_start_date_utc_ts, lp_end_date_local_ts, lp_end_date_utc_ts,
                lp_start_date_id_val, lp_end_date_id_val,
                true, false,
                timezone('UTC', current_timestamp), lp_last_user,
                timezone('UTC', current_timestamp), lp_last_user
            )
            RETURNING start_date_id, end_date_id
            INTO lp_sync_start_date_id, lp_sync_end_date_id;

            lp_step := 12;
            CALL application_data.sync_ft_kpi_target_from_lk_target(
                p_user_id, p_user_fullname, lp_sync_start_date_id, lp_sync_end_date_id,
                p_plant_id, p_line_id, p_kpi_id
            );

        WHEN 'U' THEN
            lp_step := 20;
            IF p_target_id IS NULL THEN
                lp_err_msg := 'ERROR: target_id cannot be NULL for update.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            IF lp_end_date_local_ts IS NOT NULL AND lp_start_date_local_ts IS NOT NULL AND lp_end_date_local_ts <= lp_start_date_local_ts THEN
                lp_err_msg := 'ERROR: end_date_local must be greater than start_date_local.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            IF lp_start_date_local_ts IS NOT NULL THEN
                lp_start_date_utc_ts := (lp_start_date_local_ts AT TIME ZONE lp_plant_timezone) AT TIME ZONE 'UTC';
                lp_start_date_id_val := TO_CHAR(lp_start_date_local_ts, 'YYYYMMDD')::numeric(8);
            END IF;
            IF lp_end_date_local_ts IS NOT NULL THEN
                lp_end_date_utc_ts  := (lp_end_date_local_ts AT TIME ZONE lp_plant_timezone) AT TIME ZONE 'UTC';
                lp_end_date_id_val  := TO_CHAR(lp_end_date_local_ts, 'YYYYMMDD')::numeric(8);
            END IF;

            lp_step := 21;
            IF EXISTS (
                SELECT 1
                FROM application_data.lk_target t
                CROSS JOIN (
                    SELECT
                        COALESCE(lp_start_date_id_val, start_date_id) AS eff_start,
                        COALESCE(lp_end_date_id_val, end_date_id)     AS eff_end
                    FROM application_data.lk_target
                    WHERE target_id = p_target_id
                ) cur
                WHERE t.target_id <> p_target_id
                  AND t.plant_id = p_plant_id
                  AND t.line_id = p_line_id
                  AND t.kpi_id = p_kpi_id
                  AND t.is_deleted = false
                  AND daterange(
                        to_date(t.start_date_id::text, 'YYYYMMDD'),
                        COALESCE(to_date(t.end_date_id::text, 'YYYYMMDD'), 'infinity'::date),
                        '[]'
                      ) && daterange(
                        to_date(cur.eff_start::text, 'YYYYMMDD'),
                        COALESCE(to_date(cur.eff_end::text, 'YYYYMMDD'), 'infinity'::date),
                        '[]'
                      )
            ) THEN
                lp_err_msg := 'ERROR: The new validity interval would overlap (fully or partially) with another existing record for this plant, line and KPI.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            UPDATE application_data.lk_target
            SET
                target_value_num  = COALESCE(p_target_value_num, target_value_num),
                start_date_local  = COALESCE(lp_start_date_local_ts, start_date_local),
                start_date_utc    = COALESCE(lp_start_date_utc_ts, start_date_utc),
                end_date_local    = COALESCE(lp_end_date_local_ts, end_date_local),
                end_date_utc      = COALESCE(lp_end_date_utc_ts, end_date_utc),
                start_date_id     = COALESCE(lp_start_date_id_val, start_date_id),
                end_date_id       = COALESCE(lp_end_date_id_val, end_date_id),
                is_active         = COALESCE(p_is_active, is_active),
                is_deleted        = COALESCE(p_is_deleted, is_deleted),
                last_modified     = timezone('UTC', current_timestamp),
                last_user         = lp_last_user
            WHERE target_id = p_target_id
            RETURNING start_date_id, end_date_id
            INTO lp_sync_start_date_id, lp_sync_end_date_id;

            lp_step := 22;
            CALL application_data.sync_ft_kpi_target_from_lk_target(
                p_user_id, p_user_fullname, lp_sync_start_date_id, lp_sync_end_date_id,
                p_plant_id, p_line_id, p_kpi_id
            );

        WHEN 'D' THEN
            lp_step := 30;
            IF p_target_id IS NULL THEN
                lp_err_msg := 'ERROR: target_id cannot be NULL for delete.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 31;
            SELECT
                plant_id,
                line_id,
                kpi_id,
                start_date_id,
                end_date_id
            INTO
                lp_delete_plant_id,
                lp_delete_line_id,
                lp_delete_kpi_id,
                lp_sync_start_date_id,
                lp_sync_end_date_id
            FROM application_data.lk_target
            WHERE target_id = p_target_id;

            IF NOT FOUND THEN
                lp_err_msg := 'ERROR: target_id ' || p_target_id::text || ' not found.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 32;
            UPDATE application_data.ft_kpi_target
            SET
                target_value_num = NULL,
                last_modified    = timezone('UTC', current_timestamp),
                last_user        = lp_last_user
            WHERE plant_id = lp_delete_plant_id
              AND line_id  = lp_delete_line_id
              AND kpi_id   = lp_delete_kpi_id
              AND target_date_iso >= lp_sync_start_date_id
              AND (lp_sync_end_date_id IS NULL OR target_date_iso <= lp_sync_end_date_id);

            DELETE FROM application_data.lk_target WHERE target_id = p_target_id;

            lp_step := 33;
            CALL application_data.sync_ft_kpi_target_from_lk_target(
                p_user_id, p_user_fullname, lp_sync_start_date_id, lp_sync_end_date_id,
                lp_delete_plant_id, lp_delete_line_id, lp_delete_kpi_id
            );

        ELSE
            lp_err_msg := 'ERROR: Invalid operation_type. Use I, U or D.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION WHEN OTHERS THEN
    CALL application_data.log_error_write(lp_procedure_name, SQLERRM::varchar, current_user::varchar);
    RAISE;
END;
$procedure$;



DROP PROCEDURE IF EXISTS application_data.sync_ft_kpi_target_from_lk_target(int8, varchar);
DROP PROCEDURE IF EXISTS application_data.sync_ft_kpi_target_from_lk_target(int8, varchar, numeric, numeric);
CREATE OR REPLACE PROCEDURE application_data.sync_ft_kpi_target_from_lk_target(
    p_user_id       bigint DEFAULT NULL::bigint,
    p_user_fullname character varying DEFAULT NULL::character varying,
    p_start_date_id numeric DEFAULT NULL::numeric,
    p_end_date_id   numeric DEFAULT NULL::numeric,
    p_plant_id      bigint DEFAULT NULL::bigint,
    p_line_id       bigint DEFAULT NULL::bigint,
    p_kpi_id        bigint DEFAULT NULL::bigint
)
LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description:
--   Propagates targets from application_data.lk_target to application_data.ft_kpi_target.target_value_num.
--   For each row in ft_kpi_target (plant_id, line_id, kpi_id, target_date_iso) sets target_value_num
--   according to the validity interval (start_date_id, end_date_id) in lk_target.
--
-- @Notes:
--   - Updates only existing rows in ft_kpi_target (no insert).
--   - When p_start_date_id and p_end_date_id are both NOT NULL, only rows with target_date_iso in that
--     range (inclusive) are updated; when either is NULL, no date filter is applied (full table).
--   - Optional filters p_plant_id, p_line_id, p_kpi_id restrict sync scope and are written to logs.
--   - Typically called from populate_ft_kpi_target with current month range (first_day..last_day as YYYYMMDD).
--   - p_user_id, p_user_fullname used for log_operation and last_user.
-- ============================================================================================================
DECLARE
    lp_procedure_name VARCHAR(80) := 'application_data.sync_ft_kpi_target_from_lk_target';
    lp_last_user      VARCHAR(200);
    v_rows_updated    bigint;
    v_rows_in_range   bigint := 0;
    v_rows_not_updated bigint := 0;
BEGIN
    lp_last_user := COALESCE(p_user_id::TEXT, '') || COALESCE(' -- ' || NULLIF(trim(p_user_fullname), ''), '');

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Start: sync target_value_num from lk_target to ft_kpi_target. Input: [p_user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') ||
        ', p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') ||
        ', p_start_date_id: ' || COALESCE(p_start_date_id::TEXT, 'NULL') ||
        ', p_end_date_id: ' || COALESCE(p_end_date_id::TEXT, 'NULL') ||
        ', p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', p_line_id: ' || COALESCE(p_line_id::TEXT, 'NULL') ||
        ', p_kpi_id: ' || COALESCE(p_kpi_id::TEXT, 'NULL') || ']',
        lp_last_user
    );

    -- Count rows in range (when date filter is applied) for "not updated" log
    IF p_start_date_id IS NOT NULL AND p_end_date_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_rows_in_range
        FROM application_data.ft_kpi_target t
        WHERE t.target_date_iso >= p_start_date_id
          AND t.target_date_iso <= p_end_date_id
          AND (p_plant_id IS NULL OR t.plant_id = p_plant_id)
          AND (p_line_id  IS NULL OR t.line_id  = p_line_id)
          AND (p_kpi_id   IS NULL OR t.kpi_id   = p_kpi_id);
    END IF;

    WITH updated AS (
        UPDATE application_data.ft_kpi_target t
        SET
            target_value_num = l.target_value_num,
            last_modified    = timezone('UTC', current_timestamp),
            last_user        = lp_last_user
        FROM application_data.lk_target l
        WHERE t.plant_id      = l.plant_id
          AND t.line_id      = l.line_id
          AND t.kpi_id       = l.kpi_id
          AND (p_plant_id IS NULL OR t.plant_id = p_plant_id)
          AND (p_line_id  IS NULL OR t.line_id  = p_line_id)
          AND (p_kpi_id   IS NULL OR t.kpi_id   = p_kpi_id)
          AND l.is_deleted   = false
          AND l.is_active    = true
          AND t.target_date_iso >= l.start_date_id
          AND (l.end_date_id IS NULL OR t.target_date_iso <= l.end_date_id)
          AND (p_start_date_id IS NULL OR t.target_date_iso >= p_start_date_id)
          AND (p_end_date_id   IS NULL OR t.target_date_iso <= p_end_date_id)
        RETURNING t.target_id
    )
    SELECT COUNT(*) INTO v_rows_updated FROM updated;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Completed: rows updated in ft_kpi_target from lk_target = ' || COALESCE(v_rows_updated::TEXT, '0') ||
        '. Scope [plant_id: ' || COALESCE(p_plant_id::TEXT, 'ALL') ||
        ', line_id: ' || COALESCE(p_line_id::TEXT, 'ALL') ||
        ', kpi_id: ' || COALESCE(p_kpi_id::TEXT, 'ALL') ||
        ', start_date_id: ' || COALESCE(p_start_date_id::TEXT, 'MIN') ||
        ', end_date_id: ' || COALESCE(p_end_date_id::TEXT, 'MAX') || ']',
        lp_last_user
    );

    IF v_rows_updated = 0 THEN
        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'No matching lk_target found for requested scope/date range: no records updated. Scope [plant_id: ' ||
            COALESCE(p_plant_id::TEXT, 'ALL') || ', line_id: ' || COALESCE(p_line_id::TEXT, 'ALL') ||
            ', kpi_id: ' || COALESCE(p_kpi_id::TEXT, 'ALL') ||
            ', start_date_id: ' || COALESCE(p_start_date_id::TEXT, 'MIN') ||
            ', end_date_id: ' || COALESCE(p_end_date_id::TEXT, 'MAX') || ']',
            lp_last_user
        );
    END IF;

    -- Log rows in range not updated (no matching lk_target)
    IF v_rows_in_range > 0 THEN
        v_rows_not_updated := v_rows_in_range - v_rows_updated;
        IF v_rows_not_updated > 0 THEN
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Rows in scope/date range not updated (no matching lk_target): ' || v_rows_not_updated::TEXT || ' of ' || v_rows_in_range::TEXT ||
                '. Scope [plant_id: ' || COALESCE(p_plant_id::TEXT, 'ALL') ||
                ', line_id: ' || COALESCE(p_line_id::TEXT, 'ALL') ||
                ', kpi_id: ' || COALESCE(p_kpi_id::TEXT, 'ALL') ||
                ', start_date_id: ' || COALESCE(p_start_date_id::TEXT, 'MIN') ||
                ', end_date_id: ' || COALESCE(p_end_date_id::TEXT, 'MAX') || ']',
                lp_last_user
            );
        END IF;
    END IF;

EXCEPTION WHEN OTHERS THEN
    CALL application_data.log_error_write(lp_procedure_name, SQLERRM::varchar, current_user::varchar);
    RAISE;
END;
$procedure$;

-- DROP PROCEDURE application_data.manage_lk_safety_category(varchar, int8, varchar, varchar, int8, int8, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_safety_category(operation_type character varying, p_safety_category_id bigint DEFAULT NULL::bigint, p_safety_category_code character varying DEFAULT NULL::character varying, p_safety_category_ds character varying DEFAULT NULL::character varying, p_safety_category_sort bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_is_active boolean DEFAULT NULL::boolean, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_safety_category';
    lp_err_msg VARCHAR(2000);
BEGIN
    lp_step := 0;

    -- Log operation input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type::TEXT, 'NULL') || ', ' ||
            'p_safety_category_id: ' || COALESCE(p_safety_category_id::TEXT, 'NULL') || ', ' ||
            'p_safety_category_code: ' || COALESCE(p_safety_category_code::TEXT, 'NULL') || ', ' ||
            'p_safety_category_ds: ' || COALESCE(p_safety_category_ds::TEXT, 'NULL') || ', ' ||
			'p_safety_category_sort: ' || COALESCE(p_safety_category_sort::TEXT, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ']',
       		 p_user_id::TEXT || ' -- ' || p_user_fullname::TEXT
    );

    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Main CASE block to handle operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_safety_category_code IS NULL OR p_safety_category_ds IS NULL OR p_plant_id IS NULL THEN
                lp_err_msg := 'ERROR: Required fields cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_safety_category (
                safety_category_code,
                safety_category_ds,
				safety_category_sort,
                plant_id,
                is_active,
                is_deleted,
                is_modify,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_safety_category_code,
                p_safety_category_ds,
				p_safety_category_sort,
                p_plant_id,
                COALESCE(p_is_active, TRUE),
                FALSE,
                TRUE,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;

            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_safety_category
            WHERE safety_category_id = p_safety_category_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_modify = FALSE).';
            END IF;

            UPDATE application_data.lk_safety_category
            SET
                safety_category_code = COALESCE(p_safety_category_code, safety_category_code),
                safety_category_ds = COALESCE(p_safety_category_ds, safety_category_ds),
				safety_category_sort = COALESCE(p_safety_category_sort, safety_category_sort),
                is_active = COALESCE(p_is_active, is_active),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE safety_category_id = p_safety_category_id AND plant_id = p_plant_id;

        WHEN 'LD' THEN
            -- Logical Deletion
            lp_step := 3;

            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_safety_category
            WHERE safety_category_id = p_safety_category_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_modify = FALSE).';
            END IF;

            UPDATE application_data.lk_safety_category
            SET
                is_deleted = TRUE,
                is_active = FALSE,
                is_modify = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE safety_category_id = p_safety_category_id AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Deletion
            lp_step := 4;

            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_safety_category
            WHERE safety_category_id = p_safety_category_id AND plant_id = p_plant_id AND is_modify = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_modify = FALSE).';
            END IF;

            DELETE FROM application_data.lk_safety_category
            WHERE safety_category_id = p_safety_category_id AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Log errors
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_lk_tier(varchar, int8, varchar, varchar, int4, int8, int8, bool, varchar, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_tier(operation_type character varying, p_tier_id bigint DEFAULT NULL::bigint, p_tier_code character varying DEFAULT NULL::character varying, p_tier_ds character varying DEFAULT NULL::character varying, p_tier_sort integer DEFAULT NULL::integer, p_plant_id bigint DEFAULT NULL::bigint, p_frequency_id bigint DEFAULT NULL::bigint, p_is_active boolean DEFAULT NULL::boolean, p_tier_meeting_color character varying DEFAULT NULL::character varying, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
declare
    lp_last_user VARCHAR;                								 -- Last user info (combines ID and Fullname)
    lp_step NUMERIC;                      								 -- Step for debugging/logging
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_tier';  -- Procedure name
    lp_err_msg VARCHAR(2000);             -- Error message
BEGIN
    lp_step := 0;

    -- Log the operation input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_tier_id: ' || COALESCE(p_tier_id::TEXT, 'NULL') || ', ' ||
            'p_tier_code: ' || COALESCE(p_tier_code, 'NULL') || ', ' ||
            'p_tier_ds: ' || COALESCE(p_tier_ds, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_frequency_id: ' || COALESCE(p_frequency_id::TEXT, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::TEXT, 'NULL') || ', ' ||
			'p_tier_meeting_color: ' || COALESCE(p_tier_meeting_color::TEXT, 'NULL') || ']',
     	    p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- Main CASE block to handle operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert Operation
            lp_step := 1;
            IF p_tier_ds IS NULL 
				OR  p_tier_code IS NULL
				OR p_plant_id IS NULL 
				OR p_tier_sort IS NULL 
				OR p_frequency_id IS NULL THEN
                lp_err_msg := 'ERROR: Required fields cannot be NULL for insertion.';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            INSERT INTO application_data.lk_tier (
                tier_code,
                tier_ds,
				tier_sort,
                plant_id,
				frequency_id,
                is_active,
                is_deleted,
                is_editable,
				tier_meeting_color,
                creation_ts,
                creator_user,
                last_user,
                last_modified
            ) VALUES (
                p_tier_code,
                p_tier_ds,
				p_tier_sort,
                p_plant_id,
				p_frequency_id,
                COALESCE(p_is_active, TRUE),
                FALSE,
                TRUE,
				p_tier_meeting_color,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp)
            );

        WHEN 'U' THEN
            -- Update Operation
            lp_step := 2;

            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_tier
            WHERE tier_id = p_tier_id AND plant_id = p_plant_id AND is_editable = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_editable = FALSE).';
            END IF;

            UPDATE application_data.lk_tier
            SET
                tier_code = COALESCE(p_tier_code, tier_code),
                tier_ds = COALESCE(p_tier_ds, tier_ds),
				tier_sort = COALESCE(p_tier_sort, tier_sort),
                is_active = COALESCE(p_is_active, is_active),
 				frequency_id = COALESCE(p_frequency_id, frequency_id),
				tier_meeting_color = COALESCE(p_tier_meeting_color, tier_meeting_color),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE tier_id = p_tier_id AND plant_id = p_plant_id;

        WHEN 'LD' THEN
            -- Logical Deletion
            lp_step := 3;

            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_tier
            WHERE tier_id = p_tier_id AND plant_id = p_plant_id AND is_editable = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_editable = FALSE).';
            END IF;

            UPDATE application_data.lk_tier
            SET
                is_deleted = TRUE,
                is_active = FALSE,
                is_editable = FALSE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE tier_id = p_tier_id AND plant_id = p_plant_id;

        WHEN 'D' THEN
            -- Physical Deletion
            lp_step := 4;

            -- Check if the record is editable
            PERFORM 1
            FROM application_data.lk_tier
            WHERE tier_id = p_tier_id AND plant_id = p_plant_id AND is_editable = FALSE;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR: The record is not editable (is_editable = FALSE).';
            END IF;

            DELETE FROM application_data.lk_tier
            WHERE tier_id = p_tier_id AND plant_id = p_plant_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'ERROR: Invalid operation_type.';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        -- Log errors
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::TEXT || ' -- ' || p_user_fullname
        );
        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.manage_map_action_issue(varchar, int8, int8, int8, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_map_action_issue(p_operation_type character varying, p_plant_id bigint, p_issue_id bigint, p_action_id bigint, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name TEXT := 'application_data.manage_map_action_issue';
    lp_last_user TEXT := p_user_id::TEXT || ' -- ' || p_user_fullname; 
	procedure_ts TIMESTAMP := timezone('UTC', current_timestamp);    
	lp_log_message TEXT;
    lp_err_msg TEXT;
    lp_step INT;
    lp_plant_timezone TEXT;
    lp_creation_local_ts TIMESTAMP;
    lp_creation_day_local_id INT;
BEGIN
    lp_step := 1;

 	-- Build log message
    lp_log_message :=
        'Input: [operation_type=' || p_operation_type ||
        ', plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', issue_id: ' || COALESCE(p_issue_id::TEXT, 'NULL') ||
        ', action_id: '|| COALESCE(p_action_id::TEXT, 'NULL') || 
		', user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') ||
		', user_fullname: ' || COALESCE(p_user_fullname::TEXT, 'NULL') ||
		']';

   lp_step := 2;
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        procedure_ts,
        lp_procedure_name,
        lp_log_message,
        lp_last_user
    );

    -- Check required parameters
    IF p_user_id IS NULL OR 
	   p_user_fullname IS NULL OR 
	   p_action_id IS NULL OR 
	   p_issue_id IS NULL  THEN
       RAISE EXCEPTION 'Mandatory fields are missing!';
    END IF;

    lp_step := 3;
    SELECT plant_timezone INTO lp_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Plant ID % not found in lk_plant.', p_plant_id;
    END IF;

    lp_step := 4;
    lp_creation_local_ts := procedure_ts AT TIME ZONE 'UTC' AT TIME ZONE lp_plant_timezone;
    lp_creation_day_local_id := TO_CHAR(lp_creation_local_ts, 'YYYYMMDD')::INT;

 
    lp_step := 5;

    -- Perform action
    CASE p_operation_type
        WHEN 'I' THEN
            INSERT INTO application_data.map_action_issue (
                plant_id,
                issue_id,
                action_id,
                creation_day_local_id,
                creation_local_ts,
                creation_utc_ts,
                creator_user
            )
            VALUES (
                p_plant_id,
                p_issue_id,
                p_action_id,
                lp_creation_day_local_id,
                lp_creation_local_ts,
                procedure_ts,
                lp_last_user
            )
            ON CONFLICT DO NOTHING;

        WHEN 'D' THEN
            DELETE FROM application_data.map_action_issue
            WHERE plant_id = p_plant_id
              AND issue_id = p_issue_id
              AND action_id = p_action_id;

        ELSE
            RAISE EXCEPTION 'Invalid operation_type: %, use I or D.', p_operation_type;
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg :='ERROR at step ' || lp_step::TEXT || ' ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            procedure_ts,
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.populate_ft_attendance(int8, int8, varchar, int8, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.populate_ft_attendance(p_status_id bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_attendance_role_list_id character varying DEFAULT NULL::character varying, p_tier_id bigint DEFAULT NULL::bigint, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_plant_id BIGINT;
    lp_day_id INT;
    lp_local_date INT;
    lp_local_time TIME;          
    lp_plant_timezone TEXT;
    lp_plant_code VARCHAR(100);  
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.populate_ft_attendance';
    lp_err_msg VARCHAR(2000);

    v_role_id BIGINT; -- current attendance_role_id
    v_plant_rec RECORD;
    
    -- Variabili conteggio
    v_count_existing INT;
    v_count_inserted INT;

    -- 🔧 PARTITION VARIABLES
    lp_year INT;
    lp_month INT;
    lp_partition_name TEXT;
    lp_partition_exists BOOLEAN;

    plant_cursor CURSOR FOR
        SELECT plant_id, plant_timezone, plant_code
        FROM application_data.lk_plant
        WHERE is_active = TRUE 
          AND is_deleted = FALSE
          AND (p_plant_id IS NULL OR plant_id = p_plant_id);

BEGIN
    lp_step := 0;

    -- STEP 1: Validate mandatory inputs
    lp_step := 1;
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- STEP 2: Log procedure input
    lp_step := 2;
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: p_status_id=' || COALESCE(p_status_id::TEXT, 'NULL') ||
        ', p_plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') ||
        ', p_role_list=' || COALESCE(p_attendance_role_list_id, 'NULL'),
        lp_last_user
    );

    -- STEP 3: Iterate through selected plants
    lp_step := 3;
    FOR v_plant_rec IN plant_cursor LOOP
        
        lp_plant_code := v_plant_rec.plant_code;
        v_count_existing := 0;
        v_count_inserted := 0;

        -- STEP 4: Resolve date and day_id AND TIME
        lp_step := 4;
        
        -- Calcola Orario Locale
        SELECT (NOW() AT TIME ZONE v_plant_rec.plant_timezone)::TIME
        INTO lp_local_time;

        -- Calcola Data Locale
        SELECT TO_CHAR(timezone(v_plant_rec.plant_timezone, current_timestamp), 'YYYYMMDD')::int
        INTO lp_local_date;

        SELECT id_day INTO lp_day_id
        FROM application_data.lk_date
        WHERE id_day = lp_local_date;

        IF lp_day_id IS NULL THEN
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'No valid day_id found for plant ' || trim(lp_plant_code) ||
                ', local_date=' || lp_local_date::TEXT,
                lp_last_user
            );
            CONTINUE;
        END IF;

        ------------------------------------------------------------
        -- 🔧 PARTITION CHECK & CREATION
        ------------------------------------------------------------
        lp_step := 4.5;
        
        -- ✅ CLEANER DATE EXTRACTION: Convert int YYYYMMDD to Date, then extract
        lp_year  := EXTRACT(YEAR  FROM to_date(lp_local_date::TEXT, 'YYYYMMDD'))::INT;
        lp_month := EXTRACT(MONTH FROM to_date(lp_local_date::TEXT, 'YYYYMMDD'))::INT;
        
        -- Naming convention: ft_attendance_plant_<id>_<yyyy><mm>
        lp_partition_name := format('ft_attendance_plant_%s_%s%02s', v_plant_rec.plant_id, lp_year, lp_month);

        -- Check existence
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = 'application_data'
              AND table_name = lp_partition_name
        ) INTO lp_partition_exists;

        -- Create partition if missing
        IF NOT lp_partition_exists THEN
            BEGIN
                -- ft_attendance uses 'day_id' as range column
                PERFORM application_data.create_monthly_partition(
                    'ft_attendance',
                    'day_id', 
                    v_plant_rec.plant_id,
                    lp_year,
                    lp_month
                );

                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'ℹ️ Partition created: ' || lp_partition_name,
                    lp_last_user
                );

            EXCEPTION WHEN OTHERS THEN
                -- Log error but assume we might proceed (or subsequent inserts will fail)
                lp_err_msg := '❌ Partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );
            END;
        END IF;
        ------------------------------------------------------------
        -- END PARTITION LOGIC
        ------------------------------------------------------------

        -- STEP 5: Check if mode is GLOBAL or FILTERED
        lp_step := 5;
        
        IF p_plant_id IS NULL AND p_attendance_role_list_id IS NULL THEN
            ------------------------------------------------------------------
            -- 🌍 GLOBAL MODE: process all plants (Scheduled)
            ------------------------------------------------------------------
            lp_step := 5.1;

            -- CHECK ORARIO (Solo per Global Mode)
			-- Se l'ora non è tra 00:00 e 00:59, logga lo skip e passa al prossimo																	   
            IF lp_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant ' || trim(lp_plant_code) || ' (ID: ' || v_plant_rec.plant_id::TEXT || 
                    ') skipped: Local time ' || lp_local_time::TEXT || ' (TZ: ' || v_plant_rec.plant_timezone || 
                    ') is outside 00:00-00:59 window.',
                    lp_last_user
                );
                CONTINUE; 
            END IF;

            -- Log Start Processing
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Plant ' || trim(lp_plant_code) || ' (Global Mode) processing started: Local=' || lp_local_time::TEXT,
                lp_last_user
            );

            -- Check roles assigned
            lp_step := 5.11;
            IF NOT EXISTS (
                SELECT 1 
                FROM application_data.map_attendance_tier mat
                WHERE mat.plant_id = v_plant_rec.plant_id
                  AND mat.is_active = TRUE 
                  AND mat.is_assigned = TRUE
            ) THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'No assigned roles found for plant ' || trim(lp_plant_code) || ' -> skipping.',
                    lp_last_user
                );
                CONTINUE;
            END IF;

            -- CONTA I RECORD ESISTENTI (Logica Delta)
            SELECT COUNT(1) INTO v_count_existing
            FROM application_data.map_attendance_tier mat
            JOIN application_data.lk_module mod ON mat.plant_id = mod.plant_id
            JOIN application_data.lk_line line ON line.plant_id = mod.plant_id AND line.module_id = mod.module_id AND line.is_active = TRUE AND line.is_deleted = FALSE
            JOIN application_data.ft_attendance ft ON ft.plant_id = mat.plant_id AND ft.tier_id = mat.tier_id AND ft.line_id = line.line_id AND ft.attendance_role_id = mat.attendance_role_id AND ft.day_id = lp_day_id
            WHERE mat.plant_id = v_plant_rec.plant_id AND mat.is_assigned = TRUE AND mat.is_active = TRUE;

            IF v_count_existing > 0 THEN
                INSERT INTO application_data.log_operation (
                     operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                     timezone('UTC', current_timestamp),
                     lp_procedure_name,
                     'Plant ' || trim(lp_plant_code) || ': Found ' || v_count_existing::TEXT || ' existing records. Skipping duplicates.', 
                     lp_last_user
                );
            END IF;

            -- Perform Global Delta Insert
            lp_step := 5.13;
            INSERT INTO application_data.ft_attendance (
                plant_id, tier_id, module_id, line_id,
                day_id, attendance_role_id, status_id,
                creation_ts, creator_user, last_user, last_modified
            )
            SELECT 
                mat.plant_id, mat.tier_id, mod.module_id, line.line_id,
                lp_day_id, mat.attendance_role_id,
                COALESCE(p_status_id, 100),
                timezone('UTC', current_timestamp),
                lp_last_user, lp_last_user, timezone('UTC', current_timestamp)
            FROM application_data.map_attendance_tier mat
            JOIN application_data.lk_module mod ON mat.plant_id = mod.plant_id
            JOIN application_data.lk_attendance_role att_role
              ON mat.attendance_role_id = att_role.attendance_role_id
             AND mat.plant_id = att_role.plant_id
            JOIN application_data.lk_line line
              ON line.plant_id = mod.plant_id
             AND line.module_id = mod.module_id
             AND line.is_active AND NOT line.is_deleted
            WHERE mat.is_assigned AND mat.is_active
              AND mod.is_active AND NOT mod.is_deleted
              AND att_role.is_active AND NOT att_role.is_deleted
              AND mat.plant_id = v_plant_rec.plant_id
              AND NOT EXISTS (
                   SELECT 1 FROM application_data.ft_attendance ft_check
                   WHERE ft_check.plant_id = mat.plant_id
                     AND ft_check.day_id = lp_day_id
                     AND ft_check.tier_id = mat.tier_id
                     AND ft_check.line_id = line.line_id
                     AND ft_check.attendance_role_id = mat.attendance_role_id
               );

            GET DIAGNOSTICS v_count_inserted = ROW_COUNT;

            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Plant ' || trim(lp_plant_code) || ' (Global): Inserted ' || v_count_inserted::TEXT || ' NEW records.',
                lp_last_user
            );

        ELSE
            ------------------------------------------------------------------
            -- 🎯 FILTERED MODE: specific plant/roles (Manual Run)
            ------------------------------------------------------------------
            lp_step := 5.2;

            FOR v_role_id IN
                SELECT btrim(value, ' "''*')::bigint
                FROM regexp_split_to_table(
                    regexp_replace(p_attendance_role_list_id, '^\\*\\*\\*|\\*\\*\\*$' , '', 'g'),
                    ','
                ) AS value
            LOOP
                lp_step := 6;
                v_count_inserted := 0; 

                INSERT INTO application_data.ft_attendance (
                    plant_id, tier_id, module_id, line_id,
                    day_id, attendance_role_id, status_id,
                    creation_ts, creator_user, last_user, last_modified
                )
                SELECT 
                    mat.plant_id, mat.tier_id, mod.module_id, line.line_id,
                    lp_day_id, v_role_id,
                    COALESCE(p_status_id, 100),
                    timezone('UTC', current_timestamp),
                    lp_last_user, lp_last_user, timezone('UTC', current_timestamp)
                FROM application_data.map_attendance_tier mat
                JOIN application_data.lk_module mod ON mat.plant_id = mod.plant_id
                JOIN application_data.lk_attendance_role att_role
                  ON mat.attendance_role_id = att_role.attendance_role_id
                 AND mat.plant_id = att_role.plant_id
                JOIN application_data.lk_line line
                  ON line.plant_id = mod.plant_id
                 AND line.module_id = mod.module_id
                 AND line.is_active AND NOT line.is_deleted
                WHERE mat.is_assigned AND mat.is_active
                  AND mod.is_active AND NOT mod.is_deleted
                  AND att_role.is_active AND NOT att_role.is_deleted
                  AND mat.plant_id = v_plant_rec.plant_id
                  AND mat.attendance_role_id = v_role_id
                  AND mat.tier_id = p_tier_id
                  AND NOT EXISTS (
                       SELECT 1 FROM application_data.ft_attendance ft_check
                       WHERE ft_check.plant_id = mat.plant_id
                         AND ft_check.day_id = lp_day_id
                         AND ft_check.tier_id = mat.tier_id
                         AND ft_check.line_id = line.line_id
                         AND ft_check.attendance_role_id = v_role_id
                    );
                
                GET DIAGNOSTICS v_count_inserted = ROW_COUNT;

                IF v_count_inserted > 0 THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Plant ' || trim(lp_plant_code) || ' (Filtered): Role ' || v_role_id::TEXT || 
                        ', Tier ' || COALESCE(p_tier_id::TEXT, 'NULL') || ' -> Inserted ' || v_count_inserted::TEXT || ' NEW records.',
                        lp_last_user
                    );
                ELSE
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Plant ' || trim(lp_plant_code) || ' (Filtered): Role ' || v_role_id::TEXT || 
                        ', Tier ' || COALESCE(p_tier_id::TEXT, 'NULL') || ' -> 0 records inserted (Already exist or no mapping).',
                        lp_last_user
                    );
                END IF;
                
            END LOOP;
            
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Plant ' || trim(lp_plant_code) || ' (Filtered Mode): Process completed.',
                lp_last_user
            );

        END IF;
    END LOOP;

    -- STEP 10: Final log
    lp_step := 10;
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Procedure completed successfully',
        lp_last_user
    );

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM ||
                      ', SQLSTATE=' || SQLSTATE ||
                      ', Step=' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name, lp_err_msg, lp_last_user
        );
        RAISE;
END;
$procedure$
;



-- DROP PROCEDURE application_data.populate_ft_kpi_target(int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.populate_ft_kpi_target(p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    kpi_rec RECORD;
    lp_target_date DATE;
    lp_target_day_iso INT;
    lp_number_of_input INT;
    number_of_record INT;
    first_day_of_current_month DATE;
    last_day_of_current_month DATE; 
    lp_local_time TIME; 
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.populate_ft_kpi_target';
    lp_err_msg VARCHAR(2000);
    lp_existing_record BOOL;
    lp_exec_safety_kpi BOOLEAN := FALSE;
    
    -- Variable to prevent log flooding when skipping multiple KPIs for the same plant
    lp_last_skipped_plant BIGINT := -1; 

    -- 🔧 PARTITION VARIABLES (Added)
    lp_year INT;
    lp_month INT;
    lp_partition_name TEXT;
    lp_partition_exists BOOLEAN;
    lp_last_partition_check_plant BIGINT := -1; -- To avoid checking schema for every KPI of the same plant

    -- Sync range: current month (UTC) so sync_ft_kpi_target_from_lk_target only updates that month
    lp_sync_start_date_id numeric(8);
    lp_sync_end_date_id   numeric(8);

    -- Cursor for iterating over KPIs
    kpi_cursor CURSOR FOR 
    SELECT
        kpi.kpi_id,
        kpi.tier_id,
        kpi.line_id,
        kpi.module_id,
        kpi.plant_id,
        freq.frequency_id,
        freq.frequency_ds,
        lk_kpi.kpi_category_id,
        lk_kpi.target_tendency_id,
        lk_kpi.kpi_code,
        lk_plant.plant_timezone
    FROM
        application_data.ass_module_line_tier_kpi kpi
    INNER JOIN application_data.lk_tier tier 
        ON kpi.tier_id = tier.tier_id AND kpi.plant_id = tier.plant_id
    INNER JOIN application_data.lk_frequency freq 
        ON tier.frequency_id = freq.frequency_id
    INNER JOIN application_data.lk_kpi lk_kpi 
        ON lk_kpi.kpi_id = kpi.kpi_id AND lk_kpi.plant_id = kpi.plant_id
    INNER JOIN application_data.lk_plant lk_plant 
        ON lk_plant.plant_id=kpi.plant_id AND lk_plant.is_active=true
    WHERE
        kpi.is_active = TRUE
        AND kpi.is_deleted = FALSE 
    ORDER BY
        kpi.plant_id, kpi.kpi_id; 
BEGIN
    lp_step := 0;

    -- Log operation start
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', CURRENT_TIMESTAMP),
        lp_procedure_name,
        'Input: [p_user_id: ' || COALESCE(p_user_id::TEXT, 'NULL') || ', ' ||
        'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- Validate user inputs
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_step := 1;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;
   
    -- Iterate through each KPI
    FOR kpi_rec IN kpi_cursor LOOP
        lp_step := 2;

        ------------------------------------------------------------
        -- Time Check: Execute only between 00:00 and 00:59 local time
        ------------------------------------------------------------
        SELECT (NOW() AT TIME ZONE kpi_rec.plant_timezone)::TIME
        INTO lp_local_time;

        IF lp_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
            
            -- Log the skip ONLY ONCE per plant to avoid flooding the log table
            IF lp_last_skipped_plant IS DISTINCT FROM kpi_rec.plant_id THEN
																						   
                INSERT INTO application_data.log_operation (
                    operation_timestamp,
                    operation_src,
                    operation_msg,
                    operation_caller
                ) VALUES (
                    timezone('UTC', CURRENT_TIMESTAMP),
                    lp_procedure_name,
                    'Plant ID ' || kpi_rec.plant_id::TEXT || ' skipped: Local time (' || lp_local_time::TEXT || ') is outside the 00:00-00:59 window.',
                    lp_last_user
                );
                lp_last_skipped_plant := kpi_rec.plant_id;
            END IF;

            CONTINUE;
        END IF;

        -- Check for Safety KPI
        IF kpi_rec.kpi_code = 'safety events' THEN
            lp_exec_safety_kpi := TRUE;
        ELSE
            lp_exec_safety_kpi := FALSE; 
        END IF;

        -- Get the first day of the current month (Local Plant Time)
        SELECT DATE_TRUNC('month', (CURRENT_TIMESTAMP at time zone kpi_rec.plant_timezone))::DATE
        INTO first_day_of_current_month;

        -- Calculate the last day of the current month
        SELECT (first_day_of_current_month + INTERVAL '1 month' - INTERVAL '1 day')::DATE
        INTO last_day_of_current_month;
        
        ------------------------------------------------------------
        -- 🔧 PARTITION CHECK & CREATION (Added Logic)
        ------------------------------------------------------------
        -- We perform this check only when the plant_id changes to minimize overhead
        IF lp_last_partition_check_plant IS DISTINCT FROM kpi_rec.plant_id THEN
            
            lp_year := EXTRACT(YEAR FROM first_day_of_current_month)::INT;
            lp_month := EXTRACT(MONTH FROM first_day_of_current_month)::INT;
            -- Naming convention: ft_kpi_target_plant_<id>_<yyyy><mm>
            lp_partition_name := format('ft_kpi_target_plant_%s_%s%02s', kpi_rec.plant_id, lp_year, lp_month);

            -- Check existence
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = 'application_data'
                  AND table_name = lp_partition_name
            ) INTO lp_partition_exists;

            -- Create partition if missing
            IF NOT lp_partition_exists THEN
                BEGIN
                    -- Note: ft_kpi_target usually uses 'target_date_iso' as range column
                    PERFORM application_data.create_monthly_partition(
                        'ft_kpi_target',
                        'target_date_iso', 
                        kpi_rec.plant_id,
                        lp_year,
                        lp_month
                    );

                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'ℹ️ Partition created: ' || lp_partition_name,
                        lp_last_user
                    );

                EXCEPTION WHEN OTHERS THEN
                    -- Log error but assume we might proceed (or subsequent inserts will fail)
                    lp_err_msg := '❌ Partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
                    INSERT INTO application_data.log_error (
                        error_timestamp, error_src, error_msg, error_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        lp_err_msg,
                        lp_last_user
                    );
                END;
            END IF;

            -- Update flag to avoid re-checking for this plant in this run
            lp_last_partition_check_plant := kpi_rec.plant_id;
        END IF;
        ------------------------------------------------------------
        -- END PARTITION LOGIC
        ------------------------------------------------------------

        lp_step := 2.05;

        ------------------------------------------------------------
        -- 🚀 SMART SKIP: Check if targets for this month already exist
        ------------------------------------------------------------
        PERFORM 1 
        FROM application_data.ft_kpi_target
        WHERE kpi_id = kpi_rec.kpi_id
          AND tier_id = kpi_rec.tier_id
          AND plant_id = kpi_rec.plant_id
          AND line_id = kpi_rec.line_id        
          AND module_id = kpi_rec.module_id   
          AND target_date >= first_day_of_current_month
          AND target_date <= last_day_of_current_month
        LIMIT 1;

        IF FOUND THEN
            -- Data already populated for this specific KPI context in this month.
            
																
            INSERT INTO application_data.log_operation (
                operation_timestamp,
                operation_src,
                operation_msg,
                operation_caller
            ) VALUES (
                timezone('UTC', CURRENT_TIMESTAMP),
                lp_procedure_name,
                'Smart Skip: Targets already exist for KPI ' || kpi_rec.kpi_id::TEXT || 
                ' (Plant ' || kpi_rec.plant_id::TEXT || 
                ', Tier ' || kpi_rec.tier_id::TEXT || 
                ', Line ' || COALESCE(kpi_rec.line_id::TEXT, 'N/A') || 
                ') for month starting ' || first_day_of_current_month::TEXT || '. Skipping calculation.',
                lp_last_user
            );

            -- Skip calculation and move to next KPI.
            CONTINUE; 
        END IF;

        ------------------------------------------------------------
        -- Start Calculation (Only if Smart Skip didn't trigger)
        ------------------------------------------------------------
        lp_step := 2.1;
    
        -- Calculate MAX number of records (Safety limit)
        CASE kpi_rec.frequency_ds
            WHEN '<#Daily/>' THEN 
                number_of_record := DATE_PART('day', last_day_of_current_month)::INT;
            WHEN '<#Weekly/>' THEN
                number_of_record := 5; -- Max weeks in a month
            WHEN '<#Biweekly/>' THEN
                number_of_record := 3; -- Max bi-weeks in a month
            WHEN '<#Monthly/>' THEN
                number_of_record := 1;
            WHEN '<#Bimonthly/>' THEN
                number_of_record := 1;
            WHEN '<#Quarterly/>' THEN  
                number_of_record := 1;
            WHEN '<#Annually/>' THEN
                number_of_record := 1;
            ELSE
                lp_step := 2.2;
                number_of_record := DATE_PART('day', last_day_of_current_month)::INT;
        END CASE;

        lp_step := 2.3;

        FOR lp_number_of_input IN 1..number_of_record LOOP
            -- Determine the target date based on frequency
            CASE kpi_rec.frequency_ds
                WHEN '<#Daily/>' THEN 
                    lp_target_date := (first_day_of_current_month + ( (lp_number_of_input-1)  * INTERVAL '1 day'))::DATE;

                WHEN '<#Weekly/>' THEN
                    -- Using (lp_number_of_input - 1) to catch the first week
                    lp_target_date := (DATE_TRUNC('week', first_day_of_current_month) + ((lp_number_of_input - 1) * INTERVAL '7 days'))::DATE;

                WHEN '<#Biweekly/>' THEN
                    -- Using (lp_number_of_input - 1)
                    lp_target_date := (DATE_TRUNC('week', first_day_of_current_month) + ((lp_number_of_input - 1) * INTERVAL '14 days'))::DATE;

                WHEN '<#Monthly/>' THEN
                    lp_target_date := (DATE_TRUNC('month', first_day_of_current_month) + ((lp_number_of_input - 1) * INTERVAL '1 month'))::DATE;

                WHEN '<#Bimonthly/>' THEN
                    lp_target_date := (DATE_TRUNC('month', first_day_of_current_month) + ((lp_number_of_input - 1) * INTERVAL '2 months'))::DATE;

                WHEN '<#Quarterly/>' THEN
                    lp_target_date := (DATE_TRUNC('quarter', first_day_of_current_month) + ((lp_number_of_input - 1) * INTERVAL '3 months'))::DATE;

                WHEN '<#Annually/>' THEN
                    lp_target_date := (DATE_TRUNC('year', first_day_of_current_month) + ((lp_number_of_input - 1) * INTERVAL '1 year'))::DATE;

                ELSE
                    lp_target_date := (first_day_of_current_month + (lp_number_of_input * INTERVAL '1 day'))::DATE;
            END CASE;

            ------------------------------------------------------------
            -- VALIDATION: Ensure the date is within the CURRENT MONTH
            ------------------------------------------------------------
            
            -- If calculated date is beyond the end of the month, stop generating
            IF lp_target_date > last_day_of_current_month THEN
                EXIT; 
            END IF;
            
            -- If calculated date is in the previous month (possible with week logic), skip it
            IF lp_target_date < first_day_of_current_month THEN
                CONTINUE; 
            END IF;

            lp_target_day_iso := TO_CHAR(lp_target_date, 'YYYYMMDD')::INT;

            -- CHECK if record already exists (Double check for safety before insert)
            PERFORM 1 FROM application_data.ft_kpi_target
                WHERE kpi_id=kpi_rec.kpi_id
                AND tier_id=kpi_rec.tier_id
                AND line_id=kpi_rec.line_id
                AND module_id=kpi_rec.module_id
                AND plant_id=kpi_rec.plant_id
                AND kpi_category_id=kpi_rec.kpi_category_id
                AND target_date = lp_target_date;
            
            IF FOUND THEN
                 lp_existing_record := TRUE;
            ELSE
                 lp_existing_record := FALSE;
            END IF;

            -- DETAILED DEBUG LOG
            INSERT INTO application_data.log_operation (
                operation_timestamp,
                operation_src,
                operation_msg,
                operation_caller
             ) VALUES (
                 timezone('UTC', CURRENT_TIMESTAMP),
                 lp_procedure_name,
                     'Input: [Kpi_id: ' || COALESCE(kpi_rec.kpi_id::TEXT, 'NULL') || ', ' ||
                     'tier_id: ' || COALESCE(kpi_rec.tier_id::TEXT, 'NULL')  || ', ' ||
                    'plant_id: ' || COALESCE(kpi_rec.plant_id::TEXT, 'NULL') || ', ' ||
                    'lp_target_date: ' || COALESCE(lp_target_date::TEXT, 'NULL')  || ', ' ||
                    'existing_record: ' || COALESCE(lp_existing_record::TEXT, 'NULL') || ']',
                 p_user_id::TEXT || ' -- ' || p_user_fullname
             );

            -- Insert with ON CONFLICT DO NOTHING
            INSERT INTO application_data.ft_kpi_target (
                target_id,
                kpi_id,
                tier_id,
                line_id,
                module_id,
                plant_id,
                kpi_category_id,
                target_tendency_id,
                target_date,
                target_date_iso,
                frequency_id,
                frequency_ds,
                target_value_num,
                kpi_value,
                is_visible,
                is_editable,
                creation_ts,
                creator_user,
                last_modified,
                last_user
            ) VALUES (
                nextval('application_data.ft_kpi_target_seq'),
                kpi_rec.kpi_id,
                kpi_rec.tier_id,
                kpi_rec.line_id,
                kpi_rec.module_id,
                kpi_rec.plant_id,
                kpi_rec.kpi_category_id,
                kpi_rec.target_tendency_id,
                lp_target_date,
                lp_target_day_iso,
                kpi_rec.frequency_id,
                kpi_rec.frequency_ds,
                case when lp_exec_safety_kpi=TRUE THEN 0 ELSE NULL END,
                NULL,
                TRUE,
                TRUE,
                timezone('UTC', CURRENT_TIMESTAMP),
                lp_last_user,
                timezone('UTC', CURRENT_TIMESTAMP),
                lp_last_user
            )
            ON CONFLICT ON CONSTRAINT ft_kpi_target_unique DO NOTHING;

        END LOOP;
    END LOOP;

    -- Sync target_value_num from lk_target to ft_kpi_target only for current month (same range as inserts: first_day_of_current_month..last_day_of_current_month from loop)
    lp_sync_start_date_id := to_char(first_day_of_current_month, 'YYYYMMDD')::numeric(8);
    lp_sync_end_date_id   := to_char(last_day_of_current_month, 'YYYYMMDD')::numeric(8);
    BEGIN
        CALL application_data.sync_ft_kpi_target_from_lk_target(p_user_id, p_user_fullname, lp_sync_start_date_id, lp_sync_end_date_id);
    EXCEPTION WHEN OTHERS THEN
        lp_err_msg := 'sync_ft_kpi_target_from_lk_target failed: ' || SQLERRM;
        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        -- Do not re-raise: insertion completed; sync is best-effort
    END;

    -- Log successful completion
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', CURRENT_TIMESTAMP),
        lp_procedure_name,
        'KPI target data insertion completed successfully',
        lp_last_user
    );

EXCEPTION
    WHEN OTHERS THEN
															   
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step: ' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;



-- DROP PROCEDURE application_data.populate_ft_quality_fpy(date, date, int8, int8, int8, varchar);
CREATE OR REPLACE PROCEDURE application_data.populate_ft_quality_fpy(
    IN p_date_min DATE DEFAULT NULL,
    IN p_date_max DATE DEFAULT NULL,
    IN p_plant_id BIGINT DEFAULT NULL,
    IN p_line_id BIGINT DEFAULT NULL,
    IN p_user_id BIGINT DEFAULT NULL,
    IN p_user_fullname character varying DEFAULT NULL::character varying
)
LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description:
--   Popola la tabella di appoggio application_data.ft_quality con i conteggi FPY (good/total first-pass)
--   per giorno con dettaglio component/fixture/shift (da application_data.ft_rawdata).
--   Poi aggiorna application_data.ft_kpi_target per il KPI con kpi_code='FPY' a livello di linea/giorno
--   (su tutti i tier), considerando solo gli step (lk_machine) con fpy_active=true.
--
-- @Notes:
--   - ft_quality NON salva il KPI (rapporto), ma solo good_first_pass e total_first_pass.
--   - ft_kpi_target viene aggiornato solo se esiste già il record (no insert).
--   - Filtra sempre pass_number=0 (first pass).
--   - Esecuzione schedulata: se p_date_min e p_date_max sono NULL, la procedura processa "ieri" per ciascun
--     plant *solo* se l'ora locale del plant è tra 00:00 e 00:59 (logga SKIP altrimenti).
--   - Partizioni: come populate_ft_attendance, crea se necessario le partizioni per plant/mese
--     (LIST(plant_id) -> RANGE(day_id/target_date_iso)).
-- ============================================================================================================
DECLARE
    lp_last_user     TEXT;
    lp_step          NUMERIC := 0;
    lp_procedure_name TEXT := 'application_data.populate_ft_quality_fpy';
    lp_err_msg       TEXT;
    v_date_min       DATE;
    v_date_max       DATE;
    v_day_id_min     NUMERIC(8);
    v_day_id_max     NUMERIC(8);

    -- Per-plant gate (timezone)
    v_plant_rec      RECORD;
    v_plant_timezone TEXT;
    v_local_time     TIME;
    v_yesterday_local DATE;

    -- Partition helpers (monthly)
    v_month_cursor   DATE;
    v_month_end      DATE;
    v_year           INT;
    v_month          INT;

    v_rows_deleted   BIGINT := 0;
    v_rows_inserted  BIGINT := 0;
    v_rows_updated   BIGINT := 0;

    -- FPY threshold check (lk_threshold for KPI 'FPY'): run calculations only if sum(total_production) > threshold per day/line
    v_fpy_kpi_id       BIGINT;
    v_threshold_rec    RECORD;
    v_skipped_count    INT := 0;
    v_missing_threshold_count INT := 0;
    v_not_exceeded_count INT := 0;
    v_kpi_skipped      INT := 0;
    -- Arrays to store threshold check results (calculated once, used in all steps)
    v_passing_days     NUMERIC(8)[];
    v_passing_lines    BIGINT[];
    v_missing_days     NUMERIC(8)[];
    v_missing_lines    BIGINT[];
    v_missing_prods    BIGINT[];
    v_failing_days     NUMERIC(8)[];
    v_failing_lines    BIGINT[];
    v_failing_prods    BIGINT[];
    v_failing_thresholds NUMERIC(18,6)[];
    v_line_rec         RECORD;
BEGIN
    lp_step := 0;

    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: p_date_min=' || COALESCE(p_date_min::TEXT, 'NULL') || ', p_date_max=' || COALESCE(p_date_max::TEXT, 'NULL') ||
        ', p_plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') || ', p_line_id=' || COALESCE(p_line_id::TEXT, 'NULL'),
        lp_last_user
    );

    -- STEP 1..N: iterate plants and apply time-gate + partition checks + calc
    lp_step := 1;
    FOR v_plant_rec IN
        SELECT plant_id, plant_code, plant_timezone
        FROM application_data.lk_plant
        WHERE is_active = TRUE
          AND is_deleted = FALSE
          AND (p_plant_id IS NULL OR plant_id = p_plant_id)
        ORDER BY plant_id
    LOOP
        -- Timezone is mandatory for execution: if missing, skip plant and log it.
        v_plant_timezone := NULLIF(btrim(v_plant_rec.plant_timezone), '');
        IF v_plant_timezone IS NULL THEN
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'SKIP plant ' || COALESCE(btrim(v_plant_rec.plant_code), '?') ||
                ' (ID=' || v_plant_rec.plant_id::TEXT || '): missing plant_timezone in application_data.lk_plant.',
                lp_last_user
            );
            CONTINUE;
        END IF;

        -- Local time for gating
        SELECT (NOW() AT TIME ZONE v_plant_timezone)::TIME
        INTO v_local_time;

        -- Scheduled mode = dates not passed: run only once/day per plant (00:00-00:59 local time), for yesterday local
        IF p_date_min IS NULL AND p_date_max IS NULL THEN
            IF v_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'SKIP plant ' || COALESCE(btrim(v_plant_rec.plant_code), '?') ||
                    ' (ID=' || v_plant_rec.plant_id::TEXT || '): local time ' || COALESCE(v_local_time::TEXT, '?') ||
                    ' (TZ=' || v_plant_timezone || ') is outside 00:00-00:59 window.',
                    lp_last_user
                );
                CONTINUE;
            END IF;

            v_yesterday_local := (timezone(v_plant_timezone, current_timestamp)::DATE - 1);
            v_date_min := v_yesterday_local;
            v_date_max := v_yesterday_local;
        ELSE
            -- Manual mode: use the requested range (max may be NULL = open range)
            v_date_min := COALESCE(p_date_min, p_date_max);
            v_date_max := p_date_max;
        END IF;

        v_day_id_min := to_char(v_date_min, 'YYYYMMDD')::NUMERIC(8);
        IF v_date_max IS NOT NULL THEN
            v_day_id_max := to_char(v_date_max, 'YYYYMMDD')::NUMERIC(8);
        ELSE
            v_day_id_max := NULL;
        END IF;

        ------------------------------------------------------------------
        -- PARTITION CHECK & CREATION (ft_quality + ft_kpi_target)
        -- - ensure LIST plant partition exists
        -- - ensure monthly RANGE partition exists for months in requested window (best-effort)
        ------------------------------------------------------------------
        lp_step := 1.5;
        BEGIN
            PERFORM application_data.create_plant_partition('ft_quality', 'day_id', v_plant_rec.plant_id);
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE IN ('42P07', 'P0001') THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Plant partition ft_quality_plant_' || v_plant_rec.plant_id::TEXT || ' already exists, continuing.',
                        lp_last_user
                    );
                ELSE
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_plant_partition(ft_quality) failed for plant_id=' || v_plant_rec.plant_id::TEXT || ': ' || SQLERRM,
                        lp_last_user
                    );
                END IF;
        END;

        BEGIN
            PERFORM application_data.create_plant_partition('ft_kpi_target', 'target_date_iso', v_plant_rec.plant_id);
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE IN ('42P07', 'P0001') THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Plant partition ft_kpi_target_plant_' || v_plant_rec.plant_id::TEXT || ' already exists, continuing.',
                        lp_last_user
                    );
                ELSE
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_plant_partition(ft_kpi_target) failed for plant_id=' || v_plant_rec.plant_id::TEXT || ': ' || SQLERRM,
                        lp_last_user
                    );
                END IF;
        END;

        -- Create monthly partitions for the month(s) in range (if open range, only month of v_date_min)
        v_month_cursor := date_trunc('month', v_date_min)::DATE;
        v_month_end := date_trunc('month', COALESCE(v_date_max, v_date_min))::DATE;
        WHILE v_month_cursor <= v_month_end LOOP
            v_year := EXTRACT(YEAR FROM v_month_cursor)::INT;
            v_month := EXTRACT(MONTH FROM v_month_cursor)::INT;

            BEGIN
                PERFORM application_data.create_monthly_partition('ft_quality', 'day_id', v_plant_rec.plant_id, v_year, v_month);
            EXCEPTION
                WHEN SQLSTATE '42P07' THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Monthly partition ft_quality_plant_' || v_plant_rec.plant_id::TEXT || '_' || v_year::TEXT || lpad(v_month::TEXT, 2, '0') || ' already exists, continuing.',
                        lp_last_user
                    );
                WHEN OTHERS THEN
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_monthly_partition(ft_quality) failed for plant_id=' || v_plant_rec.plant_id::TEXT ||
                        ', ' || v_year::TEXT || '-' || lpad(v_month::TEXT, 2, '0') || ': ' || SQLERRM,
                        lp_last_user
                    );
            END;

            BEGIN
                PERFORM application_data.create_monthly_partition('ft_kpi_target', 'target_date_iso', v_plant_rec.plant_id, v_year, v_month);
            EXCEPTION
                WHEN SQLSTATE '42P07' THEN
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Monthly partition ft_kpi_target_plant_' || v_plant_rec.plant_id::TEXT || '_' || v_year::TEXT || lpad(v_month::TEXT, 2, '0') || ' already exists, continuing.',
                        lp_last_user
                    );
                WHEN OTHERS THEN
                    CALL application_data.log_error_write(
                        lp_procedure_name,
                        'create_monthly_partition(ft_kpi_target) failed for plant_id=' || v_plant_rec.plant_id::TEXT ||
                        ', ' || v_year::TEXT || '-' || lpad(v_month::TEXT, 2, '0') || ': ' || SQLERRM,
                        lp_last_user
                    );
            END;

            v_month_cursor := (v_month_cursor + INTERVAL '1 month')::DATE;
        END LOOP;

        ------------------------------------------------------------------
        -- STEP 1.8: FPY threshold check (lk_threshold)
        -- For each day/line in range: sum(ft_rawdata.total_production) must be > threshold (value valid for that day).
        -- Threshold is taken from lk_threshold for KPI 'FPY', validity: day between start_date_local and end_date_local.
        -- Days/lines with missing threshold are logged and skipped (ft_quality not populated, ft_kpi_target.kpi_value set to -99).
        -- Days/lines that don't exceed threshold are logged and skipped (ft_quality not populated, ft_kpi_target.kpi_value set to -100).
        -- Only days/lines that exceed threshold are processed normally.
        -- NOTE: Threshold calculated ONCE here and stored in arrays for use in subsequent steps.
        ------------------------------------------------------------------
        lp_step := 1.8;
        SELECT k.kpi_id INTO v_fpy_kpi_id
        FROM application_data.lk_kpi k
        WHERE k.plant_id = v_plant_rec.plant_id
          AND k.kpi_code = 'FPY'
          AND k.is_deleted = FALSE;

        -- Calculate threshold status ONCE and populate arrays
        WITH threshold_status AS (
            SELECT
                fr.day_id,
                fr.line_id,
                SUM(fr.total_production)::BIGINT AS total_prod,
                (SELECT t.threshold_value
                 FROM application_data.lk_threshold t
                 WHERE t.plant_id = v_plant_rec.plant_id
                   AND t.line_id = fr.line_id
                   AND t.kpi_id = v_fpy_kpi_id
                   AND t.is_deleted = FALSE
                   AND t.is_active = TRUE
                   AND t.start_date_local::date <= to_date(fr.day_id::TEXT, 'YYYYMMDD')
                   AND (t.end_date_local IS NULL OR t.end_date_local::date >= to_date(fr.day_id::TEXT, 'YYYYMMDD'))
                 ORDER BY t.start_date_local DESC
                 LIMIT 1) AS threshold_value
            FROM application_data.ft_rawdata fr
            WHERE fr.plant_id = v_plant_rec.plant_id
              AND fr.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR fr.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR fr.line_id = p_line_id)
            GROUP BY fr.day_id, fr.line_id
        )
        SELECT
            COALESCE(array_agg(day_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod > threshold_value), '{}'),
            COALESCE(array_agg(line_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod > threshold_value), '{}'),
            COALESCE(array_agg(day_id) FILTER (WHERE threshold_value IS NULL), '{}'),
            COALESCE(array_agg(line_id) FILTER (WHERE threshold_value IS NULL), '{}'),
            COALESCE(array_agg(total_prod) FILTER (WHERE threshold_value IS NULL), '{}'),
            COALESCE(array_agg(day_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}'),
            COALESCE(array_agg(line_id) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}'),
            COALESCE(array_agg(total_prod) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}'),
            COALESCE(array_agg(threshold_value) FILTER (WHERE threshold_value IS NOT NULL AND total_prod <= threshold_value), '{}')
        INTO v_passing_days, v_passing_lines, v_missing_days, v_missing_lines, v_missing_prods, v_failing_days, v_failing_lines, v_failing_prods, v_failing_thresholds
        FROM threshold_status;

        -- Log each day/line with missing threshold (cannot proceed with calculation/load)
        v_skipped_count := 0;
        v_missing_threshold_count := 0;
        IF array_length(v_missing_days, 1) > 0 THEN
            FOR i IN 1..array_length(v_missing_days, 1) LOOP
                v_missing_threshold_count := v_missing_threshold_count + 1;
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'FPY threshold missing: no active lk_threshold row found for plant_id=' || v_plant_rec.plant_id::TEXT ||
                    ', line_id=' || v_missing_lines[i]::TEXT ||
                    ', day_id=' || v_missing_days[i]::TEXT ||
                    '. total_production=' || v_missing_prods[i]::TEXT ||
                    '. Skipping ft_quality load and FPY calculation for this day/line (kpi_value set to -99).',
                    lp_last_user
                );
            END LOOP;
        END IF;

        -- Log each day/line that does NOT exceed threshold
        v_not_exceeded_count := 0;
        IF array_length(v_failing_days, 1) > 0 THEN
            FOR i IN 1..array_length(v_failing_days, 1) LOOP
                v_not_exceeded_count := v_not_exceeded_count + 1;
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'FPY threshold not exceeded (line did not work): total_production=' || v_failing_prods[i]::TEXT ||
                    ', threshold=' || v_failing_thresholds[i]::TEXT ||
                    ' for plant_id=' || v_plant_rec.plant_id::TEXT ||
                    ', line_id=' || v_failing_lines[i]::TEXT ||
                    ', day_id=' || v_failing_days[i]::TEXT || '. FPY calculation skipped, kpi_value set to -100.',
                    lp_last_user
                );
            END LOOP;
        END IF;
        v_skipped_count := v_missing_threshold_count + v_not_exceeded_count;

        ------------------------------------------------------------------
        -- STEP 2: cleanup existing ft_quality rows (this plant + selected range)
        -- Only for day/line combinations that pass the threshold (line worked that day)
        -- Uses pre-calculated arrays from STEP 1.8
        ------------------------------------------------------------------
        lp_step := 2;
        DELETE FROM application_data.ft_quality q
        WHERE q.plant_id = v_plant_rec.plant_id
          AND q.day_id >= v_day_id_min
          AND (v_day_id_max IS NULL OR q.day_id <= v_day_id_max)
          AND (p_line_id IS NULL OR q.line_id = p_line_id)
          AND EXISTS (
              SELECT 1 FROM unnest(v_passing_days, v_passing_lines) AS t(d, l)
              WHERE t.d = q.day_id AND t.l = q.line_id
          );
        GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

        ------------------------------------------------------------------
        -- STEP 3: populate ft_quality (detail day + component + fixture + shift) for this plant
        -- Only for day/line combinations that pass the threshold (line worked that day)
        -- Uses pre-calculated arrays from STEP 1.8
        ------------------------------------------------------------------
        lp_step := 3;
        INSERT INTO application_data.ft_quality (
            plant_id,
            line_id,
            day_id,
            production_date,
            shift_dwh_id,
            code_id,
            machine_id,
            component_id,
            fixture_id,
            good_first_pass,
            total_first_pass,
            calc_ts,
            calc_caller
        )
        SELECT
            fr.plant_id,
            fr.line_id,
            fr.day_id,
            to_date(fr.day_id::TEXT, 'YYYYMMDD') AS production_date,
            fr.shift_dwh_id,
            fr.code_id,
            fr.machine_id,
            fr.component_id,
            fr.fixture_id,
            COUNT(*) FILTER (WHERE lr.is_good = true)::BIGINT AS good_first_pass,
            COUNT(*)::BIGINT AS total_first_pass,
            timezone('UTC', current_timestamp),
            lp_last_user
        FROM application_data.ft_rawdata fr
        LEFT JOIN application_data.lk_result lr
          ON lr.result_id = fr.result_id
        WHERE fr.plant_id = v_plant_rec.plant_id
          AND fr.pass_number = 0
          AND fr.day_id >= v_day_id_min
          AND (v_day_id_max IS NULL OR fr.day_id <= v_day_id_max)
          AND (p_line_id IS NULL OR fr.line_id = p_line_id)
          AND EXISTS (
              SELECT 1 FROM unnest(v_passing_days, v_passing_lines) AS t(d, l)
              WHERE t.d = fr.day_id AND t.l = fr.line_id
          )
        GROUP BY
            fr.plant_id,
            fr.line_id,
            fr.day_id,
            fr.shift_dwh_id,
            fr.code_id,
            fr.machine_id,
            fr.component_id,
            fr.fixture_id;
        GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;

        ------------------------------------------------------------------
        -- STEP 4: update ft_kpi_target for KPI code 'FPY' at line/day level, all tiers (this plant)
        -- Uses data from ft_quality (already populated in STEP 3 for passing day/lines only)
        -- No need to re-query ft_rawdata - ft_quality already has good_first_pass and total_first_pass
        ------------------------------------------------------------------
        lp_step := 4;
        WITH machine_fpy AS (
            -- Machine-level FPY aggregated from ft_quality, filtered by fpy_active machines
            SELECT
                fq.plant_id,
                fq.line_id,
                fq.day_id,
                fq.machine_id,
                SUM(fq.total_first_pass)::BIGINT AS total_first_pass,
                SUM(fq.good_first_pass)::BIGINT AS good_first_pass
            FROM application_data.ft_quality fq
            JOIN application_data.lk_machine m
              ON m.machine_id = fq.machine_id
             AND m.plant_id = fq.plant_id
             AND m.is_deleted = false
             AND m.fpy_active = true
            WHERE fq.plant_id = v_plant_rec.plant_id
              AND fq.day_id >= v_day_id_min
              AND (v_day_id_max IS NULL OR fq.day_id <= v_day_id_max)
              AND (p_line_id IS NULL OR fq.line_id = p_line_id)
            GROUP BY fq.plant_id, fq.line_id, fq.day_id, fq.machine_id
        ),
        agg AS (
            -- Line-level FPY is the product of machine FPYs:
            -- FPY_line = Π_i (good_i/total_i)  over fpy_active machines with data.
            SELECT
                mf.plant_id,
                mf.line_id,
                mf.day_id AS target_date_iso,
                SUM(mf.good_first_pass)::BIGINT AS good_first_pass,
                SUM(mf.total_first_pass)::BIGINT AS total_first_pass,
                CASE
                    WHEN COUNT(*) FILTER (WHERE mf.total_first_pass > 0) = 0 THEN NULL
                    WHEN BOOL_OR(mf.good_first_pass = 0) THEN 0::NUMERIC
                    ELSE exp(
                        SUM(
                            ln( (mf.good_first_pass::NUMERIC) / NULLIF(mf.total_first_pass::NUMERIC, 0) )
                        ) FILTER (WHERE mf.good_first_pass > 0)
                    )
                END AS fpy_product_ratio
            FROM machine_fpy mf
            WHERE mf.total_first_pass > 0
            GROUP BY mf.plant_id, mf.line_id, mf.day_id
        )
        UPDATE application_data.ft_kpi_target tgt
        SET
            kpi_value = CASE
                WHEN agg.fpy_product_ratio IS NOT NULL THEN round(agg.fpy_product_ratio * 100, 6)
                ELSE NULL
            END,
            good_value = agg.good_first_pass::NUMERIC(18,6),
            total_good = agg.total_first_pass::NUMERIC(18,6),
            last_modified = timezone('UTC', current_timestamp),
            last_user = lp_last_user
        FROM agg,
             application_data.lk_kpi k
        WHERE k.kpi_id = tgt.kpi_id
          AND k.plant_id = tgt.plant_id
          AND k.is_deleted = false
          AND k.kpi_code = 'FPY'
          AND tgt.plant_id = agg.plant_id
          AND tgt.line_id = agg.line_id
          AND tgt.target_date_iso = agg.target_date_iso;
        GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

        ------------------------------------------------------------------
        -- STEP 4b: set kpi_value marker for day/line where FPY cannot be calculated
        -- Cases: threshold missing OR threshold not exceeded
        -- Uses pre-calculated arrays from STEP 1.8
        ------------------------------------------------------------------
        UPDATE application_data.ft_kpi_target tgt
        SET
            kpi_value = CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM unnest(v_missing_days, v_missing_lines) AS t_missing(d, l)
                    WHERE t_missing.d = tgt.target_date_iso
                      AND t_missing.l = tgt.line_id
                ) THEN -99
                WHEN EXISTS (
                    SELECT 1
                    FROM unnest(v_failing_days, v_failing_lines) AS t_failing(d, l)
                    WHERE t_failing.d = tgt.target_date_iso
                      AND t_failing.l = tgt.line_id
                ) THEN -100
                ELSE tgt.kpi_value
            END,
            good_value = NULL,
            total_good = NULL,
            last_modified = timezone('UTC', current_timestamp),
            last_user = lp_last_user
        FROM application_data.lk_kpi k
        WHERE k.kpi_id = tgt.kpi_id
          AND k.plant_id = tgt.plant_id
          AND k.is_deleted = FALSE
          AND k.kpi_code = 'FPY'
          AND tgt.plant_id = v_plant_rec.plant_id
          AND EXISTS (
              SELECT 1 FROM (
                  SELECT t1.d, t1.l FROM unnest(v_failing_days, v_failing_lines) AS t1(d, l)
                  UNION ALL
                  SELECT t2.d, t2.l FROM unnest(v_missing_days, v_missing_lines) AS t2(d, l)
              ) t
              WHERE t.d = tgt.target_date_iso AND t.l = tgt.line_id
          );
        GET DIAGNOSTICS v_kpi_skipped = ROW_COUNT;

        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Plant ' || COALESCE(btrim(v_plant_rec.plant_code), '?') || ' (ID=' || v_plant_rec.plant_id::TEXT || '): ' ||
            'range=[' || v_date_min::TEXT || ',' || COALESCE(v_date_max::TEXT, 'NULL') || '], ' ||
            'Deleted=' || v_rows_deleted::TEXT || ', Inserted=' || v_rows_inserted::TEXT || 
            ', Updated ft_kpi_target=' || v_rows_updated::TEXT || 
            ', Skipped missing-threshold=' || v_missing_threshold_count::TEXT ||
            ', Skipped threshold-not-exceeded=' || v_not_exceeded_count::TEXT ||
            ', Skipped total (kpi_value=-99/-100)=' || v_kpi_skipped::TEXT,
            lp_last_user
        );

        ------------------------------------------------------------------
        -- STEP 5: update target_value_num (weighted target) via manage_target
        -- - In scheduled mode (no dates passed), keep manage_target scheduled semantics (<= yesterday + backlog).
        -- - In manual mode (range requested), align manage_target to the same range (supports open range if max is NULL).
        -- - If p_line_id IS NULL, execute manage_target line-by-line for all plant lines.
        -- - Bypass manage_target time-gate because populate_ft_quality_fpy already enforced it in scheduled mode.
        ------------------------------------------------------------------
        lp_step := 5;
        IF p_line_id IS NULL THEN
            FOR v_line_rec IN
                SELECT l.line_id
                FROM application_data.lk_line l
                WHERE l.plant_id = v_plant_rec.plant_id
                  AND l.is_deleted = false
                  AND COALESCE(btrim(l.line_code), '') <> '(U)'
                ORDER BY l.line_id
            LOOP
                IF p_date_min IS NULL AND p_date_max IS NULL THEN
                    CALL application_data.manage_target(
                        p_date_min => NULL,
                        p_date_max => NULL,
                        p_plant_id => v_plant_rec.plant_id,
                        p_line_id => v_line_rec.line_id,
                        p_user_id => p_user_id,
                        p_user_fullname => p_user_fullname,
                        p_bypass_gate => TRUE
                    );
                ELSE
                    CALL application_data.manage_target(
                        p_date_min => v_date_min,
                        p_date_max => v_date_max,
                        p_plant_id => v_plant_rec.plant_id,
                        p_line_id => v_line_rec.line_id,
                        p_user_id => p_user_id,
                        p_user_fullname => p_user_fullname,
                        p_bypass_gate => TRUE
                    );
                END IF;
            END LOOP;
        ELSE
            IF EXISTS (
                SELECT 1
                FROM application_data.lk_line l
                WHERE l.plant_id = v_plant_rec.plant_id
                  AND l.line_id = p_line_id
                  AND l.is_deleted = false
                  AND COALESCE(btrim(l.line_code), '') <> '(U)'
            ) THEN
                IF p_date_min IS NULL AND p_date_max IS NULL THEN
                    CALL application_data.manage_target(
                        p_date_min => NULL,
                        p_date_max => NULL,
                        p_plant_id => v_plant_rec.plant_id,
                        p_line_id => p_line_id,
                        p_user_id => p_user_id,
                        p_user_fullname => p_user_fullname,
                        p_bypass_gate => TRUE
                    );
                ELSE
                    CALL application_data.manage_target(
                        p_date_min => v_date_min,
                        p_date_max => v_date_max,
                        p_plant_id => v_plant_rec.plant_id,
                        p_line_id => p_line_id,
                        p_user_id => p_user_id,
                        p_user_fullname => p_user_fullname,
                        p_bypass_gate => TRUE
                    );
                END IF;
            ELSE
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Skipped manage_target for line_id=' || COALESCE(p_line_id::TEXT, 'NULL') ||
                    ' (line not found/deleted or line_code=''(U)'')',
                    lp_last_user
                );
            END IF;
        END IF;
    END LOOP;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Completed (all selected plants).',
        lp_last_user
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE=' || SQLSTATE || ', step=' || lp_step::TEXT;
    CALL application_data.log_error_write(
        lp_procedure_name,
        lp_err_msg,
        lp_last_user
    );
    RAISE;
END;
$procedure$
;


-- DROP FUNCTION application_data.setup_new_plant_partitions(int8, int8, varchar);

CREATE OR REPLACE FUNCTION application_data.setup_new_plant_partitions(p_plant_id bigint, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    -- Variable for function name in logs
    lp_function_name text := 'application_data.setup_new_plant_partitions';
    lp_operation_caller text;
    
    -- 🧠 ROOT TABLE DISCOVERY CURSOR
    -- Finds all ROOT tables (partitioned by LIST) in the schema.
    -- This works even in a "virgin" environment because Root tables exist from DDL.
    target_tables_cursor CURSOR FOR
        SELECT 
            c.relname::TEXT AS table_name
        FROM pg_partitioned_table pt
        JOIN pg_class c ON pt.partrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'application_data'
          AND c.relname LIKE 'ft_%'
          AND pt.partstrat = 'l'; -- Look for LIST partitioned tables (The Roots)

    table_rec RECORD;
    v_range_column TEXT; -- Column detected dynamically
    
    plant RECORD;
    local_now TIMESTAMPTZ; 
    current_year INT;
    current_month INT;
    next_year INT;
    next_month INT;
    msg TEXT;
BEGIN
    -- Build Caller Info
    -- TEXT SAFETY: explicit cast to avoid operator does not exist errors
    lp_operation_caller := COALESCE(p_user_id::TEXT, 'Unknown') || ' -- ' || COALESCE(p_user_fullname, 'System/Unknown');

    -- Get plant timezone
    SELECT plant_id, plant_timezone INTO plant
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id;

    IF plant.plant_timezone IS NULL THEN
        RAISE EXCEPTION 'Timezone not found for plant_id %', p_plant_id::TEXT;
    END IF;

    -- Compute local date based on Plant Timezone
    local_now := now() AT TIME ZONE plant.plant_timezone;
    current_year := EXTRACT(YEAR FROM local_now);
    current_month := EXTRACT(MONTH FROM local_now);

    -- Calculate Next Month for future partition
    IF current_month = 12 THEN
        next_year := current_year + 1;
        next_month := 1;
    ELSE
        next_year := current_year;
        next_month := current_month + 1;
    END IF;

    -------------------------------------------------------
    -- 🔄 METADATA LOOP
    -- Iterates over all ft_% tables found in the database schema
    -------------------------------------------------------
    FOR table_rec IN target_tables_cursor LOOP
        
        -- 🕵️ DETECT RANGE COLUMN STRATEGY
        -- We check which column the Root table has: 'target_date_iso' or 'day_id'
        -- This allows us to handle different table structures dynamically.
        SELECT column_name INTO v_range_column
        FROM information_schema.columns 
        WHERE table_schema = 'application_data'
          AND table_name = table_rec.table_name
          AND column_name IN ('target_date_iso', 'day_id')
        ORDER BY 
            CASE column_name 
                WHEN 'target_date_iso' THEN 1  -- Priority 1
                WHEN 'day_id' THEN 2           -- Priority 2
            END
        LIMIT 1;

        -- If no suitable column is found, skip this table and log error
        IF v_range_column IS NULL THEN
            INSERT INTO application_data.log_error (
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', CURRENT_TIMESTAMP),
                lp_function_name,
                'Skipping setup for table ' || table_rec.table_name || ': No suitable range column (day_id/target_date_iso) found.',
                lp_operation_caller
            );
            CONTINUE;
        END IF;

        -- ---------------------------------------------------------
        -- Step 1: Create LIST partition (Level 1: Plant Partition)
        -- ---------------------------------------------------------
        BEGIN
            PERFORM application_data.create_plant_partition(
                table_rec.table_name, 
                v_range_column, 
                p_plant_id::bigint
            );
            
            -- TEXT SAFETY: p_plant_id cast to TEXT
            msg := format(
                'Created LIST partition for table "%s", plant_id %s, column "%s"',
                table_rec.table_name, p_plant_id::TEXT, v_range_column
            );
            
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_function_name,
                msg,
                lp_operation_caller
            );
            
            RAISE NOTICE '%', msg;

        EXCEPTION
            -- Ignore if already exists (SQLSTATE 42P07)
            WHEN SQLSTATE '42P07' THEN
                NULL;
            
            -- Log real errors
            WHEN OTHERS THEN
                msg := SQLERRM;
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_function_name,
                    'Error creating LIST partition for ' || table_rec.table_name || ': ' || msg,
                    lp_operation_caller
                );
        END;

        -- ---------------------------------------------------------
        -- Step 2: Create CURRENT month RANGE partition (Level 2)
        -- ---------------------------------------------------------
        BEGIN
            PERFORM application_data.create_monthly_partition(
                table_rec.table_name,
                v_range_column,
                p_plant_id::bigint,
                current_year,
                current_month
            );
            
            -- TEXT SAFETY: p_plant_id and current_year cast to TEXT
            msg := format('Created monthly partition for %s, plant %s, month %s-%s',
                          table_rec.table_name, 
                          p_plant_id::TEXT, 
                          current_year::TEXT, 
                          lpad(current_month::text, 2, '0'));

            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_function_name,
                msg,
                lp_operation_caller
            );
            
            RAISE NOTICE '%', msg;

        EXCEPTION
            WHEN SQLSTATE '42P07' THEN
                NULL;

            WHEN OTHERS THEN
                msg := SQLERRM;
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_function_name,
                    'Error creating Current Month partition for ' || table_rec.table_name || ': ' || msg,
                    lp_operation_caller
                );
        END;

        -- ---------------------------------------------------------
        -- Step 3: Create NEXT month RANGE partition (Level 2)
        -- ---------------------------------------------------------
        BEGIN
            PERFORM application_data.create_monthly_partition(
                table_rec.table_name,
                v_range_column,
                p_plant_id::bigint,
                next_year,
                next_month
            );
            
            -- TEXT SAFETY: p_plant_id and next_year cast to TEXT
            msg := format('Created monthly partition for %s, plant %s, month %s-%s',
                          table_rec.table_name, 
                          p_plant_id::TEXT, 
                          next_year::TEXT, 
                          lpad(next_month::text, 2, '0'));

            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_function_name,
                msg,
                lp_operation_caller
            );

            RAISE NOTICE '%', msg;

        EXCEPTION
            WHEN SQLSTATE '42P07' THEN
                NULL;

            WHEN OTHERS THEN
                msg := SQLERRM;
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_function_name,
                    'Error creating Next Month partition for ' || table_rec.table_name || ': ' || msg,
                    lp_operation_caller
                );
        END;

    END LOOP;
END;
$function$
;


-- DROP FUNCTION application_data.get_ft_meeting_pivot(int8);

CREATE OR REPLACE FUNCTION application_data.get_ft_meeting_pivot(p_meeting_id bigint)
 RETURNS TABLE(key text, value text)
 LANGUAGE sql
AS $function$
    SELECT 'plant_id', t.plant_id::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'tier_id', t.tier_id::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'line_id', t.line_id::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'module_id', t.module_id::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'day_id', t.day_id::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'creation_ts', t.creation_ts::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'creator_user', t.creator_user FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'last_modified', COALESCE(t.last_modified::text, '') FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'last_user', t.last_user FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'count_attendance', t.count_attendance::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'original_meeting', COALESCE(t.original_meeting, '') FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'meeting_format', COALESCE(t.meeting_format, '') FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'note_id', COALESCE(t.note_id, '') FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'meeting_title', COALESCE(t.meeting_title, '') FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t
    UNION ALL SELECT 'id', t.id::text FROM (SELECT * FROM application_data.ft_meeting WHERE id = p_meeting_id) t;
$function$;


-- DROP FUNCTION application_data.update_ft_kpi_target(varchar, int8, varchar, varchar);

CREATE OR REPLACE FUNCTION application_data.update_ft_kpi_target(p_file_id character varying, p_user_id bigint, p_user_fullname character varying, p_source_label character varying DEFAULT 'KPI_TARGET_UPDATER'::character varying)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    rec RECORD;
	v_num_of_record_file int8;
    v_successful_records int := 0;
    lp_step NUMERIC;
    lp_err_msg VARCHAR(2000);
    lp_procedure_name VARCHAR(100) := 'application_data.update_ft_kpi_target';
    v_day_id numeric(8);
    v_plant_id bigint;
	v_line_id BIGINT;
    v_module_id BIGINT;
	v_kpi_id BIGINT;
	v_tier_id BIGINT;
    v_year INT;
    v_month INT;
    v_partition_name TEXT;
    v_partition_exists BOOLEAN;
	lp_last_user varchar;

BEGIN
    lp_step := 0;
	SELECT COUNT(*) from application_staging.ft_kpi_target into v_num_of_record_file
	where file_id=p_file_id 
	AND is_processed = 0 AND has_unhandled_error = false;

    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'ERROR: User ID and Fullname cannot be NULL';
    END IF;

	lp_last_user := p_user_id::text || ' -- ' || p_user_fullname;

	lp_step := 1;

    FOR rec IN
        SELECT 
            kt.import_id, kt.kpi, kt.plant, kt.line, 
			kt.tier, kt.day AS target_date_iso,
            kt.value, kt.target
        FROM application_staging.ft_kpi_target kt
        WHERE kt.file_id = p_file_id
        AND kt.is_processed = 0 AND has_unhandled_error = false

    LOOP
        BEGIN
            lp_step := 2;
            v_day_id := rec.target_date_iso;
            v_year := (v_day_id / 10000)::int;
            v_month := ((v_day_id % 10000) / 100)::int;

			  -- 🔎 MAPPATURA
            BEGIN
                -- 🔹 Plant
                SELECT plant_id INTO v_plant_id
                FROM application_data.lk_plant
                WHERE plant_code = rec.plant;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Plant code "%" not found', rec.plant;
                END IF;

                -- 🔹 Line + Module
                SELECT line_id, module_id INTO v_line_id, v_module_id
                FROM application_data.lk_line
                WHERE plant_id = v_plant_id AND line_code = rec.line;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Line code "%" not found for plant_id=%', rec.line, v_plant_id;
                END IF;

                -- 🔹 KPI
                SELECT kpi_id INTO v_kpi_id
                FROM application_data.lk_kpi
                WHERE plant_id = v_plant_id AND kpi_code = rec.kpi;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ KPI "%" not found for plant_id=%', rec.kpi, v_plant_id;
                END IF;

                -- 🔹 Tier
                SELECT tier_id INTO v_tier_id
                FROM application_data.lk_tier
                WHERE  plant_id = v_plant_id and tier_code=rec.tier;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Tier "%" not found for plant_id=%', rec.tier,v_plant_id;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                -- ⛔ ERRORE DI MAPPATURA
                lp_err_msg := format('❌ Mapping error (import_id=%s): %s', rec.import_id, SQLERRM);

                UPDATE application_staging.ft_kpi_target
                SET is_processed = 1, is_rejected = 1, has_unhandled_error = FALSE, note = lp_err_msg
                WHERE import_id = rec.import_id;

                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', CURRENT_TIMESTAMP),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );

                CONTINUE; -- passa al prossimo record
            END;
			
    	   v_partition_name := format('ft_kpi_target_plant_%s_%s%02s', v_plant_id, v_year, v_month);

            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'application_data'
                  AND table_name = v_partition_name
            ) INTO v_partition_exists;

            IF NOT v_partition_exists THEN
                BEGIN
                    PERFORM application_data.create_monthly_partition(
                        'ft_kpi_target', 'target_date_iso', v_plant_id, v_year, v_month
                    );

                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                       '✔️ Partition created: ' || v_partition_name,
                        lp_last_user
                    );
                EXCEPTION WHEN OTHERS THEN
                     lp_err_msg :=  '⚠️ Partition creation failed: '|| v_partition_name || ' — ' || SQLERRM;
                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        lp_err_msg,
                        lp_last_user
                    );
                END;
            ELSE
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'ℹ️ Partition already exists: ' || v_partition_name,
                    lp_last_user
                );
            END IF;

            UPDATE application_data.ft_kpi_target tgt
            SET 
                kpi_value = rec.value,
                target_value_num = rec.target,
				import_id=rec.import_id,
				last_user=lp_last_user,
				last_modified = timezone('UTC', current_timestamp)
            FROM (
                SELECT 
                    p.plant_id,
                    kpi.kpi_id,
                    l.line_id,
                    t.tier_id
                FROM application_data.lk_plant p
                JOIN application_data.lk_kpi kpi 
                    ON p.plant_id = kpi.plant_id AND kpi.kpi_code = rec.kpi
                JOIN application_data.lk_line l 
                    ON l.plant_id = p.plant_id AND l.line_code = rec.line
                JOIN application_data.lk_tier t 
                    ON t.plant_id = p.plant_id AND t.tier_code = rec.tier
                WHERE p.plant_code = rec.plant
            ) map
            WHERE tgt.plant_id = map.plant_id
              AND tgt.kpi_id = map.kpi_id
              AND tgt.line_id = map.line_id
              AND tgt.tier_id = map.tier_id
              AND tgt.target_date_iso = rec.target_date_iso;

            IF FOUND THEN
				BEGIN
				    UPDATE application_staging.ft_kpi_target
		            SET is_processed = 1 , is_rejected = 0, note = '✔️ Successfully inserted'
		            WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
		            AND tier = rec.tier AND day = rec.target_date_iso AND file_id = p_file_id AND import_id= rec.import_id;
	
	                INSERT INTO application_data.log_operation (
	                    operation_timestamp, operation_src, operation_msg, operation_caller
	                ) VALUES (
	                    timezone('UTC', current_timestamp),
	                    lp_procedure_name,
	                    '✔️ UPDATED: [kpi: ' || rec.kpi || ', plant: ' || rec.plant || 
	                    ', line: ' || rec.line || ', tier: ' || rec.tier || 
	                    ', day: ' || rec.target_date_iso || ', value: ' || rec.value || 
	                    ', target: ' || rec.target || ']',
	                    lp_last_user);
			
					v_successful_records := v_successful_records + 1;
				END;
            ELSE
                UPDATE application_staging.ft_kpi_target
                SET is_rejected = 1,
                    is_processed = 1,
                    note = '❗NO MATCH FOUND: [kpi: ' || rec.kpi || ', plant: ' || rec.plant || ', line: ' || rec.line || ', tier: ' || rec.tier || ', day: ' || rec.target_date_iso || '] — no update applied.'
                WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
                  AND tier = rec.tier AND day = rec.target_date_iso AND file_id = p_file_id AND import_id= rec.import_id;

                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '❗NO MATCH FOUND: [kpi: ' || rec.kpi || ', plant: ' || rec.plant || 
                    ', line: ' || rec.line || ', tier: ' || rec.tier || 
                    ', day: ' || rec.target_date_iso || '] — no update applied.',
                    lp_last_user
                );
            END IF;

    

        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'ERROR INSIDE LOOP: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', Step: ' || lp_step::TEXT || 
                          ', Record: [kpi: ' || rec.kpi || ', plant: ' || rec.plant || 
                          ', line: ' || rec.line || ', tier: ' || rec.tier || 
                          ', day: ' || rec.target_date_iso || ']';
            INSERT INTO application_data.log_error (
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                lp_err_msg,
                lp_last_user
            );
        END;
    END LOOP;

    lp_step := 4;
 
        -- 📌 Conclusione su file
    IF v_successful_records = v_num_of_record_file THEN
        UPDATE application_data.lk_files
        SET is_processed = TRUE,
            processed_timestamp = timezone('UTC', CURRENT_TIMESTAMP),
            note = format('✅ Completed. File: %s, Total: %s, OK: %s', p_file_id, v_num_of_record_file, v_successful_records)
        WHERE id::text = p_file_id;

        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            format('✅ Completed. File: %s, Total: %s, OK: %s', p_file_id, v_num_of_record_file, v_successful_records),
            lp_last_user
        );
    ELSE
        UPDATE application_data.lk_files
        SET is_processed = TRUE,
            processed_timestamp = timezone('UTC', CURRENT_TIMESTAMP),
            note = format('⚠️ File %s partially processed. OK: %s, Expected: %s', p_file_id, v_successful_records, v_num_of_record_file)
        WHERE id::text = p_file_id;

        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            format('⚠️ File %s partially processed. OK: %s, Expected: %s', p_file_id, v_successful_records, v_num_of_record_file),
            lp_last_user
        );
    END IF;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'GENERAL ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_err_msg,
        lp_last_user
    );
    RAISE;
END;
$function$
;


-- DROP PROCEDURE application_data.manage_assoc_module_line_tier_kpi(varchar, int8, int8, int8, int8, int8, int8, bool, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_assoc_module_line_tier_kpi(IN operation_type character varying, IN p_amltk_id bigint DEFAULT NULL::bigint, IN p_kpi_id bigint DEFAULT NULL::bigint, IN p_tier_id bigint DEFAULT NULL::bigint, IN p_line_id bigint DEFAULT NULL::bigint, IN p_module_id bigint DEFAULT NULL::bigint, IN p_plant_id bigint DEFAULT NULL::bigint, IN p_is_active boolean DEFAULT NULL::boolean, IN p_user_id bigint DEFAULT NULL::bigint, IN p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_assoc_module_line_tier_kpi';
    lp_err_msg TEXT;
BEGIN
    lp_step := 0;

    -- 🪵 Log input dettagliato
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [' ||
        'operation_type=' || COALESCE(operation_type, 'NULL') || ', ' ||
        'p_amltk_id=' || COALESCE(p_amltk_id::TEXT, 'NULL') || ', ' ||
        'p_kpi_id=' || COALESCE(p_kpi_id::TEXT, 'NULL') || ', ' ||
        'p_tier_id=' || COALESCE(p_tier_id::TEXT, 'NULL') || ', ' ||
        'p_line_id=' || COALESCE(p_line_id::TEXT, 'NULL') || ', ' ||
        'p_module_id=' || COALESCE(p_module_id::TEXT, 'NULL') || ', ' ||
        'p_plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
        'p_is_active=' || COALESCE(p_is_active::TEXT, 'NULL') || ', ' ||
        'p_user_id=' || COALESCE(p_user_id::TEXT, 'NULL') || ', ' ||
        'p_user_fullname=''' || COALESCE(p_user_fullname, 'NULL') || '''' ||
        ']',
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );

    -- 🔍 Validazione utente
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'ERROR: User ID and Fullname cannot be NULL.';
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- ⚙️ Switch operazioni
    CASE operation_type
        WHEN 'I' THEN
            lp_step := 1;
            IF p_kpi_id IS NULL OR p_tier_id IS NULL OR p_line_id IS NULL OR p_module_id IS NULL OR p_plant_id IS NULL THEN
                RAISE EXCEPTION 'ERROR: Required fields for INSERT are missing';
            END IF;

            INSERT INTO application_data.ass_module_line_tier_kpi (
                kpi_id, tier_id, line_id, module_id, plant_id, is_active,
                creation_ts, creator_user, last_user, last_modified
            ) VALUES (
                p_kpi_id, p_tier_id, p_line_id, p_module_id, p_plant_id, COALESCE(p_is_active, true),
                timezone('UTC', current_timestamp), lp_last_user, lp_last_user, timezone('UTC', current_timestamp)
            );

            -- ✅ Chiamata a setup_kpi_into_ft_kpi_target con rollback se fallisce
            BEGIN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Calling setup_kpi_into_ft_kpi_target with [user_id=' || p_user_id || ', user_fullname=''' || p_user_fullname || ''']',
                    lp_last_user
                );

                CALL application_data.setup_kpi_into_ft_kpi_target(p_user_id, p_user_fullname, p_kpi_id, p_tier_id, p_line_id, p_module_id, p_plant_id);

                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '✔️ setup_kpi_into_ft_kpi_target completed',
                    lp_last_user
                );

            EXCEPTION WHEN OTHERS THEN
                lp_err_msg := '❌ setup_kpi_into_ft_kpi_target failed: ' || SQLERRM || ' | SQLSTATE: ' || SQLSTATE;
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );
                RAISE EXCEPTION '%', lp_err_msg;
            END;

        WHEN 'U' THEN
            lp_step := 2;
            UPDATE application_data.ass_module_line_tier_kpi
            SET
                kpi_id = COALESCE(p_kpi_id, kpi_id),
                tier_id = COALESCE(p_tier_id, tier_id),
                line_id = COALESCE(p_line_id, line_id),
                module_id = COALESCE(p_module_id, module_id),
                plant_id = COALESCE(p_plant_id, plant_id),
                is_active = COALESCE(p_is_active, is_active),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE amltk_id = p_amltk_id;
			
			IF p_is_active='true' then 
  			  BEGIN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Calling setup_kpi_into_ft_kpi_target with [user_id=' || p_user_id || ', user_fullname=''' || p_user_fullname || ''']',
                    lp_last_user
                );

                CALL application_data.setup_kpi_into_ft_kpi_target(p_user_id, p_user_fullname, p_kpi_id, p_tier_id, p_line_id, p_module_id, p_plant_id);

                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '✔️ setup_kpi_into_ft_kpi_target completed',
                    lp_last_user
                );

            EXCEPTION WHEN OTHERS THEN
                lp_err_msg := '❌ setup_kpi_into_ft_kpi_target failed: ' || SQLERRM || ' | SQLSTATE: ' || SQLSTATE;
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );
                RAISE EXCEPTION '%', lp_err_msg;
            END;
			END IF;
			
        WHEN 'LD' THEN
            lp_step := 3;
            UPDATE application_data.ass_module_line_tier_kpi
            SET
                is_active = FALSE,
                is_deleted = TRUE,
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp)
            WHERE amltk_id = p_amltk_id;

        WHEN 'D' THEN
            lp_step := 4;
            DELETE FROM application_data.ass_module_line_tier_kpi
            WHERE amltk_id = p_amltk_id;

        ELSE
            RAISE EXCEPTION 'ERROR: Invalid operation_type';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', lp_step=' || lp_step::TEXT;
        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            COALESCE(lp_last_user, 'UNKNOWN')
        );
        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.setup_kpi_into_ft_kpi_target(int8, varchar, int8, int8, int8, int8, int8);

CREATE OR REPLACE PROCEDURE application_data.setup_kpi_into_ft_kpi_target(p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying, p_kpi_id bigint DEFAULT NULL::bigint, p_tier_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_module_id bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    kpi_rec               RECORD;
    lp_target_date        DATE;
    lp_target_day_iso     INT;
    lp_last_user          TEXT;
    lp_procedure_name     TEXT := 'application_data.setup_kpi_into_ft_kpi_target';
    lp_err_msg            TEXT;
    lp_partition_name     TEXT;
    lp_partition_exists   BOOLEAN;
    lp_year               INT;
    lp_month              INT;
    lp_existing_record    BOOLEAN;
    lp_step               NUMERIC := 0;
    lp_current_ts         TIMESTAMP;
    lp_start_date         DATE;
    lp_end_date           DATE;
    lp_number_of_iterations INT := 0;
    lp_day_id             INT;
    lp_exec_safety_kpi    BOOLEAN := FALSE;
BEGIN
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID and Fullname cannot be NULL';
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', CURRENT_TIMESTAMP),
        lp_procedure_name,
        'Input: [user_id=' || COALESCE(p_user_id::TEXT, 'NULL') ||
        ', fullname=' || COALESCE(p_user_fullname, 'NULL') ||
        ', kpi_id=' || COALESCE(p_kpi_id::TEXT, 'NULL') ||
        ', tier_id=' || COALESCE(p_tier_id::TEXT, 'NULL') ||
        ', line_id=' || COALESCE(p_line_id::TEXT, 'NULL') ||
        ', module_id=' || COALESCE(p_module_id::TEXT, 'NULL') ||
        ', plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') || ']',
        lp_last_user
    );

    FOR kpi_rec IN
        SELECT
            kpi.kpi_id,
            kpi.tier_id,
            kpi.line_id,
            kpi.module_id,
            kpi.plant_id,
            freq.frequency_id,
            freq.frequency_ds,
            lk_kpi.kpi_category_id,
            lk_kpi.target_tendency_id,
            lk_kpi.kpi_code,
            lk_plant.plant_timezone
        FROM application_data.ass_module_line_tier_kpi kpi
        JOIN application_data.lk_tier tier ON kpi.tier_id = tier.tier_id AND kpi.plant_id = tier.plant_id
        JOIN application_data.lk_frequency freq ON tier.frequency_id = freq.frequency_id
        JOIN application_data.lk_kpi lk_kpi ON lk_kpi.kpi_id = kpi.kpi_id AND lk_kpi.plant_id = kpi.plant_id
        JOIN application_data.lk_plant lk_plant ON lk_plant.plant_id = kpi.plant_id AND lk_plant.is_active
        WHERE kpi.is_active = TRUE
          AND kpi.is_deleted = FALSE
          AND kpi.kpi_id = p_kpi_id
          AND kpi.tier_id = p_tier_id
          AND kpi.line_id = p_line_id
          AND kpi.module_id = p_module_id
          AND kpi.plant_id = p_plant_id
    LOOP
        lp_current_ts := current_timestamp AT TIME ZONE kpi_rec.plant_timezone;
        lp_start_date := DATE_TRUNC('year', lp_current_ts);
       -- lp_end_date := lp_current_ts::DATE;
        lp_end_date := (date_trunc('month', lp_current_ts AT TIME zone kpi_rec.plant_timezone) + interval '1 month - 1 day')::date;
        lp_target_date := lp_start_date;

        IF kpi_rec.kpi_code = 'safety events' THEN
            lp_exec_safety_kpi := TRUE;
        END IF;

        LOOP
            EXIT WHEN lp_target_date > lp_end_date;

            CASE kpi_rec.frequency_ds
                WHEN '<#Daily/>' THEN lp_target_date := lp_target_date;
                WHEN '<#Weekly/>' THEN lp_target_date := DATE_TRUNC('week', lp_target_date);
                WHEN '<#Biweekly/>' THEN lp_target_date := DATE_TRUNC('week', lp_target_date) + ((EXTRACT(WEEK FROM lp_target_date)::INT % 2) * INTERVAL '7 days');
                WHEN '<#Monthly/>' THEN lp_target_date := DATE_TRUNC('month', lp_target_date);
                WHEN '<#Quarterly/>' THEN lp_target_date := DATE_TRUNC('quarter', lp_target_date);
                WHEN '<#Annually/>' THEN lp_target_date := DATE_TRUNC('year', lp_target_date);
            END CASE;

            lp_target_day_iso := TO_CHAR(lp_target_date, 'YYYYMMDD')::INT;
            lp_year := EXTRACT(YEAR FROM lp_target_date)::INT;
            lp_month := EXTRACT(MONTH FROM lp_target_date)::INT;
            lp_partition_name := format('ft_kpi_target_plant_%s_%s%02s', kpi_rec.plant_id, lp_year, lp_month);

            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'application_data'
                  AND table_name = lp_partition_name
            ) INTO lp_partition_exists;

            IF NOT lp_partition_exists THEN
                BEGIN
                    PERFORM application_data.create_monthly_partition('ft_kpi_target', 'target_date_iso', kpi_rec.plant_id, lp_year, lp_month);
                EXCEPTION WHEN OTHERS THEN
                    INSERT INTO application_data.log_error (
                        error_timestamp, error_src, error_msg, error_caller
                    ) VALUES (
                        timezone('UTC', CURRENT_TIMESTAMP),
                        lp_procedure_name,
                        '❌ Partition creation failed for ' || lp_partition_name || ': ' || SQLERRM,
                        lp_last_user
                    );
                END;
            END IF;

            PERFORM 1 FROM application_data.ft_kpi_target
             WHERE kpi_id = kpi_rec.kpi_id AND tier_id = kpi_rec.tier_id
               AND line_id = kpi_rec.line_id AND module_id = kpi_rec.module_id
               AND plant_id = kpi_rec.plant_id AND kpi_category_id = kpi_rec.kpi_category_id
               AND target_date = lp_target_date;

            lp_existing_record := FOUND;

            IF NOT lp_existing_record THEN
                INSERT INTO application_data.ft_kpi_target (
                    target_id, kpi_id, tier_id, line_id, module_id, plant_id,
                    kpi_category_id, target_tendency_id, target_date, target_date_iso,target_value_num,kpi_value,
                    frequency_id, frequency_ds, is_visible, is_editable,
                    creation_ts, creator_user, last_modified, last_user
                ) VALUES (
                    nextval('application_data.ft_kpi_target_seq'),
                    kpi_rec.kpi_id, kpi_rec.tier_id, kpi_rec.line_id, kpi_rec.module_id, kpi_rec.plant_id,
                    kpi_rec.kpi_category_id, kpi_rec.target_tendency_id, lp_target_date, lp_target_day_iso,case when lp_exec_safety_kpi=TRUE THEN 0 ELSE NULL END,
					case when lp_exec_safety_kpi=TRUE THEN 0 ELSE NULL END,
                    kpi_rec.frequency_id, kpi_rec.frequency_ds, TRUE, TRUE,
                    timezone('UTC', CURRENT_TIMESTAMP), lp_last_user,
                    timezone('UTC', CURRENT_TIMESTAMP), lp_last_user
                );
            END IF;

            lp_target_date :=
                CASE kpi_rec.frequency_ds
                    WHEN '<#Daily/>' THEN lp_target_date + INTERVAL '1 day'
                    WHEN '<#Weekly/>' THEN lp_target_date + INTERVAL '7 days'
                    WHEN '<#Biweekly/>' THEN lp_target_date + INTERVAL '14 days'
                    WHEN '<#Monthly/>' THEN lp_target_date + INTERVAL '1 month'
                    WHEN '<#Quarterly/>' THEN lp_target_date + INTERVAL '3 months'
                    WHEN '<#Annually/>' THEN lp_target_date + INTERVAL '1 year'
                    ELSE lp_target_date + INTERVAL '1 day'
                END;

            lp_number_of_iterations := lp_number_of_iterations + 1;
        END LOOP;

        IF lp_exec_safety_kpi THEN
            FOR lp_day_id IN (
                SELECT DISTINCT day_id
                FROM application_data.ft_safety_cross
                WHERE plant_id = p_plant_id
                  AND line_id = p_line_id
                  AND module_id = p_module_id
            ) LOOP
                BEGIN
                    CALL application_data.update_ft_kpi_target_from_safety_cross_tiered(
                        p_plant_id, p_module_id, p_line_id, lp_day_id,
                        p_tier_id, p_kpi_id, kpi_rec.kpi_category_id, kpi_rec.target_tendency_id,
                        kpi_rec.frequency_id, kpi_rec.frequency_ds, kpi_rec.plant_timezone
                    );
                EXCEPTION WHEN OTHERS THEN
                    INSERT INTO application_data.log_error (
                        error_timestamp, error_src, error_msg, error_caller
                    ) VALUES (
                        timezone('UTC', CURRENT_TIMESTAMP),
                        lp_procedure_name,
                        '❌ Error populating KPI value from safety_cross for day_id=' || lp_day_id || ': ' || SQLERRM,
                        lp_last_user
                    );
                END;
            END LOOP;
        END IF;
    END LOOP;

    -- Sync target_value_num from lk_target to ft_kpi_target for the range just set up (lp_start_date .. lp_end_date from loop); best-effort, do not fail procedure on sync error
    BEGIN
        CALL application_data.sync_ft_kpi_target_from_lk_target(p_user_id, p_user_fullname, TO_CHAR(lp_start_date, 'YYYYMMDD')::numeric, TO_CHAR(lp_end_date, 'YYYYMMDD')::numeric);
    EXCEPTION WHEN OTHERS THEN
        lp_err_msg := 'sync_ft_kpi_target_from_lk_target failed: ' || SQLERRM;
        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        -- Do not re-raise: insertion completed; sync is best-effort
    END;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', CURRENT_TIMESTAMP),
        lp_procedure_name,
        '✅ Completed. Iterations: ' || lp_number_of_iterations,
        lp_last_user
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := '❌ ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', step=' || lp_step;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', CURRENT_TIMESTAMP), lp_procedure_name,
        lp_err_msg, lp_last_user
    );
    RAISE;
END;
$procedure$
;

-- DROP FUNCTION application_data.trigger_ft_kpi_target_from_safety_cross();

CREATE OR REPLACE FUNCTION application_data.trigger_ft_kpi_target_from_safety_cross()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    lp_function_name TEXT := 'application_data.trigger_ft_kpi_target_from_safety_cross';
    lp_err_msg TEXT;
    lp_log_message TEXT;
BEGIN
    -- Log iniziale
    lp_log_message := 'Input: [operation_type: ' || TG_OP ||
                      ', line_id: ' || COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.line_id::TEXT ELSE NEW.line_id::TEXT END, 'NULL') ||
                      ', module_id: ' || COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.module_id::TEXT ELSE NEW.module_id::TEXT END, 'NULL') ||
                      ', plant_id: ' || COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.plant_id::TEXT ELSE NEW.plant_id::TEXT END, 'NULL') ||
                      ', day_id: ' || COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.day_id::TEXT ELSE NEW.day_id::TEXT END, 'NULL') || ']';

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp), lp_function_name, lp_log_message, 'TRIGGER'
    );

    -- DELETE
    IF TG_OP = 'DELETE' THEN
        CALL application_data.update_ft_kpi_target_from_safety_cross(
            OLD.plant_id,
            OLD.module_id,
            OLD.line_id,
            OLD.day_id
        );
        RETURN NULL;

    -- INSERT
    ELSIF TG_OP = 'INSERT' THEN
        CALL application_data.update_ft_kpi_target_from_safety_cross(
            NEW.plant_id,
            NEW.module_id,
            NEW.line_id,
            NEW.day_id
        );
        RETURN NULL;

    -- UPDATE
    ELSIF TG_OP = 'UPDATE' THEN
        IF (OLD.line_id, OLD.module_id, OLD.plant_id, OLD.day_id) IS DISTINCT FROM
           (NEW.line_id, NEW.module_id, NEW.plant_id, NEW.day_id)
        THEN
            CALL application_data.update_ft_kpi_target_from_safety_cross(
                OLD.plant_id,
                OLD.module_id,
                OLD.line_id,
                OLD.day_id
            );
        END IF;

        CALL application_data.update_ft_kpi_target_from_safety_cross(
            NEW.plant_id,
            NEW.module_id,
            NEW.line_id,
            NEW.day_id
        );
        RETURN NULL;
    END IF;

    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', current_timestamp), lp_function_name, lp_err_msg, 'TRIGGER'
    );
    RETURN NULL;
END;
$function$
;


-- DROP PROCEDURE application_data.update_ft_kpi_target_from_safety_cross(int8, int8, int8, numeric);

CREATE OR REPLACE PROCEDURE application_data.update_ft_kpi_target_from_safety_cross(p_plant_id bigint, p_module_id bigint, p_line_id bigint, p_day_id numeric)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    rec RECORD;
    lp_procedure_name TEXT := 'application_data.update_ft_kpi_target_from_safety_cross';
    lp_err_msg TEXT;
    lp_log_message TEXT;
BEGIN
    -- Log iniziale
    lp_log_message := 'Input: [plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') ||
                      ', module_id: ' || COALESCE(p_module_id::TEXT, 'NULL') ||
                      ', line_id: ' || COALESCE(p_line_id::TEXT, 'NULL') ||
                      ', day_id: ' || COALESCE(p_day_id::TEXT, 'NULL') || ']';

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp), lp_procedure_name, lp_log_message, 'TRIGGER'
    );

    -- Itera sui tier associati
    FOR rec IN
        SELECT 
            kpi.kpi_id,
            assoc.tier_id,
            tier.frequency_id,
            freq.frequency_ds,
            kpi.kpi_category_id,
            kpi.target_tendency_id,
            plant.plant_timezone
        FROM application_data.lk_kpi kpi
        INNER JOIN application_data.ass_module_line_tier_kpi assoc
            ON assoc.kpi_id = kpi.kpi_id
            AND assoc.plant_id = p_plant_id
            AND assoc.line_id = p_line_id
            AND assoc.module_id = p_module_id
            AND assoc.is_active = true
            AND assoc.is_deleted = false
        INNER JOIN application_data.lk_kpi_type kt
            ON kt.kpi_type_id = kpi.kpi_type_id AND kt.kpi_type_code = 'DONUT'
        INNER JOIN application_data.lk_kpi_category kc
            ON kc.kpi_category_id = kpi.kpi_category_id AND kc.kpi_category_code = 'SAFETY'
        INNER JOIN application_data.lk_tier tier
            ON tier.tier_id = assoc.tier_id AND tier.plant_id = assoc.plant_id
        INNER JOIN application_data.lk_frequency freq
            ON freq.frequency_id = tier.frequency_id
        INNER JOIN application_data.lk_plant plant
            ON plant.plant_id = kpi.plant_id
        WHERE kpi.kpi_code = 'safety events'
    LOOP
        CALL application_data.update_ft_kpi_target_from_safety_cross_tiered(
            p_plant_id,
            p_module_id,
            p_line_id,
            p_day_id,
            rec.tier_id,
            rec.kpi_id,
            rec.kpi_category_id,
            rec.target_tendency_id,
            rec.frequency_id,
            rec.frequency_ds,
            rec.plant_timezone
        );

        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Processed: tier_id=' || rec.tier_id || ', kpi_id=' || rec.kpi_id,
            'TRIGGER'
        );
    END LOOP;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', current_timestamp), lp_procedure_name, lp_err_msg, 'TRIGGER'
    );
END;
$procedure$
;


-- DROP PROCEDURE application_data.update_ft_kpi_target_from_safety_cross_tiered(int8, int8, int8, numeric, int8, int8, int8, int8, int8, varchar, varchar);

CREATE OR REPLACE PROCEDURE application_data.update_ft_kpi_target_from_safety_cross_tiered(p_plant_id bigint, p_module_id bigint, p_line_id bigint, p_day_id numeric, p_tier_id bigint, p_kpi_id bigint, p_kpi_category_id bigint, p_target_tendency_id bigint, p_frequency_id bigint, p_frequency_ds character varying, p_timezone character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_target_date        DATE;
    lp_target_day_iso     NUMERIC(8);
    lp_kpi_value          NUMERIC;
    lp_partition_name     TEXT;
    lp_year               INT;
    lp_month              INT;
    lp_partition_exists   BOOLEAN;
    lp_procedure_name     TEXT := 'application_data.update_ft_kpi_target_from_safety_cross_tiered';
    lp_err_msg            TEXT;
    lp_log_message        TEXT;
BEGIN
    -- 🪵 Log input parameters
    lp_log_message := 'Input: [' ||
        'plant_id=' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
        'module_id=' || COALESCE(p_module_id::TEXT, 'NULL') || ', ' ||
        'line_id=' || COALESCE(p_line_id::TEXT, 'NULL') || ', ' ||
        'day_id=' || COALESCE(p_day_id::TEXT, 'NULL') || ', ' ||
        'tier_id=' || COALESCE(p_tier_id::TEXT, 'NULL') || ', ' ||
        'kpi_id=' || COALESCE(p_kpi_id::TEXT, 'NULL') || ', ' ||
        'kpi_category_id=' || COALESCE(p_kpi_category_id::TEXT, 'NULL') || ', ' ||
        'target_tendency_id=' || COALESCE(p_target_tendency_id::TEXT, 'NULL') || ', ' ||
        'frequency_id=' || COALESCE(p_frequency_id::TEXT, 'NULL') || ', ' ||
        'frequency_ds=''' || COALESCE(p_frequency_ds, 'NULL') || ''', ' ||
        'timezone=''' || COALESCE(p_timezone, 'NULL') || '''' ||
    ']';

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_log_message,
        'Backend'
    );

   -- 📅 Determine target date range
    CASE p_frequency_ds
        WHEN '<#Daily/>' THEN
            lp_target_date := TO_DATE(p_day_id::TEXT, 'YYYYMMDD')::date; 
        WHEN '<#Weekly/>' THEN
            lp_target_date := DATE_TRUNC('week', TO_DATE(p_day_id::TEXT, 'YYYYMMDD'))::date;
        WHEN '<#Biweekly/>' THEN
            lp_target_date := DATE_TRUNC('week', TO_DATE(p_day_id::TEXT, 'YYYYMMDD')::date )
                            + ((EXTRACT(WEEK FROM TO_DATE(p_day_id::TEXT, 'YYYYMMDD')::date)::INT % 2) * INTERVAL '7 days');
        WHEN '<#Monthly/>' THEN
            lp_target_date := DATE_TRUNC('month', TO_DATE(p_day_id::TEXT, 'YYYYMMDD'))::date;
        WHEN '<#Quarterly/>' THEN
            lp_target_date := DATE_TRUNC('quarter', TO_DATE(p_day_id::TEXT, 'YYYYMMDD'))::date;
        WHEN '<#Annually/>' THEN
            lp_target_date := DATE_TRUNC('year', TO_DATE(p_day_id::TEXT, 'YYYYMMDD'))::date;
        ELSE
            lp_target_date := TO_DATE(p_day_id::TEXT, 'YYYYMMDD')::date;
    END CASE;

    lp_target_day_iso := TO_CHAR(lp_target_date, 'YYYYMMDD')::NUMERIC(8);

    -- 🔢 Aggregate KPI value from ft_safety_cross
    SELECT COUNT(*)::NUMERIC
    INTO lp_kpi_value
    FROM application_data.ft_safety_cross
    WHERE plant_id = p_plant_id
      AND module_id = p_module_id
      AND line_id = p_line_id
      AND TO_DATE(day_id::TEXT, 'YYYYMMDD') >= lp_target_date
      AND TO_DATE(day_id::TEXT, 'YYYYMMDD') <
            lp_target_date + (
                CASE 
                    WHEN p_frequency_ds = '<#Weekly/>' THEN INTERVAL '1 week'
                    WHEN p_frequency_ds = '<#Biweekly/>' THEN INTERVAL '2 weeks'
                    WHEN p_frequency_ds = '<#Monthly/>' THEN INTERVAL '1 month'
                    WHEN p_frequency_ds = '<#Quarterly/>' THEN INTERVAL '3 months'
                    WHEN p_frequency_ds = '<#Annually/>' THEN INTERVAL '1 year'
                    ELSE INTERVAL '1 day'
                END
            );

    -- 📦 Partition preparation
    lp_year := EXTRACT(YEAR FROM lp_target_date)::INT;
    lp_month := EXTRACT(MONTH FROM lp_target_date)::INT;
    lp_partition_name := format('ft_kpi_target_plant_%s_%s%02s', p_plant_id, lp_year, lp_month);

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'application_data'
          AND table_name = lp_partition_name
    )
    INTO lp_partition_exists;

    IF NOT lp_partition_exists THEN
        BEGIN
            PERFORM application_data.create_monthly_partition(
                'ft_kpi_target',
                'target_date_iso',
                p_plant_id,
                lp_year,
                lp_month
            );

            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'ℹ️ Partition created: ' || lp_partition_name,
                'Backend'
            );

        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := '⚠️ Partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
            INSERT INTO application_data.log_error (
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                lp_err_msg,
                'Backend'
            );
        END;
    ELSE
        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'ℹ️ Partition already exists: ' || lp_partition_name,
            'Backend'
        );
    END IF;

    -- 📈 UPSERT KPI result
    INSERT INTO application_data.ft_kpi_target (
        target_id,
        line_id, module_id, plant_id, tier_id,
        kpi_id, kpi_category_id, target_tendency_id,
        target_date_iso, target_date,
        frequency_id, frequency_ds,
        is_visible, is_editable, kpi_value
    )
    VALUES (
        nextval('application_data.ft_kpi_target_seq'),
        p_line_id, p_module_id, p_plant_id, p_tier_id,
        p_kpi_id, p_kpi_category_id, p_target_tendency_id,
        lp_target_day_iso, lp_target_date,
        p_frequency_id, p_frequency_ds,
        TRUE, TRUE, lp_kpi_value
    )
    ON CONFLICT (kpi_id, tier_id, line_id, module_id, plant_id, target_date_iso)
    DO UPDATE SET kpi_value = EXCLUDED.kpi_value;

    -- 🟢 Log success
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        '✔️ KPI upserted: kpi_id=' || p_kpi_id || ', tier_id=' || p_tier_id || ', value=' || lp_kpi_value,
        'Backend'
    );

EXCEPTION WHEN OTHERS THEN
    -- 🔴 Catch-all error handler
    lp_err_msg := '❌ ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_err_msg,
        'Backend'
    );
END;
$procedure$
;



-- DROP FUNCTION application_data.update_ft_safety_cross_from_staging(varchar, int8, varchar, varchar);

CREATE OR REPLACE FUNCTION application_data.update_ft_safety_cross_from_staging(p_file_id character varying, p_user_id bigint, p_user_fullname character varying, p_source_label character varying DEFAULT 'SAFETY_CROSS_UPLOADER'::character varying)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    rec RECORD;
    v_successful_records INT := 0;
    v_num_of_record_file INT := 0;
    lp_err_msg TEXT;
    lp_procedure_name TEXT := 'application_data.update_ft_safety_cross_from_staging';
    lp_last_user TEXT;
    v_day_id NUMERIC(8);
    v_year INT;
    v_month INT;
    v_partition_name TEXT;
    v_partition_exists BOOLEAN;

    v_plant_id BIGINT;
    v_line_id BIGINT;
    v_module_id BIGINT;
    v_safety_category_id BIGINT;
    v_safety_type_id BIGINT;
BEGIN
    -- 🔍 Controlli iniziali
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID and Fullname cannot be NULL';
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    -- 📊 Conteggio righe del file da processare
    SELECT COUNT(*) INTO v_num_of_record_file
    FROM application_staging.ft_safety_cross
    WHERE file_id = p_file_id AND is_processed = 0 AND has_unhandled_error = false;

    -- ♻️ Loop sui record da elaborare
    FOR rec IN
        SELECT * FROM application_staging.ft_safety_cross
        WHERE file_id = p_file_id AND is_processed = 0 AND has_unhandled_error = false
    LOOP
        BEGIN
            v_day_id := rec.day;
            v_year := (v_day_id / 10000)::INT;
            v_month := ((v_day_id % 10000) / 100)::INT;

            -- 🔎 MAPPATURA
            BEGIN
                -- 🔹 Plant
                SELECT plant_id INTO v_plant_id
                FROM application_data.lk_plant
                WHERE plant_code = rec.plant;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Plant code "%" not found', rec.plant;
                END IF;

                -- 🔹 Line + Module
                SELECT line_id, module_id INTO v_line_id, v_module_id
                FROM application_data.lk_line
                WHERE plant_id = v_plant_id AND line_code = rec.line;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Line code "%" not found for plant_id=%', rec.line, v_plant_id;
                END IF;

                -- 🔹 Safety Category
                SELECT safety_category_id INTO v_safety_category_id
                FROM application_data.lk_safety_category
                WHERE plant_id = v_plant_id AND safety_category_code = rec.safety_category;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Safety category "%" not found for plant_id=%', rec.safety_category, v_plant_id;
                END IF;

                -- 🔹 Safety Type
                SELECT safety_type_id INTO v_safety_type_id
                FROM application_data.lk_safety_type
                WHERE safety_type_code = rec.safety_type;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Safety type "%" not found', rec.safety_type;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                -- ⛔ ERRORE DI MAPPATURA
                lp_err_msg := format('❌ Mapping error (import_id=%s): %s', rec.import_id, SQLERRM);

                UPDATE application_staging.ft_safety_cross
                SET is_processed = 1, is_rejected = 1, has_unhandled_error = FALSE, note = lp_err_msg
                WHERE import_id = rec.import_id;

                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', CURRENT_TIMESTAMP),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );

                CONTINUE; -- passa al prossimo record
            END;

            -- 🧱 Verifica/creazione partizione
            v_partition_name := format('ft_safety_cross_plant_%s_%s%02s', v_plant_id, v_year, v_month);

            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'application_data' AND table_name = v_partition_name
            ) INTO v_partition_exists;

            IF NOT v_partition_exists THEN
                BEGIN
                    PERFORM application_data.create_monthly_partition(
                        'ft_safety_cross', 'day_id', v_plant_id, v_year, v_month
                    );

                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', CURRENT_TIMESTAMP),
                        lp_procedure_name,
                        '✔️ Partition created: ' || v_partition_name,
                        lp_last_user
                    );
                EXCEPTION WHEN OTHERS THEN
                    INSERT INTO application_data.log_error (
                        error_timestamp, error_src, error_msg, error_caller
                    ) VALUES (
                        timezone('UTC', CURRENT_TIMESTAMP),
                        lp_procedure_name,
                        '⚠️ Partition creation failed: ' || v_partition_name || ' — ' || SQLERRM,
                        lp_last_user
                    );
                END;
            END IF;

            -- ✅ Inserimento record
            INSERT INTO application_data.ft_safety_cross (
                plant_id, module_id, line_id, safety_category_id, safety_type_id,
                day_id, day_ts, comment_ds, num_day, day_lost,
                creation_ts, creator_user, last_modified, last_user, import_id
            ) VALUES (
                v_plant_id, v_module_id, v_line_id, v_safety_category_id, v_safety_type_id,
                v_day_id, rec.event_datetime, rec.comment, 0, rec.day_lost::INT,
                timezone('UTC', CURRENT_TIMESTAMP), lp_last_user,
                timezone('UTC', CURRENT_TIMESTAMP), lp_last_user, rec.import_id
            );

            UPDATE application_staging.ft_safety_cross
            SET is_processed = 1, is_rejected = 0, note = '✔️ Successfully inserted'
            WHERE import_id = rec.import_id;

            v_successful_records := v_successful_records + 1;
        END;
    END LOOP;

    -- 📌 Conclusione su file
    IF v_successful_records = v_num_of_record_file THEN
        UPDATE application_data.lk_files
        SET is_processed = TRUE,
            processed_timestamp = timezone('UTC', CURRENT_TIMESTAMP),
            note = format('✅ Completed. File: %s, Total: %s, OK: %s', p_file_id, v_num_of_record_file, v_successful_records)
        WHERE id::text = p_file_id;

        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            format('✅ Completed. File: %s, Total: %s, OK: %s', p_file_id, v_num_of_record_file, v_successful_records),
            lp_last_user
        );
    ELSE
        UPDATE application_data.lk_files
        SET is_processed = TRUE,
            processed_timestamp = timezone('UTC', CURRENT_TIMESTAMP),
            note = format('⚠️ File %s partially processed. OK: %s, Expected: %s', p_file_id, v_successful_records, v_num_of_record_file)
        WHERE id::text = p_file_id;

        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            format('⚠️ File %s partially processed. OK: %s, Expected: %s', p_file_id, v_successful_records, v_num_of_record_file),
            lp_last_user
        );
    END IF;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := '💥 General error: ' || SQLERRM || ', SQLSTATE=' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp, error_src, error_msg, error_caller
    ) VALUES (
        timezone('UTC', CURRENT_TIMESTAMP),
        lp_procedure_name,
        lp_err_msg,
        p_user_id::TEXT || ' -- ' || p_user_fullname
    );
    RAISE;
END;
$function$
;




-- DROP PROCEDURE application_data.manage_ft_pareto_data(varchar, int8, varchar, int8, int8, int8, int8, int8, int8, varchar, numeric, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_ft_pareto_data(operation_type character varying, p_pareto_data_id bigint DEFAULT NULL::bigint, p_item character varying DEFAULT NULL::character varying, p_kpi_id bigint DEFAULT NULL::bigint, p_tier_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_module_id bigint DEFAULT NULL::bigint, p_plant_id bigint DEFAULT NULL::bigint, p_kpi_category_id bigint DEFAULT NULL::bigint, p_day character varying DEFAULT NULL::character varying, p_value numeric DEFAULT NULL::numeric, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_step numeric;
    lp_procedure_name varchar := 'application_data.manage_ft_pareto_data';
    lp_err_msg varchar;
    lp_last_user varchar;
    lp_new_id bigint;
    lp_day_id numeric(8);
    lp_day timestamp;

    -- 🔧 Partizione
    lp_partition_name TEXT;
    lp_year INT;
    lp_month INT;
    lp_partition_exists BOOLEAN;
BEGIN
    lp_step := 0;

    -- 👤 Validazione utente
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID and Fullname cannot be null';
    END IF;

    lp_last_user := p_user_id::text || ' -- ' || p_user_fullname;

    -- 🗓️ Conversione data
    lp_step := 0.1;
    BEGIN
        lp_day := p_day::timestamp;
        lp_day_id := TO_CHAR(lp_day, 'YYYYMMDD')::numeric;
    EXCEPTION
        WHEN others THEN
            RAISE EXCEPTION 'Invalid format for p_day: %', p_day;
    END;

    -- 🪵 Log Input
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: operation_type=' || COALESCE(operation_type, 'NULL') ||
        ', pareto_data_id=' || COALESCE(p_pareto_data_id::text, 'NULL') ||
        ', item=' || COALESCE(p_item, 'NULL') ||
        ', kpi_id=' || COALESCE(p_kpi_id::text, 'NULL') ||
        ', tier_id=' || COALESCE(p_tier_id::text, 'NULL') ||
        ', line_id=' || COALESCE(p_line_id::text, 'NULL') ||
        ', module_id=' || COALESCE(p_module_id::text, 'NULL') ||
        ', plant_id=' || COALESCE(p_plant_id::text, 'NULL') ||
        ', kpi_category_id=' || COALESCE(p_kpi_category_id::text, 'NULL') ||
        ', p_day=' || COALESCE(p_day, 'NULL') ||
        ', value=' || COALESCE(p_value::text, 'NULL'),
        lp_last_user
    );

    -- 🔀 Operazioni
    CASE operation_type
        WHEN 'I' THEN
            lp_step := 1;

            IF p_item IS NULL OR p_kpi_id IS NULL OR p_plant_id IS NULL OR p_day IS NULL THEN
                RAISE EXCEPTION 'Missing required fields for INSERT';
            END IF;

            -- 📦 Partizionamento
            lp_year := EXTRACT(YEAR FROM lp_day)::INT;
            lp_month := EXTRACT(MONTH FROM lp_day)::INT;
            lp_partition_name := format('ft_pareto_data_plant_%s_%s%02s', p_plant_id, lp_year, lp_month);

            -- Verifica esistenza
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = 'application_data'
                  AND table_name = lp_partition_name
            )
            INTO lp_partition_exists;

            -- ⚒️ Crea partizione se non esiste
            IF NOT lp_partition_exists THEN
                BEGIN
                    PERFORM application_data.create_monthly_partition(
                        'ft_pareto_data',
                        'day_id',
                        p_plant_id,
                        lp_year,
                        lp_month
                    );

                    INSERT INTO application_data.log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'ℹ️ Partition created: ' || lp_partition_name,
                        lp_last_user
                    );

                EXCEPTION WHEN OTHERS THEN
                    lp_err_msg := '❌ Partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
                    INSERT INTO application_data.log_error (
                        error_timestamp, error_src, error_msg, error_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        lp_err_msg,
                        lp_last_user
                    );
                END;
            ELSE
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'ℹ️ Partition already exists: ' || lp_partition_name,
                    lp_last_user
                );
            END IF;

            -- INSERT record
            SELECT nextval('application_data.ft_pareto_data_seq') INTO lp_new_id;

            INSERT INTO application_data.ft_pareto_data (
                pareto_data_id,
                item, kpi_id, tier_id, line_id,
                module_id, plant_id, kpi_category_id,
                day_id, day, value, is_visible, is_editable,
                creation_ts, creator_user, last_modified, last_user
            ) VALUES (
                lp_new_id,
                p_item, p_kpi_id, p_tier_id, p_line_id,
                p_module_id, p_plant_id, p_kpi_category_id,
                lp_day_id, lp_day, p_value, TRUE, TRUE,
                timezone('UTC', current_timestamp), lp_last_user,
                timezone('UTC', current_timestamp), lp_last_user
            );

        WHEN 'U' THEN
            lp_step := 2;
            IF p_pareto_data_id IS NULL THEN
                RAISE EXCEPTION 'pareto_data_id is required for UPDATE';
            END IF;

            PERFORM 1 FROM application_data.ft_pareto_data
            WHERE pareto_data_id = p_pareto_data_id AND is_editable = false;

            IF FOUND THEN
                RAISE EXCEPTION 'Cannot update: record is not editable';
            END IF;

            UPDATE application_data.ft_pareto_data
            SET
                item = COALESCE(p_item, item),
                kpi_id = COALESCE(p_kpi_id, kpi_id),
                tier_id = COALESCE(p_tier_id, tier_id),
                line_id = COALESCE(p_line_id, line_id),
                module_id = COALESCE(p_module_id, module_id),
                plant_id = COALESCE(p_plant_id, plant_id),
                kpi_category_id = COALESCE(p_kpi_category_id, kpi_category_id),
                day_id = COALESCE(lp_day_id, day_id),
                day = COALESCE(lp_day, day),
                value = COALESCE(p_value, value),
                last_modified = timezone('UTC', current_timestamp),
                last_user = lp_last_user
            WHERE pareto_data_id = p_pareto_data_id;

        WHEN 'LD' THEN
            lp_step := 3;
            UPDATE application_data.ft_pareto_data
            SET is_visible = FALSE,
                is_editable = FALSE,
                last_modified = timezone('UTC', current_timestamp),
                last_user = lp_last_user
            WHERE pareto_data_id = p_pareto_data_id;

        WHEN 'D' THEN
            lp_step := 4;
            DELETE FROM application_data.ft_pareto_data
            WHERE pareto_data_id = p_pareto_data_id;

        ELSE
            RAISE EXCEPTION 'Invalid operation_type';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ' | SQLSTATE: ' || SQLSTATE || ' | step=' || lp_step;
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        RAISE;
END;
$procedure$
;


-- DROP FUNCTION application_data.update_ft_pareto_data(varchar, int8, varchar, varchar);

CREATE OR REPLACE FUNCTION application_data.update_ft_pareto_data(p_file_id character varying, p_user_id bigint, p_user_fullname character varying, p_source_label character varying DEFAULT 'PARETO_DATA_UPDATER'::character varying)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    rec RECORD;
    v_num_of_record_file int8;
    v_successful_records int := 0;
    lp_step NUMERIC;
    lp_err_msg VARCHAR(2000);
    lp_procedure_name VARCHAR(100) := 'application_data.update_ft_pareto_data';
    lp_last_user varchar;
    v_day_id numeric(8);
    lp_record_num int4;
  	v_check_count int;
    v_line_id BIGINT;
    v_module_id BIGINT;
	v_kpi_id BIGINT;
	v_tier_id  BIGINT;

    -- 🔧 Partizione
    v_plant_id bigint;
    v_year INT;
    v_month INT;
    v_partition_name TEXT;
    v_partition_exists BOOLEAN;

BEGIN
    lp_step := 0;

	SELECT COUNT(*) INTO v_num_of_record_file
    FROM application_staging.ft_pareto_data
    WHERE file_id = p_file_id AND is_processed = 0 AND has_unhandled_error = false;

    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'ERROR: User ID and Fullname cannot be NULL';
    END IF;

    lp_last_user := p_user_id::text || ' -- ' || p_user_fullname;

    lp_step := 1;

    FOR rec IN
        SELECT 
            pt.import_id, pt.kpi, pt.plant, pt.line, pt.tier, pt.item, pt.day, pt.value
        FROM application_staging.ft_pareto_data pt
        WHERE pt.file_id = p_file_id
          	AND pt.is_processed = 0 
			AND has_unhandled_error = false
    LOOP
        BEGIN
            lp_step := 2;
            v_day_id := rec.day;

            -- 🔍 Estrai anno/mese e plant_id per verifica partizione
            v_year := (v_day_id / 10000)::int;
            v_month := ((v_day_id % 10000) / 100)::int;

        -- 🔎 MAPPATURA
            BEGIN
                -- 🔹 Plant
                SELECT plant_id INTO v_plant_id
                FROM application_data.lk_plant
                WHERE plant_code = rec.plant;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Plant code "%" not found', rec.plant;
                END IF;

                -- 🔹 Line + Module
                SELECT line_id, module_id INTO v_line_id, v_module_id
                FROM application_data.lk_line
                WHERE plant_id = v_plant_id AND line_code = rec.line;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Line code "%" not found for plant_id=%', rec.line, v_plant_id;
                END IF;

                -- 🔹 KPI
                SELECT kpi_id INTO v_kpi_id
                FROM application_data.lk_kpi
                WHERE plant_id = v_plant_id AND kpi_code = rec.kpi;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ KPI "%" not found for plant_id=%', rec.kpi, v_plant_id;
                END IF;

                -- 🔹 Tier
                SELECT tier_id INTO v_tier_id
                FROM application_data.lk_tier
                WHERE  plant_id = v_plant_id and tier_code=rec.tier;

                IF NOT FOUND THEN
                    RAISE EXCEPTION '❌ Tier "%" not found for plant_id=%', rec.tier,v_plant_id;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                -- ⛔ ERRORE DI MAPPATURA
                lp_err_msg := format('❌ Mapping error (import_id=%s): %s', rec.import_id, SQLERRM);

                UPDATE application_staging.ft_pareto_data
                SET is_processed = 1, is_rejected = 1, has_unhandled_error = FALSE, note = lp_err_msg
                WHERE import_id = rec.import_id;

                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', CURRENT_TIMESTAMP),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );

                CONTINUE; -- passa al prossimo record
            END;
			
            v_partition_name := format('ft_pareto_data_plant_%s_%s%02s', v_plant_id, v_year, v_month);

            SELECT EXISTS (
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = 'application_data'
                  AND table_name = v_partition_name
            ) INTO v_partition_exists;

            -- 🔧 Se non esiste → crea partizione
	   IF NOT v_partition_exists THEN
	    BEGIN
        -- 🔧 Tentativo di creazione partizione se non esiste
        PERFORM application_data.create_monthly_partition(
            'ft_pareto_data',
            'day_id',
            v_plant_id,
            v_year,
            v_month
        );

        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            '✔️ Partition created:: ' || v_partition_name,
            lp_last_user
        );

    EXCEPTION WHEN OTHERS THEN
        -- ⚠️ L'errore viene loggato ma NON blocca l'elaborazione del record
        lp_err_msg :=  '⚠️ Partition creation failed: '|| v_partition_name || ' — ' || SQLERRM;

        INSERT INTO application_data.log_operation (
            operation_timestamp,
            operation_src,
            operation_msg,
            operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );
        -- Nessun CONTINUE: si prosegue con INSERT
   	 END;
	ELSE
    -- 🔹 Partizione già esistente → log informativo
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'ℹ️ Partition already exists: ' || v_partition_name,
        lp_last_user
    );
	END IF;

 -- 🔽 Verifica presenza righe nella SELECT dell'INSERT
            SELECT COUNT(*) INTO v_check_count
            FROM application_data.lk_plant p
            JOIN application_data.lk_kpi kpi 
                ON p.plant_id = kpi.plant_id AND kpi.kpi_code = rec.kpi
            JOIN application_data.lk_line l 
                ON l.plant_id = p.plant_id AND l.line_code = rec.line
            JOIN application_data.lk_tier t 
                ON t.plant_id = p.plant_id AND t.tier_code = rec.tier
            JOIN application_data.lk_kpi_category kc 
                ON kc.plant_id = p.plant_id AND kpi.kpi_category_id = kc.kpi_category_id
			JOIN application_data.lk_kpi_type kt 
            ON kt.kpi_type_id = kpi.kpi_type_id and kpi_type_code='PARETO' 
				WHERE p.plant_code = rec.plant;
				
            IF v_check_count = 0 THEN
                -- ❌ Nessun dato disponibile per INSERT
                 UPDATE application_staging.ft_pareto_data
                 SET is_rejected = 1,
                    is_processed = 1,
                    note = 'NO MATCH FOUND FOR INSERT SELECT: [kpi: ' || rec.kpi || ', plant: ' || rec.plant || ', line: ' || rec.line || ', tier: ' || rec.tier || ', item: ' || rec.item || ', day: ' || rec.day || '] — SELECT vuota, record rifiutato.'
                 WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
                   AND tier = rec.tier AND day = rec.day AND item = rec.item 
                   AND file_id = p_file_id;

                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '❗NO MATCH FOUND FOR INSERT SELECT: [kpi: ' || rec.kpi || ', plant: ' || rec.plant || ', line: ' || rec.line || ', tier: ' || rec.tier || ', item: ' || rec.item || ', day: ' || rec.day || '] — SELECT vuota, record rifiutato.',
                    lp_last_user
                );
                CONTINUE;
            END IF;

            BEGIN
                -- 🔽 INSERT
               INSERT
				into application_data.ft_pareto_data (
                    pareto_data_id,
					item,
					kpi_id,
					tier_id,
					line_id,
					module_id,
					plant_id,
					kpi_category_id,
					day_id,
					"day",
					value,
					is_visible,
					is_editable,
					creation_ts,
					creator_user,
					last_modified,
					last_user,
					import_id
                )
                SELECT 
                    nextval('application_data.ft_pareto_data_seq'),
                    rec.item, 
					kpi.kpi_id,
					t.tier_id, 
					l.line_id,
					l.module_id,
					p.plant_id, 
					kc.kpi_category_id,
					v_day_id,
					to_timestamp(v_day_id::text, 'YYYYMMDD'),
                    rec.value,
                    true,
                    true,
                    timezone('UTC', current_timestamp),
                    lp_last_user,
                    timezone('UTC', current_timestamp),
                    lp_last_user,
					rec.import_id
                FROM application_data.lk_plant p
                JOIN application_data.lk_kpi kpi 
                    ON p.plant_id = kpi.plant_id AND kpi.kpi_code = rec.kpi
                JOIN application_data.lk_line l 
                    ON l.plant_id = p.plant_id AND l.line_code = rec.line
                JOIN application_data.lk_tier t 
                    ON t.plant_id = p.plant_id AND t.tier_code = rec.tier
                JOIN application_data.lk_kpi_category kc 
                    ON kc.plant_id = p.plant_id AND kpi.kpi_category_id = kc.kpi_category_id
                WHERE p.plant_code = rec.plant;

                INSERT INTO application_data.log_operation (
                    operation_timestamp,
                    operation_src,
                    operation_msg,
                    operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '✔️ INSERT : [kpi: ' || rec.kpi || ', plant: ' || rec.plant ||  
                    ', line: ' || rec.line || ', tier: ' || rec.tier || 
                    ', day: ' || rec.day || ', value: ' || rec.value ||', import id: ' || rec.import_id ||  ']',
                    lp_last_user
                );

                v_successful_records := v_successful_records + 1;

            EXCEPTION WHEN unique_violation THEN
                BEGIN
                    UPDATE application_data.ft_pareto_data fpd
                    SET 
                        value = rec.value,
                        last_user = lp_last_user,
                        last_modified = timezone('UTC', current_timestamp),
						import_id = rec.import_id 
                    FROM (
                        SELECT 
                            p.plant_id,
                            kpi.kpi_id,
                            l.line_id,
                            t.tier_id,
                            l.module_id
                        FROM application_data.lk_plant p
                        JOIN application_data.lk_kpi kpi 
                            ON p.plant_id = kpi.plant_id AND kpi.kpi_code = rec.kpi
                        JOIN application_data.lk_line l 
                            ON l.plant_id = p.plant_id AND l.line_code = rec.line
                        JOIN application_data.lk_tier t 
                            ON t.plant_id = p.plant_id AND t.tier_code = rec.tier
                        WHERE p.plant_code = rec.plant
                    ) map
                    WHERE fpd.plant_id = map.plant_id
                      AND fpd.kpi_id = map.kpi_id
                      AND fpd.line_id = map.line_id
                      AND fpd.tier_id = map.tier_id
                      AND fpd.module_id = map.module_id
                      AND fpd.item = rec.item
                      AND fpd.day_id = rec.day;

                    GET DIAGNOSTICS lp_record_num = ROW_COUNT;

                    IF lp_record_num > 0 THEN
                        INSERT INTO application_data.log_operation (
                            operation_timestamp,
                            operation_src,
                            operation_msg,
                            operation_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            '✔️ UPDATE: [item: ' || rec.item || 
                            ', kpi: ' || rec.kpi ||
                            ', tier: ' || rec.tier ||
                            ', line: ' || rec.line ||
                            ', plant: ' || rec.plant ||
                            ', day: ' || rec.day ||
                            ', value: ' || rec.value ||
							', import id: ' || rec.import_id ||  ']',
                            lp_last_user
                        );
                        v_successful_records := v_successful_records + 1;
                    ELSE
                        -- ❌ Neither INSERT nor UPDATE succeeded
                        UPDATE application_staging.ft_pareto_data
                        SET is_rejected = 1,
							is_processed= 1
                        WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
                          AND tier = rec.tier AND day = rec.day AND item = rec.item 
                          AND file_id = p_file_id AND import_id = rec.import_id;

                        INSERT INTO application_data.log_operation (
                            operation_timestamp,
                            operation_src,
                            operation_msg,
                            operation_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            '❗NO MATCH FOUND (AFTER UNIQUE VIOLATION): [kpi: ' || rec.kpi || ', plant: ' || rec.plant || 
                            ', line: ' || rec.line || ', tier: ' || rec.tier || 
                            ', day: ' || rec.day || ', import id: ' || rec.import_id || '] — no insert/update applied.',
                            lp_last_user
                        );
                    END IF;

                EXCEPTION WHEN OTHERS THEN
                    -- ❌ UPDATE error → set is_rejected = 1
                    UPDATE application_staging.ft_pareto_data
                    SET is_rejected = 1,
						is_processed= 1
                    WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
                      AND tier = rec.tier AND day = rec.day AND item = rec.item 
                      AND file_id = p_file_id AND import_id = rec.import_id;

                    lp_err_msg := 'UPDATE AFTER UNIQUE VIOLATION ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
                    INSERT INTO application_data.log_error (
                        error_timestamp,
                        error_src,
                        error_msg,
                        error_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        lp_err_msg,
                        lp_last_user
                    );
                END;

            WHEN OTHERS THEN
                -- ❌ INSERT error → set is_rejected = 1
                UPDATE application_staging.ft_pareto_data
                SET is_rejected = 1,
					is_processed= 1
                WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
                  AND tier = rec.tier AND day = rec.day AND item = rec.item 
                  AND file_id = p_file_id  AND import_id = rec.import_id;

                lp_err_msg := 'INSERT ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    lp_err_msg,
                    lp_last_user
                );
            END;

            UPDATE application_staging.ft_pareto_data
            SET is_processed = 1
            WHERE kpi = rec.kpi AND plant = rec.plant AND line = rec.line 
              AND tier = rec.tier AND day = rec.day AND item = rec.item 
              AND file_id = p_file_id and import_id = rec.import_id;

        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'ERROR INSIDE LOOP: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', STEP=' || lp_step;
            INSERT INTO application_data.log_error (
                error_timestamp,
                error_src,
                error_msg,
                error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                lp_err_msg,
                lp_last_user
            );
        END;
    END LOOP;

    lp_step := 4;

        -- 📌 Conclusione su file
    IF v_successful_records = v_num_of_record_file THEN
        UPDATE application_data.lk_files
        SET is_processed = TRUE,
            processed_timestamp = timezone('UTC', CURRENT_TIMESTAMP),
            note = format('✅ Completed. File: %s, Total: %s, OK: %s', p_file_id, v_num_of_record_file, v_successful_records)
        WHERE id::text = p_file_id;

        INSERT INTO application_data.log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            format('✅ Completed. File: %s, Total: %s, OK: %s', p_file_id, v_num_of_record_file, v_successful_records),
            lp_last_user
        );
    ELSE
        UPDATE application_data.lk_files
        SET is_processed = TRUE,
            processed_timestamp = timezone('UTC', CURRENT_TIMESTAMP),
            note = format('⚠️ File %s partially processed. OK: %s, Expected: %s', p_file_id, v_successful_records, v_num_of_record_file)
        WHERE id::text = p_file_id;

        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', CURRENT_TIMESTAMP),
            lp_procedure_name,
            format('⚠️ File %s partially processed. OK: %s, Expected: %s', p_file_id, v_successful_records, v_num_of_record_file),
            lp_last_user
        );
    END IF;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'GENERAL ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    INSERT INTO application_data.log_error (
        error_timestamp,
        error_src,
        error_msg,
        error_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        lp_err_msg,
        p_user_id::text || ' -- ' || p_user_fullname
    );
    RAISE;
END;
$function$
;





-- DROP FUNCTION application_data.get_meeting_note_object(application_data.ft_meeting);

CREATE OR REPLACE FUNCTION application_data.get_meeting_note_object(meeting_row application_data.ft_meeting)
 RETURNS json
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
    -- Restituisce un singolo oggetto JSON per la riga fornita
    RETURN json_build_object(
        'id', meeting_row.note_id,
        'name', meeting_row.meeting_title
    );
END;
$function$
;

-- DROP FUNCTION application_data.get_meeting_notes_json();

CREATE OR REPLACE FUNCTION application_data.get_meeting_notes_json()
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN (
        SELECT
            json_agg(
                json_build_object(
                    'id', fm.note_id,
                    'name', fm.meeting_title
                )
            )
        FROM
            application_data.ft_meeting fm
        WHERE
            fm.note_id IS NOT NULL AND fm.meeting_title IS NOT NULL
        -- Puoi aggiungere ulteriori condizioni WHERE qui se necessario
        -- Esempio: WHERE fm.plant_id = 123
    );
END;
$function$
;

-- DROP FUNCTION application_data.get_action_changes(int8, int8);

CREATE OR REPLACE FUNCTION application_data.get_action_changes(p_plant_id bigint, p_action_id bigint)
 RETURNS TABLE(changed_field text, old_value text, new_value text, changed_by text, change_day_id text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    WITH latest_live AS (
        SELECT
            plant_id,
            action_id,
            action_cd,
            action_ds,
            module_id,
            line_id,
            action_priority_id,
            action_status_id,
            kpi_category_id,
            assign_tier_id,
            action_owner,
            action_raiser,
            closure_day_local_id,
            due_date_day_local_id
        FROM application_data.lk_action
        WHERE plant_id = p_plant_id AND action_id = p_action_id
    ),
    audit_ordered AS (
        SELECT
            au.plant_id,
            au.action_id,
            au.action_cd,
            au.action_ds,
            au.module_id,
            au.line_id,
            au.action_priority_id,
            au.action_status_id,
            au.kpi_category_id,
            au.assign_tier_id,
            au.action_owner,
            au.action_raiser,
            au.closure_day_local_id,
            au.due_date_day_local_id,
            au.last_user,
            TO_CHAR(au.au_operation_ts, 'YYYYMMDD HH24:MI') AS op_day_id
        FROM application_audit.au_lk_action au
        WHERE au.plant_id = p_plant_id AND au.action_id = p_action_id AND change_type <> 'I'
    ),
    raw_changes AS (
        SELECT 
            '<#lblTitle/>' AS changed_field,
            a.action_cd::TEXT AS old_value,
            l.action_cd::TEXT AS new_value,
            a.last_user::TEXT AS changed_by,
            a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        WHERE a.action_cd IS DISTINCT FROM l.action_cd

        UNION ALL

        SELECT 
            '<#ACTION_DS/>', a.action_ds::TEXT, l.action_ds::TEXT, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        WHERE a.action_ds IS DISTINCT FROM l.action_ds

        UNION ALL

        SELECT 
            '<#lblModule/>', m.module_ds, lm.module_ds, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        LEFT JOIN application_data.lk_module m ON a.module_id = m.module_id AND a.plant_id = m.plant_id
        LEFT JOIN application_data.lk_module lm ON l.module_id = lm.module_id AND l.plant_id = lm.plant_id
        WHERE a.module_id IS DISTINCT FROM l.module_id

        UNION ALL

        SELECT 
            '<#lblLine/>', li.line_ds, lli.line_ds, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        LEFT JOIN application_data.lk_line li ON a.line_id = li.line_id AND a.plant_id = li.plant_id
        LEFT JOIN application_data.lk_line lli ON l.line_id = lli.line_id AND l.plant_id = lli.plant_id
        WHERE a.line_id IS DISTINCT FROM l.line_id

        UNION ALL

        SELECT 
            '<#lblPriority/>', p.action_priority_ds, lp.action_priority_ds, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        LEFT JOIN application_data.lk_action_priority p ON a.action_priority_id = p.action_priority_id
        LEFT JOIN application_data.lk_action_priority lp ON l.action_priority_id = lp.action_priority_id
        WHERE a.action_priority_id IS DISTINCT FROM l.action_priority_id

        UNION ALL

        SELECT 
            '<#lblStatus/>', s.action_status_ds, ls.action_status_ds, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        LEFT JOIN application_data.lk_action_status s ON a.action_status_id = s.action_status_id
        LEFT JOIN application_data.lk_action_status ls ON l.action_status_id = ls.action_status_id
        WHERE a.action_status_id IS DISTINCT FROM l.action_status_id

        UNION ALL

        SELECT 
            '<#Kpi_Category_Id_Cd/>', k.kpi_category_ds, lk.kpi_category_ds, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        LEFT JOIN application_data.lk_kpi_category k ON a.kpi_category_id = k.kpi_category_id
        LEFT JOIN application_data.lk_kpi_category lk ON l.kpi_category_id = lk.kpi_category_id
        WHERE a.kpi_category_id IS DISTINCT FROM l.kpi_category_id

        UNION ALL

        SELECT 
            '<#lblAssignedTier/>', t.tier_ds, lt.tier_ds, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        LEFT JOIN application_data.lk_tier t ON a.assign_tier_id = t.tier_id
        LEFT JOIN application_data.lk_tier lt ON l.assign_tier_id = lt.tier_id
        WHERE a.assign_tier_id IS DISTINCT FROM l.assign_tier_id

        UNION ALL

        SELECT 
            '<#lblOwner/>', a.action_owner::TEXT, l.action_owner::TEXT, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        WHERE a.action_owner IS DISTINCT FROM l.action_owner

        UNION ALL

        SELECT 
            '<#lblRaiser/>', a.action_raiser::TEXT, l.action_raiser::TEXT, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        WHERE a.action_raiser IS DISTINCT FROM l.action_raiser

        UNION ALL

        SELECT 
            '<#lblClosureDate/>', a.closure_day_local_id::TEXT, l.closure_day_local_id::TEXT, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        WHERE a.closure_day_local_id IS DISTINCT FROM l.closure_day_local_id

        UNION ALL

        SELECT 
            '<#lblDueDate/>', a.due_date_day_local_id::TEXT, l.due_date_day_local_id::TEXT, a.last_user::TEXT, a.op_day_id
        FROM audit_ordered a
        CROSS JOIN latest_live l
        WHERE a.due_date_day_local_id IS DISTINCT FROM l.due_date_day_local_id
    ),
    deduplicated AS (
        SELECT
            rc.changed_field,
            rc.old_value,
            rc.new_value,
            rc.changed_by,
            rc.op_day_id,
            ROW_NUMBER() OVER (
                PARTITION BY rc.changed_field, rc.op_day_id, rc.changed_by
                ORDER BY rc.op_day_id DESC
            ) AS rn
        FROM raw_changes rc
    ),
    final_dedup AS (
        SELECT
            d.changed_field,
            d.old_value,
            d.new_value,
            d.changed_by,
            d.op_day_id AS change_day_id,
            ROW_NUMBER() OVER (
                 PARTITION BY d.changed_field, d.old_value, d.new_value, SUBSTRING(d.op_day_id FROM 1 FOR 8)
                ORDER BY d.changed_by
            ) AS rn_final
        FROM deduplicated d
        WHERE d.rn = 1
          AND COALESCE(trim(regexp_replace(d.old_value, '\s+', '', 'g')), '') 
            IS DISTINCT FROM 
            COALESCE(trim(regexp_replace(d.new_value, '\s+', '', 'g')), '')
    )
    SELECT
       final_dedup.changed_field,
        final_dedup.old_value,
        final_dedup.new_value,
        final_dedup.changed_by,
        final_dedup.change_day_id
    FROM final_dedup
    WHERE final_dedup.rn_final = 1
    ORDER BY final_dedup.change_day_id DESC;
END;
$function$
;

-- DROP FUNCTION application_data.insert_action_items(text);

CREATE OR REPLACE FUNCTION application_data.insert_action_items(json_text text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    json_data JSONB;
    action_item JSONB;
    task_title TEXT;
    assigned_user TEXT;
    due_date DATE;
    status_id INT;
    thumbnail_url TEXT := '/content/resources/T0T/YLTCFBO/815197775179621/smart_toy_24dp.png';
BEGIN
    -- Parse input JSON
    BEGIN
        json_data := json_text::jsonb;
    EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'Invalid JSON format: %', json_text;
    END;

    -- Check 'actionItems' exists
    IF NOT json_data ? 'actionItems' THEN
        RAISE EXCEPTION 'Missing "actionItems" key in JSON input: %', json_text;
    END IF;

    -- Get status ID
    SELECT id INTO status_id 
    FROM application_data.kanban_statuses 
    WHERE name = 'To Do'
    LIMIT 1;

    IF status_id IS NULL THEN
        RAISE EXCEPTION 'Status "To Do" not found in kanban_statuses';
    END IF;

    -- Loop over items
    FOR action_item IN 
        SELECT jsonb_array_elements(json_data->'actionItems')
    LOOP
        task_title := action_item->>'task';
        assigned_user := action_item->>'owner';

        IF task_title IS NULL OR assigned_user IS NULL THEN
            RAISE NOTICE 'Skipping item with missing task or owner: %', action_item;
            CONTINUE;
        END IF;

        -- Safe date parsing with fallback
        BEGIN
            due_date := (action_item->>'dueDate')::DATE;
        EXCEPTION WHEN others THEN
            BEGIN
                due_date := to_date(action_item->>'dueDate', 'Mon DD');
            EXCEPTION WHEN others THEN
                due_date := NULL;
            END;
        END;

        -- Insert into table
        INSERT INTO application_data.kanban_cards (
            title, assigned_to, due_date, status_id, creation_date, last_updated, thumbnail_url
        )
        VALUES (
            task_title, assigned_user, due_date, status_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, thumbnail_url
        );
    END LOOP;
END;
$function$
;


-- DROP FUNCTION application_data.import_actions_to_pending_from_json(jsonb, int4, int4, int4, int8, int4, int8, text, varchar);

CREATE OR REPLACE FUNCTION application_data.import_actions_to_pending_from_json(p_json_input jsonb, p_hi_mod_id integer, p_hi_line_id integer, p_hi_plant_id integer, p_tier_id bigint, p_hi_me_day_id integer, p_raiser_id bigint, p_raiser_fullname text, p_creator_user character varying)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    item jsonb;
    v_title text;
    v_description text;
    v_category_id int8 := NULL;
    v_owner_id bigint;
    v_owner_fullname text;
    v_due_date_str text;
    v_due_date_int integer;
    v_action_id bigint;
    v_index integer := 0;
    v_due_ts timestamp;
    v_due_ts_utc timestamp;
    v_creation_ts_utc timestamp := timezone('UTC', current_timestamp);
    v_meeting_title text := p_json_input ->> 'meetingTitle';
    v_meeting_id text := p_json_input ->> 'uuid';
    v_meeting_date timestamp := NULL;
    v_opening_ts timestamp;
    v_opening_ts_utc timestamp;
    v_raice_notice text;
   v_exists boolean;
  v_category_ds text; 
BEGIN
    -- Parse meetingDate as timestamp if possible
    BEGIN
        v_meeting_date := to_timestamp(p_json_input ->> 'meetingDate', 'Dy, Mon DD, YYYY');
    EXCEPTION
        WHEN others THEN
            v_meeting_date := NULL;
    END;

    v_opening_ts := to_timestamp(p_hi_me_day_id::text, 'YYYYMMDD');
    v_opening_ts_utc := timezone('UTC', v_opening_ts);

    FOR item IN
        SELECT jsonb_array_elements(p_json_input -> 'actionItems')
    LOOP
        v_index := v_index + 1;
        v_raice_notice := NULL;
       v_category_id := NULL;
        v_due_ts := NULL;
        v_due_ts_utc := NULL;
        v_due_date_int := NULL;

        -- Estrazione e parsing dei dati
        v_title := item -> 'task' ->> 'title';
        v_description := item -> 'task' ->> 'description';
       v_category_ds := item -> 'category' ->> 'category_ds';  
        v_owner_id := NULLIF(item -> 'owner' ->> 'id', '')::bigint;
        v_owner_fullname := item -> 'owner' ->> 'name';
        v_due_date_str := item ->> 'dueDate';
       
       -- CATEGORY_ID: gestito con controllo esistenza
        IF item -> 'category' ? 'category_id' THEN
            BEGIN
                v_category_id := (item -> 'category' ->> 'category_id')::int8;
            EXCEPTION
                WHEN others THEN
                    v_category_id := NULL;
                    v_raice_notice := coalesce(v_raice_notice, '') || 'Invalid CATEGORY_ID format. ';
            END;
           IF v_category_id IS NULL OR v_category_id = 0 THEN
                v_raice_notice := coalesce(v_raice_notice, '') || 'Missing CATEGORY. ';
                v_category_id := NULL;
            END IF;
        ELSE
            v_raice_notice := coalesce(v_raice_notice, '') || 'Missing CATEGORY. ';
        END IF;

        -- Validazione e costruzione messaggio raice_notice
        IF v_title IS NULL OR trim(v_title) = '' THEN
            v_raice_notice := coalesce(v_raice_notice, '') || 'Missing TITLE. ';
        END IF;

        IF v_description IS NULL OR trim(v_description) = '' THEN
            v_raice_notice := coalesce(v_raice_notice, '') || 'Missing DESCRIPTION. ';
        END IF;

        

        IF v_owner_id IS NULL OR trim(v_owner_id::text) = '' THEN
            v_raice_notice := coalesce(v_raice_notice, '') || 'Missing OWNER. ';
        END IF;

        IF v_due_date_str IS NULL OR trim(v_due_date_str) = '' THEN
            v_raice_notice := coalesce(v_raice_notice, '') || 'Missing DUE DATE. ';
        ELSE
            BEGIN
                v_due_ts := to_timestamp(v_due_date_str, 'YYYY/MM/DD');
                v_due_date_int := to_char(v_due_ts, 'YYYYMMDD')::integer;
                v_due_ts_utc := timezone('UTC', v_due_ts);
            EXCEPTION
                WHEN others THEN
                    v_raice_notice := coalesce(v_raice_notice, '') || 'Invalid DUE DATE format. ';
                    v_due_ts := NULL;
                    v_due_date_int := NULL;
                    v_due_ts_utc := NULL;
            END;
        END IF;

         -- Skip se già esiste in lk_pending_actions
        SELECT EXISTS (
            SELECT 1
            FROM application_data.lk_pending_actions
            WHERE meeting_id = v_meeting_id
              AND action_cd = v_title
              
              AND module_id = p_hi_mod_id
              AND line_id = p_hi_line_id
              AND plant_id = p_hi_plant_id
        ) INTO v_exists;

        IF v_exists THEN
            CONTINUE;
        END IF;

        -- Skip se già esiste in lk_action
        SELECT EXISTS (
            SELECT 1
            FROM application_data.lk_action
            WHERE action_cd = v_title
              
              AND module_id = p_hi_mod_id
              AND line_id = p_hi_line_id
              AND plant_id = p_hi_plant_id
        ) INTO v_exists;

        IF v_exists THEN
            CONTINUE;
        END IF;
       
       
       
       
        -- Generazione ID
        SELECT nextval('application_data.lk_action_id_seq') INTO v_action_id;

        -- Inserimento nella tabella target (sempre)
        INSERT INTO application_data.lk_pending_actions (
            meeting_cd,
            meeting_id,
            meeting_date,
            plant_id,
            action_id,
            action_cd,
            action_html_ds,
            action_ds,
            module_id,
            line_id,
            action_priority_id,
            action_status_id,
            is_processed,
            raice_notice,
            kpi_category_id,
             kpi_category_cd, 
            opening_tier_id,
            assign_tier_id,
            action_owner,
            action_raiser,
            opening_day_local_id,
            opening_local_ts,
            opening_utc_ts,
            due_date_day_local_id,
            due_date_local_ts,
            due_date_utc_ts,
            creation_day_local_id,
            creation_local_ts,
            creation_utc_ts,
            creator_user,
            owner_id
        ) VALUES (
            v_meeting_title,
            v_meeting_id,
            v_meeting_date,
            p_hi_plant_id,
            v_action_id,
            v_title,
            v_description,
            v_description,
            p_hi_mod_id,
            p_hi_line_id,
            300,
            100,
            0,
            v_raice_notice,
            v_category_id,
             v_category_ds, 
            p_tier_id,
            p_tier_id,
            v_owner_id || ' -- ' || v_owner_fullname,
            p_raiser_id || ' -- ' || p_raiser_fullname,
            p_hi_me_day_id,
            v_opening_ts,
            v_opening_ts_utc,
            v_due_date_int,
            v_due_ts,
            v_due_ts_utc,
            to_char(current_date, 'YYYYMMDD')::integer,
            current_timestamp,
            v_creation_ts_utc,
            p_creator_user,
            v_owner_id
        );
     
    END LOOP;
END;
$function$
;

-- DROP PROCEDURE application_data.sp_shift_pattern_default(varchar, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_shift_pattern_default(p_plant_code_list character varying, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name varchar(100) := 'application_data.sp_shift_pattern_default';
    lp_caller         varchar(200);
    lp_err_msg        varchar(2000);
    lp_now_utc        timestamp;

    v_code            varchar(100);
    v_plant_code_list varchar := p_plant_code_list;
BEGIN
    lp_now_utc := timezone('UTC', current_timestamp);
    lp_caller  := p_user_id::text || ' -- ' || p_user_fullname;

    ----------------------------------------------------------------------
    -- INITIAL LOG ENTRY
    ----------------------------------------------------------------------
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        lp_now_utc,
        lp_procedure_name,
        'Input: [p_plant_code_list=' || COALESCE(p_plant_code_list,'NULL') ||
        ', p_user_id=' || COALESCE(p_user_id::text,'NULL') ||
        ', p_user_fullname=' || COALESCE(p_user_fullname,'NULL') || ']',
        lp_caller
    );

    ----------------------------------------------------------------------
    -- CASE 1: ALL
    ----------------------------------------------------------------------
    IF upper(trim(p_plant_code_list)) = 'ALL' THEN

        FOR v_code IN
            SELECT plant_code
            FROM application_data.lk_plant
            WHERE is_active = TRUE AND is_deleted = FALSE
            ORDER BY plant_code
        LOOP
            BEGIN
                CALL application_data.sp_shift_pattern_default_single(
                    v_code,
                    p_user_id,
                    p_user_fullname
                );

            EXCEPTION
                WHEN OTHERS THEN

                    IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'NON-CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        CONTINUE;

                    ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR
                          SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR
                          SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    ELSE

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'GENERIC ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    END IF;
            END;
        END LOOP;

        v_plant_code_list := 'ALL_DONE';
        RETURN;
    END IF;


    ----------------------------------------------------------------------
    -- CASE 2: LIST (CSV)
    ----------------------------------------------------------------------
    IF p_plant_code_list LIKE '%,%' THEN

        FOR v_code IN
            SELECT trim(both ' ' FROM regexp_split_to_table(p_plant_code_list, ','))
        LOOP
            BEGIN
                CALL application_data.sp_shift_pattern_default_single(
                    v_code,
                    p_user_id,
                    p_user_fullname
                );

            EXCEPTION
                WHEN OTHERS THEN

                    IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'NON-CRITICAL LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        CONTINUE;

                    ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR
                          SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR
                          SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'CRITICAL LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    ELSE

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'GENERIC LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    END IF;

            END;
        END LOOP;

        v_plant_code_list := 'LIST_DONE';
        RETURN;
    END IF;


    ----------------------------------------------------------------------
    -- CASE 3: SINGLE
    ----------------------------------------------------------------------
    BEGIN
        CALL application_data.sp_shift_pattern_default_single(
            trim(both ' ' FROM p_plant_code_list),
            p_user_id,
            p_user_fullname
        );

    EXCEPTION
        WHEN OTHERS THEN

            IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN

                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    lp_now_utc,
                    lp_procedure_name,
                    'NON-CRITICAL SINGLE → plant='||p_plant_code_list||' → '||SQLERRM,
                    lp_caller
                );
                RETURN;

            ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR
                  SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR
                  SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN

                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    lp_now_utc,
                    lp_procedure_name,
                    'CRITICAL SINGLE → plant='||p_plant_code_list||' → '||SQLERRM,
                    lp_caller
                );
                RAISE;

            ELSE

                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    lp_now_utc,
                    lp_procedure_name,
                    'GENERIC SINGLE → plant='||p_plant_code_list||' → '||SQLERRM,
                    lp_caller
                );
                RAISE;

            END IF;
    END;

    v_plant_code_list := p_plant_code_list || '_DONE';
    RETURN;

END;
$procedure$
;

-- DROP PROCEDURE application_data.sp_shift_pattern_default_single(varchar, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_shift_pattern_default_single(p_plant_code character varying, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    --------------------------------------------------------------------
    -- Logging and debug variables
    --------------------------------------------------------------------
    lp_procedure_name varchar(100) := 'application_data.sp_shift_pattern_default_single';
    lp_err_msg        varchar(2000);
    lp_step           numeric := 0;
    lp_caller         varchar(200);

    --------------------------------------------------------------------
    -- Business variables
    --------------------------------------------------------------------
    v_plant_id   bigint;
    v_pattern_id bigint;

    v_inserted   bigint := 0;
    v_updated    bigint := 0;
BEGIN
    --------------------------------------------------------------------
    -- 0. Validate user info and prepare caller string
    --------------------------------------------------------------------
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_caller := p_user_id::text || ' -- ' || p_user_fullname;

    --------------------------------------------------------------------
    -- 0.1 Log input parameters
    --------------------------------------------------------------------
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [p_plant_code: ' || COALESCE(p_plant_code, 'NULL') || ', ' ||
        'p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || ', ' ||
        'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']',
        lp_caller
    );

    lp_step := 1;

    --------------------------------------------------------------------
    -- 1. Resolve plant_id from plant_code
    --    Only active and non-deleted plants are valid.
    --------------------------------------------------------------------
    SELECT lp.plant_id
    INTO v_plant_id
    FROM application_data.lk_plant lp
    WHERE lp.plant_code = p_plant_code
      AND lp.is_deleted = false
      AND lp.is_active  = true
    LIMIT 1;

    IF v_plant_id IS NULL THEN
        lp_err_msg := 'ERROR: Plant with code ' || COALESCE(p_plant_code, 'NULL') ||
                      ' not found or not active.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_step := 2;

    --------------------------------------------------------------------
    -- 2. Get MIN(pattern_id) among default patterns for this plant
    --------------------------------------------------------------------
    SELECT MIN(p.pattern_id)
    INTO v_pattern_id
    FROM application_data.sh_lk_pattern p
    WHERE p.plant_id   = v_plant_id
      AND p.is_default = 1
      AND p.is_active  = 1
      AND p.is_deleted = 0;

    lp_step := 3;

    --------------------------------------------------------------------
    -- 3. If no default pattern, get MIN(pattern_id) among active patterns
    --------------------------------------------------------------------
    IF v_pattern_id IS NULL THEN
        SELECT MIN(p.pattern_id)
        INTO v_pattern_id
        FROM application_data.sh_lk_pattern p
        WHERE p.plant_id  = v_plant_id
          AND p.is_active = 1
          AND p.is_deleted = 0;
    END IF;

    --------------------------------------------------------------------
    -- 4. Log selected pattern_id (may be NULL if no active pattern exists)
    --------------------------------------------------------------------
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Plant ' || COALESCE(p_plant_code, 'NULL') ||
        ' (ID: ' || v_plant_id::text || ') - Selected MIN(pattern_id): ' ||
        COALESCE(v_pattern_id::text, 'NULL'),
        lp_caller
    );

    lp_step := 4;

    --------------------------------------------------------------------
    -- 5. Insert missing rows in sh_lk_line_pattern_default
    --    for each line and weekday of the plant.
    --    pattern_id will use the MIN(pattern_id) found (can be NULL).
    --------------------------------------------------------------------
    INSERT INTO application_data.sh_lk_line_pattern_default AS dst
        (plant_id, line_id, week_day_id, pattern_id,is_modify)
    SELECT
        l.plant_id,
        l.line_id,
        wd.week_day_id,
        v_pattern_id,          -- MIN(pattern_id) for this plant (can be NULL)
		1
    FROM application_data.lk_line l
    CROSS JOIN application_data.lk_week_day wd
    WHERE l.plant_id   = v_plant_id
      AND l.is_active  = true
      AND l.is_deleted = false
      AND NOT EXISTS (
            SELECT 1
            FROM application_data.sh_lk_line_pattern_default d
            WHERE d.plant_id    = l.plant_id
              AND d.line_id     = l.line_id
              AND d.week_day_id = wd.week_day_id
      );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    lp_step := 5;

    --------------------------------------------------------------------
    -- 6. Second pass: assign MIN(pattern_id) to existing rows with NULL
    --    Only if a valid pattern_id (MIN) was found.
    --------------------------------------------------------------------
    IF v_pattern_id IS NOT NULL THEN
        UPDATE application_data.sh_lk_line_pattern_default d
        SET pattern_id = v_pattern_id,
			au_change_day_id = to_char(timezone('UTC', current_timestamp),'YYYYMMDD')::int,
			au_change_ts = timezone('UTC', current_timestamp)
        WHERE d.plant_id   = v_plant_id
          AND d.pattern_id IS NULL;

        GET DIAGNOSTICS v_updated = ROW_COUNT;
    ELSE
        v_updated := 0;
    END IF;

    lp_step := 6;

    --------------------------------------------------------------------
    -- 7. Log summary for this plant
    --------------------------------------------------------------------
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Plant ' || COALESCE(p_plant_code, 'NULL') ||
        ' (ID: ' || v_plant_id::text || ') - ' ||
        'Inserted rows: ' || v_inserted::text || ', ' ||
		'Updated rows (pattern_id NULL → MIN(pattern_id)='||v_pattern_id||'): ' || v_updated::text,
        lp_caller
    );

EXCEPTION
    WHEN OTHERS THEN
        ----------------------------------------------------------------
        -- Error logging block: log into log_error and re-raise
        ----------------------------------------------------------------
        lp_err_msg := 'ERROR: ' || SQLERRM ||
                      ', SQLSTATE: ' || SQLSTATE ||
                      ', lp_step: ' || lp_step::text ||
                      ', p_plant_code: ' || COALESCE(p_plant_code, 'NULL');

        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src,
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            COALESCE(lp_caller, 'UNKNOWN CALLER')
        );

        RAISE;
END;
$procedure$
;



-- DROP PROCEDURE application_data.sp_sync_lk_shift_from_calendar(int8, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_sync_lk_shift_from_calendar(
    p_plant_id      bigint,
    p_user_id       bigint,
    p_user_fullname varchar
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name  varchar(100) := 'application_data.sp_sync_lk_shift_from_calendar';
    lp_caller          varchar(200);
    lp_err_msg         varchar(2000);
    lp_step            int := 0;

    v_plant_timezone   varchar(100);
    v_today_local      int;         
    v_today_local_ts   timestamp;   
BEGIN
    ----------------------------------------------------------------------
    -- Step 0: Validate inputs
    ----------------------------------------------------------------------
    lp_step := 0;

    IF p_plant_id IS NULL THEN
        RAISE EXCEPTION 'p_plant_id cannot be NULL';
    END IF;

    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User info cannot be NULL';
    END IF;

    lp_caller := p_user_id::text || ' -- ' || p_user_fullname;

    ----------------------------------------------------------------------
    -- Step 1: Read plant timezone
    ----------------------------------------------------------------------
    lp_step := 1;

    SELECT plant_timezone
    INTO v_plant_timezone
    FROM application_data.lk_plant
    WHERE plant_id = p_plant_id
      AND is_active = TRUE
      AND is_deleted = FALSE;

    IF v_plant_timezone IS NULL THEN
        RAISE EXCEPTION 'Invalid plant_id: %', p_plant_id;
    END IF;

    ----------------------------------------------------------------------
    -- Step 2: Compute local day YYYYMMDD
    ----------------------------------------------------------------------
    lp_step := 2;

    v_today_local_ts := (CURRENT_TIMESTAMP AT TIME ZONE v_plant_timezone);
    v_today_local := to_char(v_today_local_ts, 'YYYYMMDD')::int;

    ----------------------------------------------------------------------
    -- Step 3: Log START
    ----------------------------------------------------------------------
    lp_step := 3;

    INSERT INTO application_data.log_operation(
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'START sync ft_shift → plant_id='||p_plant_id||' LOCAL_DAY='||v_today_local,
        lp_caller
    );

    ----------------------------------------------------------------------
    -- Step 4: INSERT new shifts into ft_shift
    ----------------------------------------------------------------------
    lp_step := 4;

    INSERT INTO application_data.ft_shift(
        plant_id,
        line_id,
        shift_id,
        day_id_utc,
        start_timestamp_utc,
        end_timestamp_utc,
        working_duration_sec,
        is_manually_declared,
        start_timestamp_local,
        end_timestamp_local,
        day_id_local
    )
    SELECT DISTINCT
        lc.plant_id,
        lc.line_id,
        lc.shift_id,
        lc.day_id_utc,
        lc.shift_start_dt_utc,
        lc.shift_end_dt_utc,
        lc.working_duration_sec,
        FALSE,                       -- fixed default
        lc.shift_start_dt,
        lc.shift_end_dt,
        lc.day_id
    FROM application_data.sh_lk_line_calendar lc
    WHERE lc.plant_id = p_plant_id
      AND lc.day_id = v_today_local
      AND lc.is_no_working_day = 0
      AND lc.is_scheduled_to_run = 1
      AND NOT EXISTS (
            SELECT 1
            FROM application_data.ft_shift f
            WHERE f.plant_id = lc.plant_id
              AND f.line_id = lc.line_id
              AND f.shift_id = lc.shift_id
              AND f.day_id_utc = lc.day_id_utc
      );

    ----------------------------------------------------------------------
    -- Step 5: UPDATE existing rows (placeholder)
    ----------------------------------------------------------------------
    lp_step := 5;

    UPDATE application_data.ft_shift f
    SET
        -- PLACEHOLDER FOR FUTURE FIELDS
        -- e.g. working_duration_sec = lc.working_duration_sec,
        start_timestamp_utc  = lc.shift_start_dt_utc,
        end_timestamp_utc    = lc.shift_end_dt_utc,
        start_timestamp_local = lc.shift_start_dt,
        end_timestamp_local   = lc.shift_end_dt,
        day_id_local          = lc.day_id
    FROM application_data.sh_lk_line_calendar lc
    WHERE f.plant_id = lc.plant_id
      AND f.line_id = lc.line_id
      AND f.shift_id = lc.shift_id
      AND f.day_id_utc = lc.day_id_utc
      AND lc.plant_id = p_plant_id
      AND lc.day_id = v_today_local
      AND lc.is_no_working_day = 0
      AND lc.is_scheduled_to_run = 1;

    ----------------------------------------------------------------------
    -- Step 6: Log END
    ----------------------------------------------------------------------
    lp_step := 6;

    INSERT INTO application_data.log_operation(
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END sync ft_shift → plant_id='||p_plant_id||' LOCAL_DAY='||v_today_local,
        lp_caller
    );

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg :=
            'ERROR ['||lp_procedure_name||'] step='||lp_step||
            ' plant_id='||p_plant_id||
            ' msg='||SQLERRM||' state='||SQLSTATE;

        INSERT INTO application_data.log_error(
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_caller
        );

        RAISE;
END;
$procedure$;

-- DROP FUNCTION application_data.evaluate_duration(text, text, int4);

CREATE OR REPLACE FUNCTION application_data.evaluate_duration(start_time text, end_time text, end_offset integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
/* Given the params:
*   - start_time    TEXT
*   - end_time      TEXT
*  this function evaluates and returns the duration(in minutes) of the interval [start,end]
*/
DECLARE
    result_duration INTEGER;        -- Declare a variable to store the result duration
BEGIN
    IF end_offset = 0 THEN  
        -- If end_offset is 0, it mean the shift does NOT cross midnight
        
        result_duration := 
                    -- (end_time.hours - start_time.hours - 1 ) * 60
                    (
                        ( (cast ( substring(end_time,1,2) as integer) - cast ( substring(start_time,1,2) as integer) -1 ) *60 )
                        +
                        ( 60 - cast ( substring (start_time,4,2) as integer) + cast ( substring(end_time,4,2)as integer) ) 
                    );

    ELSIF end_offset = 1 THEN
        -- If end_offset is 1, it mean the shift does cross midnight
        
        result_duration := 
                    -- hours included before midnight - 1
                    (  
                        (
                            (
                                ( cast( substring ('24:00',1,2)as integer) ) - ( cast ( substring(start_time,1,2) as integer) )   -1
                            ) *60
                        ) 
                        +
                        ( 60 - cast ( substring (start_time,4,2) as integer)     )
  
                        +
                        (cast (substring (end_time,1,2)  as integer)   *60)
                        +
                        cast (substring (end_time,4,2) as integer)  
                    );
    ELSE
        RAISE EXCEPTION 'Offset value is not valid: %', end_offset;
    END IF;

    RETURN result_duration;
END;
$function$
;


-- DROP PROCEDURE application_data.sp_master_shift_processing(varchar, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_master_shift_processing(p_plant_filter character varying, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name   varchar(100) := 'application_data.sp_master_shift_processing';
    lp_caller           varchar(200);
    lp_err_msg          varchar(2000);

    v_raw_filter        varchar;
    v_clean_filter      varchar;
    v_plant_code        varchar;

    v_local_time        time;
    v_timezone          varchar;

    v_filtered_list     text := '';
BEGIN
    ----------------------------------------------------------------------
    -- 0) Caller identity
    ----------------------------------------------------------------------
    lp_caller := p_user_id::text || ' -- ' || p_user_fullname;

    ----------------------------------------------------------------------
    -- 1) Normalize input filter
    ----------------------------------------------------------------------
    v_clean_filter :=
        trim(
            both ' ' from
            replace(
                coalesce(p_plant_filter, ''),
                '''', ''
            )
        );

    IF v_clean_filter = '' THEN
        v_clean_filter := 'ALL';
    END IF;

    ----------------------------------------------------------------------
    -- Log: MASTER START
    ----------------------------------------------------------------------
    INSERT INTO application_data.log_operation(
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'MASTER START – RawFilter='||coalesce(p_plant_filter,'NULL')||
        ', CleanFilter='||v_clean_filter||
        ', Mode=Dynamic Date Calculation',
        lp_caller
    );

    ----------------------------------------------------------------------
    -- 2) Determine which plants qualify based on LOCAL TIME.
    ----------------------------------------------------------------------

    IF upper(v_clean_filter) = 'ALL' THEN

        ------------------------------------------------------------------
        -- ALL plants → filter all active plants by local time window
        ------------------------------------------------------------------
        FOR v_plant_code, v_timezone IN
            SELECT plant_code, plant_timezone
            FROM application_data.lk_plant
            WHERE is_active = TRUE AND is_deleted = FALSE
        LOOP
            
            -- ✅ ADDED: Safety check for NULL Timezone in 'ALL' loop
            IF v_timezone IS NULL THEN
                INSERT INTO application_data.log_error(
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Skipping plant (No Timezone defined): ' || v_plant_code,
                    lp_caller
                );
                CONTINUE; -- Skip this plant, proceed to next
            END IF;

            -- Compute local time for each plant robustly
            v_local_time := (NOW() AT TIME ZONE v_timezone)::time;

            IF v_local_time BETWEEN time '00:00' AND time '00:59' THEN

                v_filtered_list :=
                    CASE WHEN v_filtered_list = '' THEN trim(v_plant_code)
                         ELSE v_filtered_list || ',' || trim(v_plant_code)
                    END;

                INSERT INTO application_data.log_operation(
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant '||trim(v_plant_code)||' included: Local='||v_local_time||
                    ', TZ='||v_timezone,
                    lp_caller
                );
            ELSE
                INSERT INTO application_data.log_operation(
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant '||trim(v_plant_code)||' skipped: Local='||v_local_time||
                    ', TZ='||v_timezone,
                    lp_caller
                );
            END IF;

        END LOOP;


    ELSIF v_clean_filter LIKE '%,%' THEN
        ------------------------------------------------------------------
        -- CASE LIST → split CSV and check each requested plant
        ------------------------------------------------------------------
        FOR v_plant_code IN
            SELECT trim(both ' ' FROM regexp_split_to_table(v_clean_filter, ','))
        LOOP
            -- Normalize requested plant code
            v_plant_code := trim(v_plant_code);

            SELECT plant_timezone
            INTO v_timezone
            FROM application_data.lk_plant
            WHERE trim(plant_code) = v_plant_code
              AND is_active = TRUE
              AND is_deleted = FALSE;

            -- Safety check for NULL Timezone in LIST loop (already existed, kept for consistency)
            IF v_timezone IS NULL THEN
                INSERT INTO application_data.log_error(
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Invalid plant or No Timezone in list: '||v_plant_code,
                    lp_caller
                );
                CONTINUE;
            END IF;

            v_local_time := (NOW() AT TIME ZONE v_timezone)::time;

            IF v_local_time BETWEEN time '00:00' AND time '00:59' THEN

                v_filtered_list :=
                    CASE WHEN v_filtered_list = '' THEN v_plant_code
                         ELSE v_filtered_list || ',' || v_plant_code
                    END;

                INSERT INTO application_data.log_operation(
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant '||v_plant_code||' included (LIST): Local='||
                    v_local_time||', TZ='||v_timezone,
                    lp_caller
                );
            ELSE
                INSERT INTO application_data.log_operation(
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Plant '||v_plant_code||' skipped (LIST): Local='||
                    v_local_time||', TZ='||v_timezone,
                    lp_caller
                );
            END IF;

        END LOOP;


    ELSE
        ------------------------------------------------------------------
        -- CASE SINGLE
        ------------------------------------------------------------------
        v_plant_code := trim(both ' ' FROM v_clean_filter);

        SELECT plant_timezone
        INTO v_timezone
        FROM application_data.lk_plant
        WHERE trim(plant_code) = v_plant_code
          AND is_active = TRUE
          AND is_deleted = FALSE;

        IF v_timezone IS NULL THEN
            RAISE EXCEPTION 'Invalid plant_code or No Timezone: %', v_plant_code;
        END IF;

        v_local_time := (NOW() AT TIME ZONE v_timezone)::time;

        IF v_local_time BETWEEN time '00:00' AND time '00:59' THEN

            v_filtered_list := v_plant_code;

            INSERT INTO application_data.log_operation(
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Plant '||v_plant_code||' included (SINGLE): Local='||
                v_local_time||', TZ='||v_timezone,
                lp_caller
            );

        ELSE
            INSERT INTO application_data.log_operation(
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Plant '||v_plant_code||' skipped (SINGLE): Local='||
                v_local_time||', TZ='||v_timezone,
                lp_caller
            );

            RETURN;
        END IF;

    END IF;


    ----------------------------------------------------------------------
    -- 3) If no plant qualified, exit
    ----------------------------------------------------------------------
    IF v_filtered_list = '' THEN
        INSERT INTO application_data.log_operation(
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'MASTER END – No plants qualified',
            lp_caller
        );
        RETURN;
    END IF;


    ----------------------------------------------------------------------
    -- 4) Execute dispatchers on filtered list
    ----------------------------------------------------------------------

    ----------------------------
    -- PATTERN DEFAULT ROUTINE
    ----------------------------
    BEGIN
        CALL application_data.sp_shift_pattern_default(
            v_filtered_list,
            p_user_id,
            p_user_fullname
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN
            INSERT INTO application_data.log_error(
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'NON-CRITICAL in pattern_default → '||SQLERRM,
                lp_caller
            );
        ELSE
            INSERT INTO application_data.log_error(
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'CRITICAL in pattern_default → '||SQLERRM,
                lp_caller
            );
            RAISE;
        END IF;
    END;


    ----------------------------
    -- SHIFT MANAGE ROUTINE
    ----------------------------
    BEGIN
        CALL application_data.sp_shift_manage(
            v_filtered_list,
            p_user_id,
            p_user_fullname
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN
            INSERT INTO application_data.log_error(
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'NON-CRITICAL in shift_manage → '||SQLERRM,
                lp_caller
            );
        ELSE
            INSERT INTO application_data.log_error(
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'CRITICAL in shift_manage → '||SQLERRM,
                lp_caller
            );
            RAISE;
        END IF;
    END;


    ----------------------------
    -- SHIFT CALENDAR ROUTINE
    ----------------------------
    BEGIN
        -- Call without date params (dynamic calculation inside)
        CALL application_data.sp_shift_calendar(
            v_filtered_list,
            p_user_id,
            p_user_fullname
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN
            INSERT INTO application_data.log_error(
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'NON-CRITICAL in shift_calendar → '||SQLERRM,
                lp_caller
            );
        ELSE
            INSERT INTO application_data.log_error(
                error_timestamp, error_src, error_msg, error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'CRITICAL in shift_calendar → '||SQLERRM,
                lp_caller
            );
            RAISE;
        END IF;
    END;


    ----------------------------------------------------------------------
    -- 5) Final log
    ----------------------------------------------------------------------
    INSERT INTO application_data.log_operation(
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'MASTER END – Executed for plants: '||v_filtered_list,
        lp_caller
    );

END;
$procedure$
;


-- DROP PROCEDURE application_data.sp_shift_calendar(varchar, int8, varchar, int4, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_shift_calendar(p_plant_filter character varying, p_user_id bigint, p_user_fullname character varying, p_interval_val integer DEFAULT 7, p_interval_unit character varying DEFAULT 'days'::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name varchar(100) := 'application_data.sp_shift_calendar';
    lp_caller         varchar(200);
    
    v_filter          varchar;
    v_code            varchar;
    v_timezone        varchar;
    
    -- Variables for dynamic date calculation
    v_calc_day_from   integer;
    v_calc_day_to     integer;
    v_local_now       timestamp;
    
    -- Variable for the interval
    v_dynamic_interval interval; 

BEGIN
    -- Build caller info
    lp_caller := p_user_id::text || ' -- ' || p_user_fullname;

    -- Log Start
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [Filter=' || COALESCE(p_plant_filter,'NULL') ||
        ', Interval=' || p_interval_val::text || ' ' || p_interval_unit || ']',
        lp_caller
    );

    -- Validate Unit
    IF lower(p_interval_unit) NOT IN ('day', 'days', 'week', 'weeks', 'month', 'months', 'year', 'years') THEN
        RAISE EXCEPTION 'Invalid interval unit: %. Allowed: days, weeks, months, years.', p_interval_unit;
    END IF;

    -- Build Interval
    v_dynamic_interval := (p_interval_val::text || ' ' || p_interval_unit)::interval;

    -- Normalize Filter
    v_filter := trim(both ' ' from replace(coalesce(p_plant_filter, ''),'''', ''));
    IF v_filter = '' THEN v_filter := 'ALL'; END IF;

    ----------------------------------------------------------------------
    -- CASE 1: ALL (Scheduled / Global)
    ----------------------------------------------------------------------
    IF upper(v_filter) = 'ALL' THEN
        FOR v_code, v_timezone IN
            SELECT plant_code, plant_timezone
            FROM application_data.lk_plant
            WHERE is_active = TRUE AND is_deleted = FALSE
            ORDER BY plant_code
        LOOP
            BEGIN
                -- 🕒 Dynamic Calculation
                v_local_now := now() AT TIME ZONE v_timezone;
                v_calc_day_from := to_char(v_local_now, 'YYYYMMDD')::integer;
                v_calc_day_to   := to_char(v_local_now + v_dynamic_interval, 'YYYYMMDD')::integer;

                CALL application_data.sp_shift_calendar_single(
                    v_code, v_calc_day_from, v_calc_day_to, p_user_id, p_user_fullname
                );

            EXCEPTION
                WHEN OTHERS THEN
                    -- 🛡️ EXCEPTION HANDLING RESTORED
                    IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN
                        -- Non-Critical Data Errors (e.g., specific plant logic fail). Log and Continue.
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'NON-CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        CONTINUE;

                    ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR 
                          SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR 
                          SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN
                        -- Critical System Errors (e.g., DB Shutdown, Connection Loss). Log and Stop.
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE; -- Stop execution

                    ELSE
                        -- Generic Errors. Log and Stop.
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'GENERIC ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE; -- Stop execution
                    END IF;
            END;
        END LOOP;
        RETURN;
    END IF;

    ----------------------------------------------------------------------
    -- CASE 2: LIST (Triggered by Master Scheduler)
    ----------------------------------------------------------------------
    IF v_filter LIKE '%,%' THEN
        FOR v_code IN
            SELECT trim(both ' ' FROM regexp_split_to_table(v_filter, ','))
        LOOP
            BEGIN
                -- 1. Get Timezone
                SELECT plant_timezone INTO v_timezone 
                FROM application_data.lk_plant WHERE plant_code = v_code;

                IF v_timezone IS NULL THEN v_timezone := 'UTC'; END IF;

                -- 2. 🕒 Dynamic Calculation
                v_local_now := now() AT TIME ZONE v_timezone;
                v_calc_day_from := to_char(v_local_now, 'YYYYMMDD')::integer;
                v_calc_day_to   := to_char(v_local_now + v_dynamic_interval, 'YYYYMMDD')::integer;

                -- 3. Execute
                CALL application_data.sp_shift_calendar_single(
                    v_code, v_calc_day_from, v_calc_day_to, p_user_id, p_user_fullname
                );

            EXCEPTION
                WHEN OTHERS THEN
                    -- 🛡️ EXCEPTION HANDLING RESTORED
                    IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'NON-CRITICAL LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        CONTINUE;

                    ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR 
                          SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR 
                          SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'CRITICAL LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    ELSE
                        INSERT INTO application_data.log_error (
                            error_timestamp, error_src, error_msg, error_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'GENERIC LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;
                    END IF;
            END;
        END LOOP;
        RETURN;
    END IF;

    ----------------------------------------------------------------------
    -- CASE 3: SINGLE
    ----------------------------------------------------------------------
    BEGIN
        v_code := trim(both ' ' FROM v_filter);
        
        SELECT plant_timezone INTO v_timezone 
        FROM application_data.lk_plant WHERE plant_code = v_code;

        IF v_timezone IS NULL THEN v_timezone := 'UTC'; END IF;

        -- 🕒 Dynamic Calculation
        v_local_now := now() AT TIME ZONE v_timezone;
        v_calc_day_from := to_char(v_local_now, 'YYYYMMDD')::integer;
        v_calc_day_to   := to_char(v_local_now + v_dynamic_interval, 'YYYYMMDD')::integer;

        CALL application_data.sp_shift_calendar_single(
            v_code, v_calc_day_from, v_calc_day_to, p_user_id, p_user_fullname
        );

    EXCEPTION
        WHEN OTHERS THEN
            -- 🛡️ EXCEPTION HANDLING RESTORED
            IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'NON-CRITICAL SINGLE → plant='||v_code||' → '||SQLERRM,
                    lp_caller
                );
                -- For single execution, we just log and exit gracefully if non-critical
                RETURN;

            ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR 
                  SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR 
                  SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'CRITICAL SINGLE → plant='||v_code||' → '||SQLERRM,
                    lp_caller
                );
                RAISE;

            ELSE
                INSERT INTO application_data.log_error (
                    error_timestamp, error_src, error_msg, error_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'GENERIC SINGLE → plant='||v_code||' → '||SQLERRM,
                    lp_caller
                );
                RAISE;
            END IF;
    END;

END;
$procedure$
;


-- DROP PROCEDURE application_data.sp_shift_calendar_single(varchar, int4, int4, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_shift_calendar_single(p_plant_code character varying, p_day_from integer, p_day_to integer, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name   varchar(100) := 'application_data.sp_shift_calendar_single';
    lp_err_msg          varchar(2000);
    lp_step             numeric := 0;
    lp_last_user        varchar;

    v_plant_id          bigint;
    v_plant_timezone    varchar;

    v_tmp_table         text;               -- NEW: dynamic table name
    v_pid               int := pg_backend_pid();   -- session identifier

	v_out_flag varchar := NULL ;
BEGIN
    lp_step := 0;
    lp_last_user := p_user_id::text || ' -- ' || p_user_fullname;

    ------------------------------------------------------------------
    -- Validate user identity
    ------------------------------------------------------------------
    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID and Fullname cannot be NULL';
    END IF;

    ------------------------------------------------------------------
    -- STEP 1: Resolve plant_id and timezone
    ------------------------------------------------------------------
    lp_step := 1;

    SELECT plant_id, plant_timezone
    INTO   v_plant_id, v_plant_timezone
    FROM   application_data.lk_plant
    WHERE  plant_code = p_plant_code
      AND  is_active = TRUE
      AND  is_deleted = FALSE;

    IF v_plant_id IS NULL THEN
        RAISE EXCEPTION 'Invalid plant_code: %', p_plant_code;
    END IF;

    ------------------------------------------------------------------
    -- Log input
    ------------------------------------------------------------------
    lp_step := 2;

    INSERT INTO application_data.log_operation(
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: plant_code='||p_plant_code||
        ', plant_id='||v_plant_id||
        ', day_from='||p_day_from||
        ', day_to='||p_day_to,
        lp_last_user
    );

    ------------------------------------------------------------------
    -- STEP 3: CREATE TEMP TABLE WITH UNIQUE NAME
    ------------------------------------------------------------------
    lp_step := 3;

    v_tmp_table := format(
        'tmp_line_calendar_new_%s_%s',
        v_plant_id,
        v_pid
    );

    -- Drop previous table if exists in this session
    EXECUTE format('DROP TABLE IF EXISTS %I;', v_tmp_table);

    -- Create new temp table
    EXECUTE format($DDL$
        CREATE TEMP TABLE %I (
            plant_id             bigint,
            line_id              bigint,
            day_id               integer,
            def_pattern_id       bigint,
            pattern_id           bigint,
            shift_id             bigint,
            shift_sort           integer,
            shift_start_dt       timestamp,
            shift_end_dt         timestamp,
            is_no_working_day    integer,
            is_holiday           integer,
            is_scheduled_to_run  integer,
            shift_number         integer,
            working_duration_sec numeric(20,5),
            au_user_id           bigint,
            au_change_type       varchar(10),
            au_change_num        bigint,
            au_change_day_id     integer,
            au_change_ts         timestamp,
            is_modify            integer,
            shift_start_dt_utc   timestamp,
            shift_end_dt_utc     timestamp,
            day_id_utc           integer
        ) ON COMMIT DROP;
    $DDL$, v_tmp_table);

    ------------------------------------------------------------------
    -- STEP 4: Populate dynamic temp table
    ------------------------------------------------------------------
    lp_step := 4;

    EXECUTE format($INS$
        INSERT INTO %I (
            plant_id, line_id, day_id, def_pattern_id, pattern_id,
            shift_id, shift_sort, shift_start_dt, shift_end_dt,
            is_no_working_day, is_holiday, is_scheduled_to_run,
            shift_number, working_duration_sec, au_user_id,
            au_change_type, au_change_num, au_change_day_id,
            au_change_ts, is_modify, shift_start_dt_utc,
            shift_end_dt_utc, day_id_utc
        )
        SELECT
            l.plant_id,
            l.line_id,
            d.id_day::integer,
            lp.pattern_id,
            lp.pattern_id,
            s.shift_id,
            COALESCE(m.shift_sort,0),

            /* LOCAL START */
            to_timestamp(
                to_char(
                    (to_date(d.id_day::text,'YYYYMMDD') + s.start_time_offset),
                    'YYYYMMDD'
                ) || s.start_time_desc,
                'YYYYMMDDHH24:MI'
            ),

            /* LOCAL END */
            to_timestamp(
                to_char(
                    (to_date(d.id_day::text,'YYYYMMDD') + s.end_time_offset),
                    'YYYYMMDD'
                ) || s.end_time_desc,
                'YYYYMMDDHH24:MI'
            ),

            0, 0, 1, 1,
            COALESCE(s.duration_ss,0)::numeric(20,5),
            %L,
			NULL, 
			NULL,
			to_char(timezone('UTC', current_timestamp),'YYYYMMDD')::INT,
            timezone('UTC', current_timestamp),
            lp.is_modify,

            /* UTC START */
            (
                to_timestamp(
                    to_char(
                        (to_date(d.id_day::text,'YYYYMMDD') + s.start_time_offset),
                        'YYYYMMDD'
                    ) || s.start_time_desc,
                    'YYYYMMDDHH24:MI'
                ) AT TIME ZONE %L
            )::timestamp,

            /* UTC END */
            (
                to_timestamp(
                    to_char(
                        (to_date(d.id_day::text,'YYYYMMDD') + s.end_time_offset),
                        'YYYYMMDD'
                    ) || s.end_time_desc,
                    'YYYYMMDDHH24:MI'
                ) AT TIME ZONE %L
            )::timestamp,

            /* UTC DAY ID */
            to_char(
                (
                    to_timestamp(
                        to_char(
                            (to_date(d.id_day::text,'YYYYMMDD') + s.start_time_offset),
                            'YYYYMMDD'
                        ) || s.start_time_desc,
                        'YYYYMMDDHH24:MI'
                    ) AT TIME ZONE %L
                ),
                'YYYYMMDD'
            )::integer

        FROM application_data.lk_line l
        JOIN application_data.sh_lk_line_pattern_default lp
              ON lp.plant_id = l.plant_id
             AND lp.line_id  = l.line_id
        JOIN application_data.lk_date d
              ON d.id_day BETWEEN %s AND %s
             AND d.id_weekday = lp.week_day_id
        LEFT JOIN application_data.sh_map_pattern_shift m
              ON m.pattern_id = lp.pattern_id
             AND m.plant_id   = lp.plant_id
        LEFT JOIN application_data.sh_lk_shift_definition sd
              ON sd.shift_def_id = m.shift_def_id
             AND sd.plant_id     = m.plant_id
             AND sd.is_deleted   = 0
        LEFT JOIN application_data.sh_lk_shift s
              ON s.shift_src_id  = sd.shift_def_id
             AND s.plant_id      = sd.plant_id
             AND s.is_deleted    = 0
        WHERE
            l.plant_id   = %s
            AND l.is_active  = TRUE
            AND l.is_deleted = FALSE
            AND s.shift_id IS NOT NULL
    $INS$, v_tmp_table, p_user_id, v_plant_timezone, v_plant_timezone, v_plant_timezone,
          p_day_from, p_day_to, v_plant_id);

    ------------------------------------------------------------------
    -- STEP 5: UPSERT
    ------------------------------------------------------------------
    lp_step := 5;

    EXECUTE format($UP$
        INSERT INTO application_data.sh_lk_line_calendar AS c (
            plant_id, line_id, day_id, def_pattern_id, pattern_id,
            shift_id, shift_sort, shift_start_dt, shift_end_dt,
            is_no_working_day, is_holiday, is_scheduled_to_run,
            shift_number, working_duration_sec, au_user_id,
            au_change_type, au_change_num, au_change_day_id,
            au_change_ts, is_modify, shift_start_dt_utc,
            shift_end_dt_utc, day_id_utc
        )
        SELECT * FROM %I
        ON CONFLICT (plant_id, line_id, day_id, shift_id)
        DO UPDATE SET
            def_pattern_id       = EXCLUDED.def_pattern_id,
            pattern_id           = EXCLUDED.pattern_id,
            shift_sort           = EXCLUDED.shift_sort,
            shift_start_dt       = EXCLUDED.shift_start_dt,
            shift_end_dt         = EXCLUDED.shift_end_dt,
            shift_number         = EXCLUDED.shift_number,
            working_duration_sec = EXCLUDED.working_duration_sec,
            is_modify            = EXCLUDED.is_modify,
            shift_start_dt_utc   = EXCLUDED.shift_start_dt_utc,
            shift_end_dt_utc     = EXCLUDED.shift_end_dt_utc,
            day_id_utc           = EXCLUDED.day_id_utc,
        	au_change_day_id 	 = EXCLUDED.au_change_day_id,
        	au_change_ts		 = EXCLUDED.au_change_ts
        WHERE
               c.def_pattern_id       IS DISTINCT FROM EXCLUDED.def_pattern_id
            OR c.pattern_id           IS DISTINCT FROM EXCLUDED.pattern_id
            OR c.shift_sort           IS DISTINCT FROM EXCLUDED.shift_sort
            OR c.shift_start_dt       IS DISTINCT FROM EXCLUDED.shift_start_dt
            OR c.shift_end_dt         IS DISTINCT FROM EXCLUDED.shift_end_dt
            OR c.shift_number         IS DISTINCT FROM EXCLUDED.shift_number
            OR c.working_duration_sec IS DISTINCT FROM EXCLUDED.working_duration_sec
            OR c.is_modify            IS DISTINCT FROM EXCLUDED.is_modify
            OR c.shift_start_dt_utc   IS DISTINCT FROM EXCLUDED.shift_start_dt_utc
            OR c.shift_end_dt_utc     IS DISTINCT FROM EXCLUDED.shift_end_dt_utc
            OR c.day_id_utc           IS DISTINCT FROM EXCLUDED.day_id_utc;
    $UP$, v_tmp_table);

    ------------------------------------------------------------------
    -- STEP 6: DELETE obsolete calendar rows
    ------------------------------------------------------------------
    lp_step := 6;

    EXECUTE format($DEL$
        DELETE FROM application_data.sh_lk_line_calendar c
        WHERE c.plant_id = %s
          AND c.day_id BETWEEN %s AND %s
          AND NOT EXISTS (
                SELECT 1
                FROM %I n
                WHERE n.plant_id = c.plant_id
                  AND n.line_id  = c.line_id
                  AND n.day_id   = c.day_id
                  AND n.shift_id = c.shift_id
          );
    $DEL$, v_plant_id, p_day_from, p_day_to, v_tmp_table);

------------------------------------------------------------------
-- STEP 7: Apply non-production-day updates (ROUTINE)
------------------------------------------------------------------
lp_step := 7;

CALL application_data.manage_lk_non_production_days(
    NULL,
    'ROUTINE',
    v_out_flag,
    v_plant_id,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    0,
    'ROUTINE'
);

------------------------------------------------------------------
-- STEP 8: sync lk_shift from sh_lk_line_calendar
------------------------------------------------------------------
lp_step := 8;

CALL application_data.sp_sync_lk_shift_from_calendar(v_plant_id, p_user_id, p_user_fullname);
------------------------------------------------------------------
-- STEP 9: Final log
------------------------------------------------------------------
INSERT INTO application_data.log_operation(
    operation_timestamp, operation_src, operation_msg, operation_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    'Completed: plant='||p_plant_code||
    ' ('||v_plant_id||') from '||p_day_from||' to '||p_day_to,
    lp_last_user
);


EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg :=
            'ERROR: ' || SQLERRM ||
            ', SQLSTATE: ' || SQLSTATE ||
            ', lp_step: ' || lp_step;

        INSERT INTO application_data.log_error(
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_last_user
        );

        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.sp_shift_manage(varchar, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_shift_manage(p_plant_code_list character varying, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name varchar(100) := 'application_data.sp_shift_manage';
    lp_caller         varchar(200);
    lp_err_msg        varchar(2000);
    lp_now_utc        timestamp;

    v_code            varchar(100);
    v_plant_code_list varchar := p_plant_code_list;
BEGIN
    lp_now_utc := timezone('UTC', current_timestamp);
    lp_caller  := p_user_id::text || ' -- ' || p_user_fullname;

    ----------------------------------------------------------------------
    -- INITIAL LOG
    ----------------------------------------------------------------------
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        lp_now_utc,
        lp_procedure_name,
        'Input: [p_plant_code_list=' || COALESCE(p_plant_code_list,'NULL') ||
        ', p_user_id=' || COALESCE(p_user_id::text,'NULL') ||
        ', p_user_fullname=' || COALESCE(p_user_fullname,'NULL') || ']',
        lp_caller
    );

    ----------------------------------------------------------------------
    -- CASE 1: ALL
    ----------------------------------------------------------------------
    IF upper(trim(p_plant_code_list)) = 'ALL' THEN

        FOR v_code IN
            SELECT plant_code
            FROM application_data.lk_plant
            WHERE is_active = TRUE
              AND is_deleted = FALSE
            ORDER BY plant_code
        LOOP
            BEGIN
                CALL application_data.sp_shift_manage_single(
                    v_code,
                    p_user_id,
                    p_user_fullname
                );

            EXCEPTION
                WHEN OTHERS THEN

                    IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'NON-CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        CONTINUE;

                    ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR
                          SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR
                          SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    ELSE
                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'GENERIC ALL → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    END IF;

            END;

        END LOOP;

        v_plant_code_list := 'ALL_DONE';
        RETURN;
    END IF;


    ----------------------------------------------------------------------
    -- CASE 2: LIST
    ----------------------------------------------------------------------
    IF p_plant_code_list LIKE '%,%' THEN

        FOR v_code IN
            SELECT trim(both ' ' FROM regexp_split_to_table(p_plant_code_list, ','))
        LOOP
            BEGIN
                CALL application_data.sp_shift_manage_single(
                    v_code,
                    p_user_id,
                    p_user_fullname
                );

            EXCEPTION
                WHEN OTHERS THEN

                    IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'NON-CRITICAL LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        CONTINUE;

                    ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR
                          SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR
                          SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'CRITICAL LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    ELSE

                        INSERT INTO application_data.log_error (
                            error_timestamp,
                            error_src,
                            error_msg,
                            error_caller
                        ) VALUES (
                            lp_now_utc,
                            lp_procedure_name,
                            'GENERIC LIST → plant='||v_code||' → '||SQLERRM,
                            lp_caller
                        );
                        RAISE;

                    END IF;

            END;

        END LOOP;

        v_plant_code_list := 'LIST_DONE';
        RETURN;
    END IF;


    ----------------------------------------------------------------------
    -- CASE 3: SINGLE
    ----------------------------------------------------------------------
    BEGIN

        CALL application_data.sp_shift_manage_single(
            trim(both ' ' FROM p_plant_code_list),
            p_user_id,
            p_user_fullname
        );

    EXCEPTION
        WHEN OTHERS THEN

            IF SQLSTATE LIKE '22%' OR SQLSTATE LIKE '23%' OR SQLSTATE = 'P0001' THEN

                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    lp_now_utc,
                    lp_procedure_name,
                    'NON-CRITICAL SINGLE → plant='||p_plant_code_list||' → '||SQLERRM,
                    lp_caller
                );
                RETURN;

            ELSIF SQLSTATE LIKE '57P%' OR SQLSTATE LIKE '58%' OR
                  SQLSTATE LIKE '08%' OR SQLSTATE LIKE '53%' OR
                  SQLSTATE LIKE '40%' OR SQLSTATE LIKE 'XX%' THEN

                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    lp_now_utc,
                    lp_procedure_name,
                    'CRITICAL SINGLE → plant='||p_plant_code_list||' → '||SQLERRM,
                    lp_caller
                );
                RAISE;

            ELSE

                INSERT INTO application_data.log_error (
                    error_timestamp,
                    error_src,
                    error_msg,
                    error_caller
                ) VALUES (
                    lp_now_utc,
                    lp_procedure_name,
                    'GENERIC SINGLE → plant='||p_plant_code_list||' → '||SQLERRM,
                    lp_caller
                );
                RAISE;

            END IF;

    END;

    v_plant_code_list := p_plant_code_list || '_DONE';
    RETURN;

END;
$procedure$
;

-- DROP PROCEDURE application_data.sp_shift_manage_single(varchar, int8, varchar);

CREATE OR REPLACE PROCEDURE application_data.sp_shift_manage_single(p_plant_code character varying, p_user_id bigint, p_user_fullname character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_procedure_name varchar(100) := 'application_data.sp_shift_manage_single';
    lp_err_msg        varchar(2000);
    lp_step           int := 0;
    lp_caller         varchar(200);
    lp_now_utc        timestamp;

    v_plant_id        bigint;

    v_cnt_step1 bigint := 0;
    v_cnt_step2 bigint := 0;
    v_cnt_step3 bigint := 0;
BEGIN
    lp_now_utc := timezone('UTC', current_timestamp);
    lp_caller  := p_user_id::text || ' -- ' || p_user_fullname;

    ----------------------------------------------------------------------
    -- Input log
    ----------------------------------------------------------------------
    INSERT INTO application_data.log_operation(
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_now_utc,
        lp_procedure_name,
        'Input: [plant_code=' || COALESCE(p_plant_code,'NULL') || ']',
        lp_caller
    );

    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        RAISE EXCEPTION 'User ID or fullname cannot be NULL';
    END IF;

    ----------------------------------------------------------------------
    -- Resolve plant_id from plant_code
    ----------------------------------------------------------------------
    SELECT plant_id
    INTO v_plant_id
    FROM application_data.lk_plant
    WHERE plant_code = p_plant_code
      AND is_deleted = false
      AND is_active  = true;

    IF v_plant_id IS NULL THEN
        RAISE EXCEPTION 'Invalid plant_code: %', p_plant_code;
    END IF;

    ----------------------------------------------------------------------
    -- STEP 1 — Mark deleted shifts
    ----------------------------------------------------------------------
    lp_step := 1;

    WITH deleted_defs AS (
        SELECT s.shift_id
        FROM application_data.sh_lk_shift s
        LEFT JOIN application_data.sh_lk_shift_definition d
               ON d.plant_id     = s.plant_id
              AND d.shift_def_id = s.shift_src_id
        WHERE s.plant_id = v_plant_id
          AND d.shift_def_id IS NULL
		  AND s.au_change_type<>'DEL'
    )
    UPDATE application_data.sh_lk_shift s
    SET
        shift_cd         = s.shift_id::text || '***' || s.shift_cd,
        au_user_id       = p_user_id,
        au_change_type   = 'DEL',
        au_change_num    = COALESCE(s.au_change_num,0) + 1,
        au_change_day_id = EXTRACT(doy FROM lp_now_utc)::int,
        au_change_ts     = lp_now_utc
    FROM deleted_defs dd
    WHERE s.shift_id = dd.shift_id
      AND s.plant_id = v_plant_id;

    GET DIAGNOSTICS v_cnt_step1 = ROW_COUNT;

    INSERT INTO application_data.log_operation (operation_timestamp, operation_src, operation_msg, operation_caller) VALUES (
        lp_now_utc,
        lp_procedure_name,
        'STEP 1 - Mark deleted shifts: ' || v_cnt_step1,
        lp_caller
    );

    ----------------------------------------------------------------------
    -- STEP 2 — Update shifts changed in definition
    ----------------------------------------------------------------------
    lp_step := 2;

    UPDATE application_data.sh_lk_shift s
    SET
        shift_cd         = d.shift_def_cd,
        shift_short_cd   = d.shift_def_short_cd,
        shift_ds         = d.shift_def_ds,
        start_time_desc  = d.start_time_desc,
        start_time_offset= d.start_time_offset,
        end_time_desc    = d.end_time_desc,
        end_time_offset  = d.end_time_offset,
        duration_ss      = d.duration_ss,
        is_deleted       = 0,
        au_user_id       = p_user_id,
        au_change_type   = 'UPD',
        au_change_num    = COALESCE(s.au_change_num,0) + 1,
        au_change_day_id = EXTRACT(doy FROM lp_now_utc)::int,
        au_change_ts     = lp_now_utc
    FROM application_data.sh_lk_shift_definition d
    WHERE s.plant_id = v_plant_id
      AND d.plant_id = s.plant_id
      AND d.shift_def_id = s.shift_src_id
      AND (
            s.shift_cd          IS DISTINCT FROM d.shift_def_cd OR
            s.shift_short_cd    IS DISTINCT FROM d.shift_def_short_cd OR
            s.shift_ds          IS DISTINCT FROM d.shift_def_ds OR
            s.start_time_desc   IS DISTINCT FROM d.start_time_desc OR
            s.start_time_offset IS DISTINCT FROM d.start_time_offset OR
            s.end_time_desc     IS DISTINCT FROM d.end_time_desc OR
            s.end_time_offset   IS DISTINCT FROM d.end_time_offset OR
            s.duration_ss       IS DISTINCT FROM d.duration_ss
      );

    GET DIAGNOSTICS v_cnt_step2 = ROW_COUNT;

    INSERT INTO application_data.log_operation (operation_timestamp, operation_src, operation_msg, operation_caller) VALUES (
        lp_now_utc,
        lp_procedure_name,
        'STEP 2 - Sync updated shifts: ' || v_cnt_step2,
        lp_caller
    );

    ----------------------------------------------------------------------
    -- STEP 3 — Insert new shifts not present in sh_lk_shift
    ----------------------------------------------------------------------
    lp_step := 3;

    INSERT INTO application_data.sh_lk_shift(
        plant_id, shift_cd, shift_short_cd, shift_ds,
        start_time_desc, start_time_offset,
        end_time_desc, end_time_offset,
        duration_ss, is_deleted,
        au_user_id, au_change_type, au_change_num, au_change_day_id, au_change_ts,
        shift_src_id
    )
    SELECT
        d.plant_id,
        d.shift_def_cd,
        d.shift_def_short_cd,
        d.shift_def_ds,
        d.start_time_desc,
        d.start_time_offset,
        d.end_time_desc,
        d.end_time_offset,
        d.duration_ss,
        0,
        p_user_id,
        'INS',
        1,
        EXTRACT(doy FROM lp_now_utc)::int,
        lp_now_utc,
        d.shift_def_id
    FROM application_data.sh_lk_shift_definition d
    LEFT JOIN application_data.sh_lk_shift s
           ON s.plant_id = d.plant_id
          AND s.shift_src_id = d.shift_def_id
    WHERE d.plant_id = v_plant_id
      AND d.is_deleted = 0
      AND s.shift_id IS NULL;

    GET DIAGNOSTICS v_cnt_step3 = ROW_COUNT;

    INSERT INTO application_data.log_operation (operation_timestamp, operation_src, operation_msg, operation_caller) VALUES (
        lp_now_utc,
        lp_procedure_name,
        'STEP 3 - Insert new shifts: ' || v_cnt_step3,
        lp_caller
    );

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR [' || lp_procedure_name || '] step=' || lp_step ||
                      ' plant=' || COALESCE(p_plant_code,'NULL') ||
                      ' msg=' || SQLERRM || ' state=' || SQLSTATE;

        INSERT INTO application_data.log_error (error_timestamp, error_src, error_msg, error_caller) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            lp_caller
        );

        RAISE;
END;
$procedure$
;


-- DROP PROCEDURE application_data.manage_lk_non_production_days(in int8, in varchar, inout varchar, in int8, in int8, in int4, in varchar, in int4, in int4, in int4, in int8, in varchar);

CREATE OR REPLACE PROCEDURE application_data.manage_lk_non_production_days(p_non_production_id bigint, operation_type character varying, INOUT out_flag character varying, p_plant_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_non_working_id integer DEFAULT NULL::integer, p_reason character varying DEFAULT NULL::character varying, p_is_scheduled_to_run integer DEFAULT 0, p_is_holiday integer DEFAULT 0, p_is_no_working_day integer DEFAULT 1, p_user_id bigint DEFAULT NULL::bigint, p_user_fullname character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    lp_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_lk_non_production_days';
    lp_err_msg VARCHAR(2000);
    lp_line_plant BIGINT;
	lp_line_id INTEGER;
	lp_year INTEGER;
	lp_non_working_datetime TIMESTAMP;
	lp_plant_id INTEGER;
	lp_non_working_day_id INTEGER;
	lp_execution_timestamp TIMESTAMP;
cur_no_prod_day CURSOR FOR
SELECT
	npd.non_production_id,
	npd.plant_id,
	p.plant_timezone,
	npd.line_id,
	npd.non_working_day_id,
	npd.is_holiday,
	npd.is_scheduled_to_run,
	npd.is_no_working_day
FROM application_data.lk_non_production_days npd
INNER JOIN 	application_data.lk_plant p on p.plant_id=npd.plant_id 
where npd.plant_id=p_plant_id 
and "year" = extract (year from current_timestamp AT TIME ZONE p.plant_timezone);


rec RECORD;

BEGIN
lp_execution_timestamp := timezone('UTC', current_timestamp);

lp_non_working_day_id := null; 

	lp_step := 10;
    
    -- Log operation
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || operation_type || 
			', p_non_production_id: ' || COALESCE(p_non_production_id::text, 'NULL') || 
            ', p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || 
            ', p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || 
            ', p_non_working_id: ' || COALESCE(p_non_working_id::text, 'NULL') || 
            ', p_reason: ' || COALESCE(p_reason, 'NULL') || 
            ', p_is_holiday: ' || COALESCE(p_is_holiday::text, 'NULL') || 
            ', p_is_scheduled_to_run: ' || COALESCE(p_is_scheduled_to_run::text, 'NULL') || 
            ', p_is_no_working_day: ' || COALESCE(p_is_no_working_day::text, 'NULL') || 
            ', p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || 
            ', p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']',
        p_user_id::text || ' -- ' || p_user_fullname
    );

    -- Check whether user information is provided and whether the operation type is other than "routine" which is performed automatically after the shift talend job is performed
   IF operation_type NOT IN ('ROUTINE') THEN
   BEGIN
	 lp_step := 20;
    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        lp_err_msg := 'User fullname and ID cannot be null.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_user := p_user_id::text || ' -- ' || p_user_fullname;

    -- Ensure required parameters are not null
    IF ( (p_plant_id IS NULL OR p_line_id IS NULL OR p_non_working_id IS NULL ) AND (operation_type IN ('I','U') ) ) THEN
        lp_err_msg := 'Plant ID, Line ID, and Non-Working Date must be set.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

	-- extract year from p_non_working_id
	 lp_step := 30;
	SELECT substring((p_non_working_id::varchar),1,4)::integer into lp_year;
	SELECT to_timestamp(p_non_working_id::text, 'YYYYMMDD')::timestamp into lp_non_working_datetime;

	SELECT non_working_day_id into lp_non_working_day_id 
	FROM application_data.lk_non_production_days 
	WHERE non_production_id = p_non_production_id;

	raise notice 'lp_non_working_day_id, %,',lp_non_working_day_id;

    -- Validate that line belongs to the specified plant
    IF ( p_line_id IS NOT NULL ) THEN
        lp_step := 40;
        SELECT line_id, plant_id INTO lp_line_id,lp_plant_id
        FROM application_data.lk_line
        WHERE line_id = p_line_id;

      	lp_step := 50;
        IF ( lp_line_plant <> p_plant_id  AND (operation_type IN ('I','U') ) ) THEN
            lp_err_msg := 'The line does not belong to the specified plant.';
            RAISE EXCEPTION '%', lp_err_msg;
        END IF;
    END IF;
	
	
    -- Main CASE block to handle different operation types
    CASE operation_type
        WHEN 'I' THEN
            -- Insert operation
            lp_step := 60;
            INSERT INTO application_data.lk_non_production_days (
                plant_id,
                line_id,
                year,
				non_working_date,
                non_working_day_id,
                reason,
                is_holiday,
                is_scheduled_to_run,
                is_no_working_day,
				creator_user,
				last_user
            ) VALUES (
                lp_plant_id,
                lp_line_id,
               	lp_year,
				lp_non_working_datetime,
                p_non_working_id,
                case when p_reason is null then null end,
                p_is_holiday,
                p_is_scheduled_to_run,
                p_is_no_working_day,
				lp_user,
				lp_user
            );

        WHEN 'U' THEN
            -- Update operation
            lp_step := 70;
            UPDATE application_data.lk_non_production_days
            SET 
                reason = p_reason,
                is_holiday = p_is_holiday,
              	is_scheduled_to_run = p_is_scheduled_to_run,
                is_no_working_day = p_is_no_working_day,
				non_working_day_id = p_non_working_id,
				non_working_date = lp_non_working_datetime,
				line_id = lp_line_id,
				plant_id=lp_plant_id,
				year =lp_year,
				last_user=lp_user,
				last_modified=(CURRENT_TIMESTAMP AT TIME ZONE 'utc')
            WHERE non_production_id = p_non_production_id;

        WHEN 'D' THEN
            -- Physical delete operation
            lp_step := 80;
            DELETE FROM application_data.lk_non_production_days WHERE non_production_id = p_non_production_id;

        ELSE
            -- Invalid operation type
            lp_err_msg := 'Invalid operation type';
            RAISE EXCEPTION '%', lp_err_msg;
    END CASE;

      -- if exist a record with the same plant_id, line_id and day_id in sh_lk_line_calendar table
	  -- then I'll update all the flag columns with the value set in the lk_non_production_days
	  lp_step := 90;	
	 
		PERFORM 1
	 	FROM application_data.sh_lk_line_calendar
      	WHERE plant_id=lp_plant_id
		AND line_id=lp_line_id
		AND day_id in (p_non_working_id,lp_non_working_day_id);
 	  lp_step := 100;
	  IF FOUND THEN 
		CASE WHEN operation_type IN ('I', 'U') THEN
				
				-- update all shift in "sh_lk_line_calendar" table for the day set as "no working day" 
	            UPDATE application_data.sh_lk_line_calendar
				SET is_holiday=p_is_holiday,
					is_scheduled_to_run=p_is_scheduled_to_run,
					is_no_working_day=p_is_no_working_day
				WHERE
	 			plant_id=lp_plant_id
				AND line_id=lp_line_id
				AND day_id=p_non_working_id;
				
				IF operation_type IN ('U') THEN
					-- update all shift in "sh_lk_line_calendar" table for the previous day set as "no working day". Previous refers to the "non working day id" saved in the table 
					-- "lk_non_production_days" before last update
					UPDATE application_data.sh_lk_line_calendar
					SET is_holiday=0,
						is_scheduled_to_run=0,
						is_no_working_day=0
					WHERE
		 			plant_id=lp_plant_id
					AND line_id=lp_line_id
					AND day_id=lp_non_working_day_id;

				END IF; 

		 WHEN operation_type IN ('D') THEN
				UPDATE application_data.sh_lk_line_calendar
				SET is_holiday=0,
					is_scheduled_to_run=0,
					is_no_working_day=0
				WHERE
	 			plant_id=lp_plant_id
				AND line_id=lp_line_id
				AND day_id=lp_non_working_day_id;
		 END CASE;
      END IF;
 END; --this is the end of "BEGIN" inside the main IF
ELSE 
-- this is the code executed when the operation type is "ROUTINE"
BEGIN
    -- Open the cursor
    OPEN cur_no_prod_day;

    -- Loop through each row in the cursor
    LOOP
        -- Fetch each row into the record variable
        FETCH cur_no_prod_day INTO rec;
        
        -- Exit the loop if no more rows are found
        EXIT WHEN NOT FOUND;

        -- Process each row here (use rec.non_working_day_id, rec.plant_id, rec.line_id)
		  UPDATE application_data.sh_lk_line_calendar
				SET is_holiday=rec.is_holiday,
					is_scheduled_to_run=rec.is_scheduled_to_run,
					is_no_working_day=rec.is_no_working_day
				WHERE
	 			plant_id= rec.plant_id
				AND line_id=rec.line_id
				AND day_id=rec.non_working_day_id;

     	   RAISE NOTICE 'non_working_day_id: %, plant_id: %, line_id: %',rec.non_working_day_id, rec.plant_id, rec.line_id;
		
    END LOOP;

    -- Close the cursor
    CLOSE cur_no_prod_day;
END;
END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log all exceptions and re-raise
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || 
                      ', Step: ' || lp_step::text || 
                      ', Input: [operation_type: ' || operation_type || 
					  ', p_non_production_id: ' || COALESCE(p_non_production_id::text, 'NULL') || 
                      ', p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || 
                      ', p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || 
                      ', p_non_working_id: ' || COALESCE(p_non_working_id::text, 'NULL') || 
                      ', p_reason: ' || COALESCE(p_reason, 'NULL') || 
                      ', p_is_holiday: ' || COALESCE(p_is_holiday::text, 'NULL') || 
                      ', p_is_scheduled_to_run: ' || COALESCE(p_is_scheduled_to_run::text, 'NULL') || 
                      ', p_is_no_working_day: ' || COALESCE(p_is_no_working_day::text, 'NULL') || 
                      ', p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || 
                      ', p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ']';
 	 out_flag := lp_err_msg;
 		begin
        -- Log the error
        INSERT INTO application_data.log_error (
            error_timestamp,
            error_src, 
            error_msg,
            error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            lp_err_msg,
            p_user_id::text || ' -- ' || p_user_fullname
        );
		end;
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_sh_line_pattern_default(varchar, int8, int8, int8, int8, int8, int8, int8, int8, int8, numeric);

CREATE OR REPLACE PROCEDURE application_data.manage_sh_line_pattern_default(operation_type character varying, p_plant_id bigint DEFAULT NULL::bigint, p_line_id bigint DEFAULT NULL::bigint, p_pattern_id_1 bigint DEFAULT NULL::bigint, p_pattern_id_2 bigint DEFAULT NULL::bigint, p_pattern_id_3 bigint DEFAULT NULL::bigint, p_pattern_id_4 bigint DEFAULT NULL::bigint, p_pattern_id_5 bigint DEFAULT NULL::bigint, p_pattern_id_6 bigint DEFAULT NULL::bigint, p_pattern_id_7 bigint DEFAULT NULL::bigint, p_au_user_id numeric DEFAULT NULL::numeric)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:		
-- @Company:    Decisyon
-- @Project:    DLMO
-- @Version:	
-- @Date:		
-- @ChangeHis:
--
-- @Description: 
-- Procedure to manage the association and definition between line and shift scheme, allowing its updating based on the value of the Operation_Type param.
-- 
--    Params:
--      - operation_type (character varying): The type of operation to be performed (CREATE, UPDATE, DELETE).
--      - p_plant_id 					: The ID of the plant.
--      - p_line_id 					: The ID of the line .
--      - p_pattern_1....p_pattern_7 	: The pattern to associate with the day of the week (1..7)
--      - p_au_user_id (numeric, DEFAULT NULL): The last user who modified the shift pattern.


-- ============================================================================================================
DECLARE 
    -- Params to log errors
    step 			numeric;
	procedure_name	varchar(50) := 'application_data.manage_sh_line_pattern_default';
	err_msg			varchar(2000);

begin 
    step := 0;
	IF p_au_user_id IS NULL THEN 
    	RAISE EXCEPTION 'au_user_id CANNOT BE NULL';
    END IF;
    
   	step := 0.1;
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC',current_timestamp),
        procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_plant_id: '  || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
            'p_line_id: '  || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_pattern_id_1: '  || COALESCE(p_pattern_id_1::text, 'NULL') || ', ' ||
            'p_pattern_id_2: '  || COALESCE(p_pattern_id_2::text, 'NULL') || ', ' ||
            'p_pattern_id_3: '  || COALESCE(p_pattern_id_3::text, 'NULL') || ', ' ||
            'p_pattern_id_4: '  || COALESCE(p_pattern_id_4::text, 'NULL') || ', ' ||
            'p_pattern_id_5: '  || COALESCE(p_pattern_id_5::text, 'NULL') || ', ' ||
            'p_pattern_id_6: '  || COALESCE(p_pattern_id_6::text, 'NULL') || ', ' ||
            'p_pattern_id_7: '  || COALESCE(p_pattern_id_7::text, 'NULL') || ', ' ||      
            'p_au_user_id: '  || COALESCE(p_au_user_id::text, 'NULL') || ', ' || ']',
            p_au_user_id::text
    );
    -- Main CASE block to handle different operation types
    CASE operation_type
        WHEN 'U' THEN
            -- Insert operation
            step := 1;
            -- Check if any required values are NULL
            IF (p_plant_id IS NULL OR p_line_id IS NULL 
                OR p_pattern_id_1 is NULL 
            	OR p_pattern_id_2 is null
            	OR p_pattern_id_3 is null
            	OR p_pattern_id_4 is null
            	OR p_pattern_id_5 is null
            	OR p_pattern_id_6 is null
            	OR p_pattern_id_7 is null) then
            -- RAISE EXCEPTION USING ERRCODE='DCY01', MESSAGE='ERROR VALUES CANNOT BE NULL';
            RAISE EXCEPTION 'ERROR VALUES CANNOT BE NULL';
            END IF;
         
           -- Update all the records into sh_lk_line_pattern_default for the line defined in the p_line_id parameter
         
           step := 1.1;
            UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_1,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=1;
           
			step := 1.2;
			UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_2,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=2;
		
      	    step := 1.3;
			UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_3,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=3;
		
		    step := 1.4;
			UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_4,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=4;
		
		    step := 1.5;
			UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_5,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=5;
		    
		    step := 1.6;
			UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_6,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=6;
		
		    step := 1.7;
			UPDATE application_data.sh_lk_line_pattern_default
			SET pattern_id=p_pattern_id_7,
			au_user_id=p_au_user_id,
			au_change_type=operation_type,
			au_change_num=0,
			au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
			au_change_ts=timezone('UTC',current_timestamp)
			where 
			plant_id=p_plant_id and 
			line_id=p_line_id and 
			week_day_id=7;
        ELSE
            -- Invalid operation type
            step := 2;
            RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';
    END CASE;
   
EXCEPTION
   -- WHEN  others or SQLSTATE 'DCY01' then
     WHEN  others then
        -- Catch all exceptions and log them
        err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
           'Step: ' || step::text || ', ' ||
           'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
           'p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
           'p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || ', ' ||
           'p_pattern_id_1: ' || COALESCE(p_pattern_id_1::text, 'NULL') || ', ' ||
           'p_pattern_id_2: ' || COALESCE(p_pattern_id_2::text, 'NULL') || ', ' ||
           'p_pattern_id_3: ' || COALESCE(p_pattern_id_3::text, 'NULL') || ', ' ||
           'p_pattern_id_4: ' || COALESCE(p_pattern_id_4::text, 'NULL') || ', ' ||
           'p_pattern_id_5: ' || COALESCE(p_pattern_id_5::text, 'NULL') || ', ' ||
           'p_pattern_id_6: ' || COALESCE(p_pattern_id_6::text, 'NULL') || ', ' ||
           'p_pattern_id_7: ' || COALESCE(p_pattern_id_7::text, 'NULL') || ', ' ||
           'p_au_user_id: ' || COALESCE(p_au_user_id::text, 'NULL') || ', ' ||
           'au_change_ts: ' || COALESCE(timezone('UTC',current_timestamp)::text, 'NULL') || ', ' ||']';
                 INSERT INTO application_data.log_error (
                error_timestamp,
                error_src, 
                error_msg,
                error_caller
            ) VALUES (
                timezone('UTC',current_timestamp),
                procedure_name,
                err_msg,
             	p_au_user_id::text
            );
        
END;
$procedure$
;

-- DROP PROCEDURE application_data.manage_sh_lk_pattern(varchar, int8, int8, varchar, varchar, numeric, bool, bool, bool, bool);

CREATE OR REPLACE PROCEDURE application_data.manage_sh_lk_pattern(operation_type character varying, p_plant_id bigint DEFAULT NULL::bigint, p_pattern_id bigint DEFAULT NULL::bigint, p_pattern_cd character varying DEFAULT NULL::character varying, p_pattern_ds character varying DEFAULT NULL::character varying, p_au_user_id numeric DEFAULT NULL::numeric, p_is_deleted boolean DEFAULT NULL::boolean, p_is_default boolean DEFAULT NULL::boolean, p_is_modify boolean DEFAULT NULL::boolean, p_is_active boolean DEFAULT NULL::boolean)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:		
-- @Company:    Decisyon
-- @Project:    DLMO
-- @Version:	
-- @Date:		
-- @ChangeHis:
--
-- @Description: 
--    Procedure to manage the shift pattern lookup table, allowing for create, update, and logical delete operations according
--      to the value of param operation_type.
-- 
--    Params:
--      - operation_type (character varying): The type of operation to be performed (CREATE, UPDATE, DELETE).
--      - p_plant_id (bigint, DEFAULT NULL): The ID of the plant.
--      - p_pattern_id (character varying, DEFAULT NULL): The ID of the shift pattern.
--      - p_pattern_cd (character varying, DEFAULT NULL): The code associate with the shift pattern.
--      - p_pattern_ds (character varying, DEFAULT NULL): The description of the shift pattern.
--      - p_au_user_id (numeric, DEFAULT NULL): The last user who modified the shift pattern.
--      - p_is_deleted (numeric, DEFAULT NULL): Indicator if the shift pattern is deleted.
--      - p_is_default (numeric, DEFAULT NULL): Indicator if the shift pattern is the default pattern.
--      - p_is_modify (numeric, DEFAULT NULL):Indicator if the shift pattern record has been changed.
--      - p_is_active (numeric, DEFAULT NULL): Indicator if the shift pattern is active.
-- ============================================================================================================
declare
-- Params to log errors
step numeric;

procedure_name varchar(50) := 'application_data.manage_sh_lk_pattern';

err_msg varchar(2000);

begin
	step := 0;

if p_au_user_id is null then 
    	raise exception 'au_user_id CANNOT BE NULL';
end if;
-- Log operation
step := 0.1;

insert
	into
	application_data.log_operation (
    operation_timestamp,
	operation_src,
	operation_msg,
	operation_caller
    )
values (
        timezone('UTC', current_timestamp),
        procedure_name,
        'Input: [operation_type: ' || coalesce(operation_type, 'NULL') || ', ' ||
            'p_plant_id: ' || coalesce(p_plant_id::text, 'NULL') || ', ' ||
            'p_pattern_id: ' || coalesce(p_pattern_id::text, 'NULL') || ', ' ||
            'p_pattern_cd: ' || coalesce(p_pattern_cd::text, 'NULL') || ', ' ||
            'p_pattern_ds: ' || coalesce(p_pattern_ds::text, 'NULL') || ', ' ||
            'p_au_user_id: ' || coalesce(p_au_user_id::text, 'NULL') || ', ' ||
            'p_is_deleted: ' || coalesce(p_is_deleted::text, 'NULL') || ', ' ||
            'p_is_default: ' || coalesce(p_is_default::text, 'NULL') ||
            'p_is_modify: ' || coalesce(p_is_modify::text, 'NULL') || ', ' ||
            'p_is_active: ' || coalesce(p_is_active::text, 'NULL') || ', ' || ']',
            p_au_user_id::text
    );
-- Main CASE block to handle different operation types
    case
	operation_type
        when 'I' then
	-- Insert operation
	step := 1;
-- Check if any required values are NULL
            if p_plant_id is null
				or p_pattern_cd is null
				or p_pattern_ds is null then
                raise exception 'ERROR VALUES CANNOT BE NULL TO INSERT A NEW PATTERN';
			end if;
-- Insert new record into lk_plant table
            insert
			into
			application_data.sh_lk_pattern (
		                plant_id,
						pattern_cd,
						pattern_ds,
						is_deleted,
						is_default,
						au_user_id,
						au_change_type,
						au_change_num,
						au_change_day_id,
						au_change_ts,
						is_modify,
						is_active
						
		            )
			values (
		                p_plant_id,
		           		p_pattern_cd,
		           		p_pattern_ds,
		           		0,
		           		p_is_default::int4,
		           		p_au_user_id,
		           		operation_type,
		           		null,
		           		to_number(to_char(timezone('UTC', current_timestamp), 'YYYYMMDD'), '99999999'),
		           		timezone('UTC', current_timestamp),
		           		1,
		           		p_is_active::int4
		           		
		            );
when 'U' then
-- Update operation
step := 2;
-- Check if the record is editable
            perform 1
			from
			application_data.sh_lk_pattern
			where
			plant_id = p_plant_id
			and pattern_id = p_pattern_id
			and is_modify = 0;

			if found then
			                raise exception 'ERROR IS_MODIFY CANNOT BE FALSE (ZERO)';
			end if;
-- Check if needed params are NULL
step := 2.1;

if p_au_user_id is null
	or p_plant_id is null
	or p_pattern_id is null then
	raise exception 'ERROR GIVEN PATTERN IS NULL';
end if;
-- Update the record in the sh_lk_pattern table
            update
			application_data.sh_lk_pattern
			set
			pattern_cd = coalesce(p_pattern_cd, pattern_cd),
			-- Update pattern_cd if provided
			pattern_ds = coalesce(p_pattern_ds, pattern_ds),
			-- Update pattern_ds if provided
			au_user_id = p_au_user_id,
			-- Update au_user_id
			is_active = coalesce(p_is_active::int4, is_active),
			-- Update is_active if provided
			is_modify = coalesce(p_is_modify::int4, is_modify),
			-- Update is_modify if provided
			is_default = coalesce(p_is_default::int4, is_default),
			-- Update is_default if provided
			au_change_type = coalesce(operation_type, au_change_type),
			-- Update au_change_type
			au_change_day_id = coalesce(to_number(to_char(timezone('UTC', current_timestamp), 'YYYYMMDD'), '99999999'), au_change_day_id),
			-- Update au_change_day
			au_change_ts = timezone('UTC', current_timestamp)
			-- Update au_change_ts
			where
			pattern_id = p_pattern_id
			and plant_id = p_plant_id;

when 'D' then
step := 3.0;

if 
	p_au_user_id is null
	or p_pattern_id is null then
	raise exception 'ERROR GIVEN PATTERN IS NULL';
end if;
-- Physical deletion operation  	
step := 3.1;

update
	application_data.sh_lk_pattern
set
	is_deleted = 1,
	au_user_id = p_au_user_id
	
where
	pattern_id = p_pattern_id;

step := 2.2;

delete
from
	application_data.sh_lk_pattern
where
	pattern_id = p_pattern_id;
else
-- Invalid operation type
            raise exception 'ERROR INVALID OPERATION_TYPE';
end case;

exception
when others then
-- Catch all exceptions and log them
err_msg := 'ERROR: ' || sqlerrm || ', SQLSTATE: ' || sqlstate || ', ' ||
           'Step: ' || step::text || ', ' ||
           'Input: [operation_type: ' || coalesce(operation_type, 'NULL') || ', ' ||
           'p_plant_id: ' || coalesce(p_plant_id::text, 'NULL') || ', ' ||
           'p_pattern_cd: ' || coalesce(p_pattern_cd::text, 'NULL') || ', ' ||
           'p_pattern_ds: ' || coalesce(p_pattern_ds::text, 'NULL') || ', ' ||
           'p_is_deleted: ' || coalesce(p_is_deleted::text, 'NULL') || ', ' ||
           'p_is_default: ' || coalesce(p_is_default::text, 'NULL') || ', ' ||
           'p_au_user_id: ' || coalesce(p_au_user_id::text, 'NULL') || ', ' ||
           'p_is_modify: ' || coalesce(p_is_modify::text, 'NULL') || ', ' ||
           'p_is_active: ' || coalesce(p_is_active::text, 'NULL') || ', ' ||
           'au_change_ts: ' || coalesce(timezone('UTC', current_timestamp)::text, 'NULL') || ', ' || ']';

begin
            insert
			into
			application_data.log_error (
		    error_timestamp,
			error_src,
			error_msg,
			error_caller
		            )
			values (
		    timezone('UTC', current_timestamp),
			procedure_name,
			err_msg,
			p_au_user_id::text
		            );

commit;

end;
raise;

end;

$procedure$
;

-- DROP PROCEDURE application_data.manage_shift_definition(varchar, int8, int8, varchar, varchar, varchar, int4, varchar, int4, int8, int4, int8, int4);

CREATE OR REPLACE PROCEDURE application_data.manage_shift_definition(operation_type character varying, p_plant_id bigint DEFAULT NULL::bigint, p_shift_def_id bigint DEFAULT NULL::bigint, p_shift_def_short_cd character varying DEFAULT NULL::character varying, p_shift_def_ds character varying DEFAULT NULL::character varying, p_start_time_desc character varying DEFAULT NULL::character varying, p_start_time_offset integer DEFAULT NULL::integer, p_end_time_desc character varying DEFAULT NULL::character varying, p_end_time_offset integer DEFAULT NULL::integer, p_au_user_id bigint DEFAULT NULL::bigint, p_is_modify integer DEFAULT NULL::integer, p_pattern_id bigint DEFAULT NULL::bigint, p_shift_sort integer DEFAULT NULL::integer)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:		
-- @Company:    Decisyon
-- @Project:    DLMO
-- @Version:	
-- @Date:		
-- @ChangeHis:
--
-- @Description: 
--    Procedure to manage the shift definition table, allowing for create, update, and delete operations 
--    according to the value of param operation_type.
-- 
--    Params:
--      - operation_type (character varying):                The type of operation to be performed (CREATE, UPDATE, DELETE).
--      - p_plant_id (bigint, DEFAULT NULL):                 The ID of the plant.
--      - p_shift_def_id (bigint, DEFAULT NULL):             The ID of the shift definition.
--      - p_shift_def_short_cd (character varying, DEFAULT NULL): The short code of the shift definition.
--      - p_shift_def_ds (character varying, DEFAULT NULL):  The description of the shift definition.
--      - p_start_time_desc (character varying, DEFAULT NULL): The start time description.
--      - p_start_time_offset (integer, DEFAULT NULL):       The start time offset.
--      - p_end_time_desc (character varying, DEFAULT NULL): The end time description.
--      - p_end_time_offset (integer, DEFAULT NULL):         The end time offset.
--      - p_au_user_id (bigint, DEFAULT NULL):               The ID of the user performing the operation.
--      - p_is_modify (integer, DEFAULT NULL):               Indicator if the record can be modified.
--      - p_pattern_id (bigint, DEFAULT NULL):               The ID of the pattern.
--      - p_shift_sort (integer, DEFAULT NULL):              The sort order of the shift.
-- ============================================================================================================

DECLARE 
    step NUMERIC;
    procedure_name VARCHAR(50) := 'application_data.manage_sh_lk_shift_definition';
    err_msg VARCHAR(2000);
    pp_shift_def_cd VARCHAR;
    pp_duration INTEGER;

begin
	step := 0;
	IF p_au_user_id IS NULL THEN 
    	RAISE EXCEPTION 'au_user_id CANNOT BE NULL';
    END IF;
    
   	--Log operation
    step := 0.1;
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        'application_data.manage_shift_definition',
        'Input: [operation_type: ' || operation_type || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
            'p_shift_def_id: ' || COALESCE(p_shift_def_id::text, 'NULL') || ', ' ||
            'p_shift_def_short_cd: ' || COALESCE(p_shift_def_short_cd, 'NULL') || ', ' ||
            'p_shift_def_ds: ' || COALESCE(p_shift_def_ds, 'NULL') || ', ' ||
            'p_start_time_desc: ' || COALESCE(p_start_time_desc, 'NULL') || ', ' ||
            'p_start_time_offset: ' || COALESCE(p_start_time_offset::text, 'NULL') || ', ' ||
            'p_end_time_desc: ' || COALESCE(p_end_time_desc, 'NULL') || ', ' ||
            'p_end_time_offset: ' || COALESCE(p_end_time_offset::text, 'NULL') || ', ' ||
            'p_au_user_id: ' || COALESCE(p_au_user_id::text, 'NULL') || ', ' ||
            'p_is_modify: ' || COALESCE(p_is_modify::text, 'NULL') || ', ' ||
            'p_pattern_id: ' || COALESCE(p_pattern_id::text, 'NULL') || ', ' ||
            'p_shift_sort: ' || COALESCE(p_shift_sort::text, 'NULL') || ']',
        p_au_user_id::text
    );
   
    -- Main CASE block to handle different operation types
	CASE operation_type
    	-- Insert operation
    	WHEN 'I' THEN
            step := 1;  
           
           	-- Check if any required values are NULL for insert operation
            IF p_plant_id IS NULL OR 
               p_pattern_id IS NULL OR 
               p_start_time_desc IS NULL OR 
               p_start_time_offset IS NULL OR 
               p_end_time_desc IS NULL OR 
               p_end_time_offset IS NULL OR
               p_shift_sort IS NULL THEN
                RAISE EXCEPTION 'VALUES CANNOT BE NULL TO INSERT A NEW SHIFT_DEFINITION';
            END IF;

            -- Generate shift definition code and evaluate duration
            pp_shift_def_cd := (select pattern_cd from application_data.sh_lk_pattern where plant_id=p_plant_id and pattern_id=p_pattern_id) ||'---'||	p_shift_def_short_cd;
            pp_duration := application_data.evaluate_duration(p_start_time_desc, p_end_time_desc, p_end_time_offset);


            -- Insert new shift definition record
            INSERT INTO application_data.sh_lk_shift_definition (
                plant_id,
                shift_def_cd,
                shift_def_short_cd,
                shift_def_ds,
                start_time_desc,
                start_time_offset,
                end_time_desc,
                end_time_offset,
                duration_ss,
                is_modify,
                au_user_id,
                au_change_type,
                au_change_num,
                au_change_day_id,
                au_change_ts
            ) VALUES (
                p_plant_id, 
                pp_shift_def_cd, 
                p_shift_def_short_cd, 
                p_shift_def_ds, 
                p_start_time_desc, 
                0, 
                p_end_time_desc, 
                p_end_time_offset, 
                pp_duration,
                1,
                p_au_user_id,
                'INSERT',
                0,
                to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
                timezone('UTC',current_timestamp)
            );


            -- Insert new mapping between pattern and shift definition
            INSERT INTO application_data.sh_map_pattern_shift
            (
                plant_id,
                pattern_id,
                shift_def_id,
                shift_sort,
                au_user_id,
                au_change_type,
                au_change_num,
                au_change_day_id,
                au_change_ts
            ) VALUES (
                p_plant_id, 
                p_pattern_id,
                (   select shift_def_id 
	                from  application_data.sh_lk_shift_definition 
	                where plant_id =p_plant_id 
	                        and shift_def_cd= pp_shift_def_cd
                ),
	            p_shift_sort,
                p_au_user_id,
                'INSERT',
                0,
                to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
                timezone('UTC',current_timestamp)
            );

        -- Update operation
        WHEN 'U' THEN
            step := 2.1;
            -- Check if any required values are NULL for update operation
            IF p_shift_def_id IS NULL OR
               p_plant_id IS NULL OR 
               p_pattern_id IS NULL OR 
               p_start_time_desc IS NULL OR 
               p_start_time_offset IS NULL OR 
               p_end_time_desc IS NULL OR 
               p_end_time_offset IS NULL OR 
               p_shift_sort IS NULL THEN
                RAISE EXCEPTION 'VALUES CANNOT BE NULL TO UPDATE A SHIFT_DEFINITION';
            END IF;
            IF p_au_user_id IS NULL THEN 
                RAISE EXCEPTION 'au_user_id CANNOT BE NULL';
            END IF;
            
           -- Generate shift definition code and evaluate duration
           pp_shift_def_cd := (select pattern_cd from application_data.sh_lk_pattern where plant_id=p_plant_id and pattern_id=p_pattern_id) ||'---'||	p_shift_def_short_cd;
            pp_duration := application_data.evaluate_duration(p_start_time_desc, p_end_time_desc, p_end_time_offset);


            step := 2.2;
            -- Update existing shift definition record
            UPDATE application_data.sh_lk_shift_definition
            SET
                shift_def_cd = pp_shift_def_cd,                                                    				    -- Update shift_def_cd if provided
                shift_def_short_cd = COALESCE(p_shift_def_short_cd, shift_def_short_cd),                            -- Update shift_def_short_cd if provided
                shift_def_ds = COALESCE(p_shift_def_ds, shift_def_ds),                                              -- Update shift_def_ds if provided
                start_time_desc = p_start_time_desc,                                                                -- Update start_time_desc
                start_time_offset = 0,                                                                              -- Update start_time_offset
                end_time_desc = p_end_time_desc,                                                                    -- Update end_time_desc
                end_time_offset = p_end_time_offset,                                                                -- Update end_time_offset
                duration_ss = pp_duration,                                                                          -- Update duration_ss
                au_user_id = p_au_user_id,                                                                          -- Update au_user_id if provided
                au_change_type = 'UPDATE',                                                                          -- Update au_change_type if provided
                au_change_num = 0,                                                                                  -- Update au_change_num if provided
                au_change_day_id = to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),    -- Update au_change_day_id if provided
                au_change_ts = timezone('UTC',current_timestamp)                                                   -- Update au_change_ts if provided
            WHERE plant_id = p_plant_id
              AND shift_def_id = p_shift_def_id;

            step := 2.3;
            -- Update mapping between pattern and shift definition
            UPDATE application_data.sh_map_pattern_shift
            SET
                shift_sort = p_shift_sort,
                pattern_id = p_pattern_id,
                au_user_id = p_au_user_id,
                au_change_day_id=to_number(to_char(timezone('UTC',current_timestamp),'YYYYMMDD'),'99999999'),
                au_change_type = 'UPDATE',
                au_change_ts=timezone('UTC',current_timestamp)
            WHERE plant_id = p_plant_id 
                AND shift_def_id = p_shift_def_id;

       	WHEN 'D' then
       	step := 3;
          	-- Perform physical deletion operation
            -- First update the audit user in sh_map_pattern_shift table
            update    
          		application_data.sh_map_pattern_shift 
			set 
				au_user_id = p_au_user_id
			where  
				plant_id = p_plant_id
				and shift_def_id = p_shift_def_id;
		step := 3.1;
			-- Then delete the mapping between pattern and shift definition
			DELETE FROM application_data.sh_map_pattern_shift 
			where  
				plant_id = p_plant_id
				and shift_def_id = p_shift_def_id;
       step := 3.2;
       		-- Update the audit user in sh_lk_shift_definition table
       		UPDATE  
       			application_data.sh_lk_shift_definition
			set au_user_id = p_au_user_id 
			WHERE 
				plant_id = p_plant_id
			and shift_def_id = p_shift_def_id;

		step := 3.3;
			 -- Finally delete the shift definition record
			 DELETE FROM 
				application_data.sh_lk_shift_definition
			WHERE plant_id = p_plant_id
			and shift_def_id = p_shift_def_id;

        ELSE
            -- Raise exception for invalid operation type
            RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
    	-- Log any exceptions that occur
       	err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
            'Step: ' || step::text || ', ' ||
            'Input: [operation_type: ' || operation_type || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::text, 'NULL') || ', ' ||
            'p_shift_def_id: ' || COALESCE(p_shift_def_id::text, 'NULL') || ', ' ||
            'pp_shift_def_cd: ' || COALESCE(pp_shift_def_cd, 'NULL') || ', ' ||
            'p_shift_def_short_cd: ' || COALESCE(p_shift_def_short_cd, 'NULL') || ', ' ||
            'p_shift_def_ds: ' || COALESCE(p_shift_def_ds, 'NULL') || ', ' ||
            'p_start_time_desc: ' || COALESCE(p_start_time_desc, 'NULL') || ', ' ||
            'p_start_time_offset: ' || COALESCE(p_start_time_offset::text, 'NULL') || ', ' ||
            'p_end_time_desc: ' || COALESCE(p_end_time_desc, 'NULL') || ', ' ||
            'p_end_time_offset: ' || COALESCE(p_end_time_offset::text, 'NULL') || ', ' ||
            'pp_duration: ' || COALESCE(pp_duration::text, 'NULL') || ', ' ||
            'p_au_user_id: ' || COALESCE(p_au_user_id::text, 'NULL') || ']';
        BEGIN 
	        INSERT INTO application_data.log_error (
                error_timestamp,
                error_src, 
                error_msg,
                error_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                procedure_name,
                err_msg,
                p_au_user_id::text
            );
            COMMIT;
        END;
        RAISE;
END;
$procedure$
;

-- DROP PROCEDURE application_data.log_error_write(varchar, varchar, varchar);

CREATE OR REPLACE PROCEDURE application_data.log_error_write(IN p_error_src character varying, IN p_error_msg character varying, IN p_error_caller character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    conn_name  TEXT := 'etl_log_err_' || pg_backend_pid();
    conn_str   TEXT;
    sql_insert TEXT;
    esc_src    TEXT;
    esc_msg    TEXT;
    esc_caller TEXT;
BEGIN
    -- Escape single quotes for use inside SQL string
    esc_src    := replace(COALESCE(p_error_src, ''), '''', '''''');
    esc_msg    := replace(COALESCE(p_error_msg, ''), '''', '''''');
    esc_caller := replace(COALESCE(p_error_caller, ''), '''', '''''');

    -- Connection string da tabella di config (con password) per dblink da EXCEPTION; se assente usa default
    SELECT config_value INTO conn_str
      FROM application_data.log_error_write_cfg
     WHERE config_key = 'dblink_conn_str'
     LIMIT 1;
    IF conn_str IS NULL OR btrim(conn_str) = '' THEN
        conn_str := 'dbname=' || current_database() || ' user=' || current_user;
    END IF;
    sql_insert := 'INSERT INTO application_data.log_error (error_timestamp, error_src, error_msg, error_caller) '
        || 'VALUES (timezone(''UTC'', current_timestamp), '
        || '''' || esc_src || ''', ''' || esc_msg || ''', ''' || esc_caller || ''')';

    -- Write and commit in a separate connection so it persists on rollback
    PERFORM dblink_connect(conn_name, conn_str);
    PERFORM dblink_exec(conn_name, sql_insert);
    PERFORM dblink_exec(conn_name, 'COMMIT');
    PERFORM dblink_disconnect(conn_name);

EXCEPTION WHEN OTHERS THEN
    -- Fallback: direct INSERT (will be rolled back with caller transaction if it rolls back)
    BEGIN
        INSERT INTO application_data.log_error (
            error_timestamp, error_src, error_msg, error_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            p_error_src,
            p_error_msg,
            p_error_caller
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    -- Disconnect if we had connected (e.g. exec failed after connect)
    BEGIN
        PERFORM dblink_disconnect(conn_name);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END;
$procedure$
;



-- create trigger trg_update_ft_kpi_target_from_safety_cross

DROP TRIGGER IF EXISTS trg_update_ft_kpi_target_from_safety_cross ON application_data.ft_safety_cross;

create trigger trg_update_ft_kpi_target_from_safety_cross after
insert
    or
delete
    or
update
    on
    application_data.ft_safety_cross for each row execute function application_data.trigger_ft_kpi_target_from_safety_cross();

-- DROP PROCEDURE application_data.manage_target(varchar, int8, varchar);
-- DROP PROCEDURE application_data.manage_target(int8, varchar, date, date, int8, int8, boolean);

DROP PROCEDURE IF EXISTS application_data.manage_target(varchar, int8, varchar);
DROP PROCEDURE IF EXISTS application_data.manage_target(int8, varchar, date, date, int8, int8, boolean);

-- ================================================================================================================================================
-- Main (robust) signature: supports date ranges (backfill) + optional plant/line filter + optional time-gate bypass
-- ================================================================================================================================================
CREATE OR REPLACE PROCEDURE application_data.manage_target(
    -- Required caller info first (PostgreSQL rule: defaults cannot precede non-default params)
    IN p_user_id BIGINT,
    IN p_user_fullname character varying,
    -- Optional execution filters
    IN p_date_min DATE DEFAULT NULL,
    IN p_date_max DATE DEFAULT NULL,
    IN p_plant_id BIGINT DEFAULT NULL,
    IN p_line_id BIGINT DEFAULT NULL,
    IN p_bypass_gate BOOLEAN DEFAULT FALSE
)
 LANGUAGE plpgsql
AS $procedure$
-- ================================================================================================================================================
-- @Description:
--      Procedure to manage TARGET VALUE in the ft_kpi_target table.
--      In this version we process only KPI with kpi_code = 'FPY'.
-- ================================================================================================================================================
DECLARE
    lp_last_user VARCHAR;
    lp_step NUMERIC;
    lp_procedure_name VARCHAR(50) := 'application_data.manage_target';
    lp_err_msg VARCHAR(2000);
    lp_updating_date NUMERIC(8);
    target_rec RECORD;
    plant_rec RECORD;
    lp_weighted_avg NUMERIC(18,2);
    lp_plant_id INT8;
    lp_line_id INT8;
    lp_kpi_id INT8;
    lp_target_date_iso NUMERIC(8);
    lp_record_number INT8;
    lp_local_time TIME;
    lp_use_manual_range BOOLEAN := FALSE;
    lp_day_id_min NUMERIC(8);
    lp_day_id_max NUMERIC(8);
    lp_date_min DATE;
    lp_date_max DATE;

cursor_plant CURSOR FOR
   SELECT plant_id, plant_timezone
    FROM application_data.lk_plant
    WHERE is_deleted = false
      AND is_active = true
      AND (p_plant_id IS NULL OR plant_id = p_plant_id);

cursor_target CURSOR FOR
   SELECT DISTINCT
    row_number() OVER (ORDER BY trg.kpi_id, trg.target_date_iso) as record_num,
    trg.kpi_id,
    trg.line_id,
    trg.plant_id,
    trg.kpi_category_id,
    trg.target_tendency_id,
    trg.target_date_iso,
    trg.target_value_num,
    trg.total_good
    FROM application_data.ft_kpi_target trg
    INNER JOIN application_data.lk_kpi kpi ON trg.kpi_id = kpi.kpi_id
    WHERE (target_value_num is null)
      AND trg.plant_id = lp_plant_id
      AND (p_line_id IS NULL OR trg.line_id = p_line_id)
      AND total_good is not null
      AND kpi.kpi_code = 'FPY'
      AND (
        (lp_use_manual_range = FALSE AND target_date_iso <= lp_updating_date)
        OR
        (lp_use_manual_range = TRUE
         AND target_date_iso >= lp_day_id_min
         AND (lp_day_id_max IS NULL OR target_date_iso <= lp_day_id_max)
        )
      )
    ORDER BY 1;
BEGIN
    lp_step := 0;

    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [p_date_min: ' || COALESCE(p_date_min::TEXT, 'NULL') || ', ' ||
            'p_date_max: ' || COALESCE(p_date_max::TEXT, 'NULL') || ', ' ||
            'p_plant_id: ' || COALESCE(p_plant_id::TEXT, 'NULL') || ', ' ||
            'p_line_id: ' || COALESCE(p_line_id::TEXT, 'NULL') || ', ' ||
            'p_bypass_gate: ' || COALESCE(p_bypass_gate::TEXT, 'NULL') || ', ' ||
            'p_user_id: '  || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: '  || COALESCE(p_user_fullname, 'NULL') || ', ]',
        p_user_id::text || ' -- ' || p_user_fullname
    );

    IF p_user_id IS NULL OR p_user_fullname IS NULL THEN
        lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_last_user := p_user_id::TEXT || ' -- ' || p_user_fullname;

    FOR plant_rec IN cursor_plant LOOP
        lp_step := 1;
        SELECT plant_rec.plant_id INTO lp_plant_id;
        IF plant_rec.plant_timezone IS NULL THEN
            lp_step := 2;
            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Input: [plant_rec.plant_id: ' || COALESCE(plant_rec.plant_id, 'NULL') || ', ' ||
                'plant_rec.plant_timezone: timezone is not defined, ]',
                p_user_id::text || ' -- ' || p_user_fullname
            );
            CONTINUE;
        END IF;
        lp_step := 3;

        SELECT to_char((CURRENT_TIMESTAMP AT TIME ZONE plant_rec.plant_timezone - interval '1 day')::date,'YYYYMMDD')::int
          INTO lp_updating_date;

        IF p_date_min IS NULL AND p_date_max IS NULL THEN
            lp_use_manual_range := FALSE;
        ELSE
            lp_use_manual_range := TRUE;
            lp_date_min := COALESCE(p_date_min, p_date_max);
            lp_date_max := p_date_max;
            lp_day_id_min := to_char(lp_date_min, 'YYYYMMDD')::NUMERIC(8);
            IF lp_date_max IS NOT NULL THEN
                lp_day_id_max := to_char(lp_date_max, 'YYYYMMDD')::NUMERIC(8);
            ELSE
                lp_day_id_max := NULL;
            END IF;
        END IF;

        IF lp_use_manual_range = FALSE AND p_bypass_gate = FALSE THEN
            SELECT (NOW() AT TIME ZONE plant_rec.plant_timezone)::TIME INTO lp_local_time;
            IF lp_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
                INSERT INTO application_data.log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'SKIP plant_id=' || lp_plant_id::TEXT ||
                    ': local time ' || COALESCE(lp_local_time::TEXT, '?') ||
                    ' (TZ=' || plant_rec.plant_timezone || ') is outside 00:00-00:59 window.',
                    lp_last_user
                );
                CONTINUE;
            END IF;
        END IF;

        FOR target_rec IN cursor_target LOOP
            lp_step := 4;
            SELECT target_rec.record_num, target_rec.line_id, target_rec.kpi_id, target_rec.target_date_iso
              INTO lp_record_number, lp_line_id, lp_kpi_id, lp_target_date_iso;

            lp_step := 5;
            SELECT round((SUM(main_query.ratio_total_step_over_line * main_query.rapporto_raggiungimento_target) * 100), 2)
              INTO lp_weighted_avg
            FROM (
                SELECT
                    sub.line_id,
                    sub.step,
                    sub.startdate_id,
                    sub.total_by_step_per_day,
                    sub.total_by_line_day,
                    sub.perc_total_step_over_line::text || '%',
                    sub.ratio_total_step_over_line,
                    sub.total_good_by_step_day_rework_0,
                    sub.total_by_step_day_rework_0,
                    round(((total_good_by_step_day_rework_0::numeric / NULLIF(total_by_step_day_rework_0, 0))::numeric) * 100, 2) as first_Pass_Yield,
                    mt.target_value as target_FPY_value,
                    round((round(((total_good_by_step_day_rework_0::numeric / NULLIF(total_by_step_day_rework_0, 0))::numeric) * 100, 5) / NULLIF(mt.target_value, 0)) * 100, 5) as Percentuale_raggiungimento_target,
                    round((round(((total_good_by_step_day_rework_0::numeric / NULLIF(total_by_step_day_rework_0, 0))::numeric) * 100, 5) / NULLIF(mt.target_value, 0)), 5) as rapporto_raggiungimento_target
                FROM (
                    SELECT
                        fr.line_id,
                        fr.machine_id as step,
                        fr.day_id as startdate_id,
                        COUNT(*) as total_by_step_per_day,
                        COUNT(*) FILTER (WHERE fr.pass_number = 0) AS total_by_step_day_rework_0,
                        COUNT(*) FILTER (WHERE lr.is_good = true AND fr.pass_number = 0) AS total_good_by_step_day_rework_0,
                        SUM(COUNT(*)) OVER (PARTITION BY fr.line_id, fr.day_id) AS total_by_line_day,
                        ROUND((COUNT(*) / (SUM(COUNT(*)) OVER (PARTITION BY fr.line_id, fr.day_id))) * 100, 5) as perc_total_step_over_line,
                        ROUND((COUNT(*) / (SUM(COUNT(*)) OVER (PARTITION BY fr.line_id, fr.day_id))), 5) as ratio_total_step_over_line
                    FROM application_data.ft_rawdata fr
                    JOIN application_data.lk_machine m
                      ON m.machine_id = fr.machine_id
                     AND m.plant_id = fr.plant_id
                     AND m.is_deleted = false
                     AND m.fpy_active = true
                    LEFT JOIN application_data.lk_result lr
                      ON lr.result_id = fr.result_id
                    WHERE fr.plant_id = target_rec.plant_id
                      AND fr.line_id = target_rec.line_id
                      AND fr.day_id = target_rec.target_date_iso
                    GROUP BY fr.line_id, fr.machine_id, fr.day_id
                ) sub
                INNER JOIN application_data.lk_machine_target mt
                        ON mt.plant_id = target_rec.plant_id
                       AND mt.line_id = sub.line_id
                       AND mt.machine_id = sub.step
                       AND mt.kpi_id = target_rec.kpi_id
                       AND mt.is_deleted = false
                       AND mt.is_active = true
                       AND target_rec.target_date_iso BETWEEN mt.start_date_id AND coalesce(mt.end_date_id,20991231)
            ) main_query;

            lp_step := 6;
            UPDATE application_data.ft_kpi_target
               SET target_value_num = lp_weighted_avg
             WHERE ft_kpi_target.plant_id = lp_plant_id
               AND ft_kpi_target.line_id = lp_line_id
               AND ft_kpi_target.kpi_id = lp_kpi_id
               AND ft_kpi_target.target_date_iso = lp_target_date_iso;

            INSERT INTO application_data.log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Input: [ row num : ' || COALESCE(lp_record_number::TEXT , 'NULL') || ', ' ||
                'line_id: ' || COALESCE(target_rec.line_id::TEXT , 'NULL') || ', ' ||
                'target_rec.kpi_id: '|| COALESCE(target_rec.kpi_id::TEXT , 'NULL') || ', ' ||
                'target_rec.target_date_iso: '  || COALESCE(target_rec.target_date_iso::TEXT , 'NULL') || ', ' ||
                'target_value: '  || COALESCE(lp_weighted_avg::TEXT , 'NULL') || ', ]',
                lp_last_user
            );
        END LOOP;
    END LOOP;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', Step: ' || lp_step::TEXT;
        CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, lp_last_user);
        RAISE;
END;
$procedure$
;

-- ================================================================================================================================================
-- Backward compatible wrapper (old signature)
-- ================================================================================================================================================
CREATE OR REPLACE PROCEDURE application_data.manage_target(
    IN p_operation_type character varying,
    IN p_user_id bigint,
    IN p_user_fullname character varying
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO application_data.log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        'application_data.manage_target',
        'Wrapper call (legacy signature): operation_type=' || COALESCE(p_operation_type, 'NULL'),
        COALESCE(p_user_id::TEXT, 'NULL') || ' -- ' || COALESCE(p_user_fullname, 'NULL')
    );

    CALL application_data.manage_target(
        p_date_min => NULL,
        p_date_max => NULL,
        p_plant_id => NULL,
        p_line_id => NULL,
        p_user_id => p_user_id,
        p_user_fullname => p_user_fullname,
        p_bypass_gate => FALSE
    );
END;
$procedure$;
