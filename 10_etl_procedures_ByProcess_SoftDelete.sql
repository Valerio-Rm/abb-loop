-- DROP PROCEDURE application_staging.etl_log_error_write(varchar, varchar, varchar);

CREATE OR REPLACE PROCEDURE application_staging.etl_log_error_write(IN p_error_src character varying, IN p_error_msg character varying, IN p_error_caller character varying)
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

    -- Connection string da application_data.log_error_write_cfg (stessa tabella usata da application_data.log_error_write)
    SELECT config_value INTO conn_str
      FROM application_data.log_error_write_cfg
     WHERE config_key = 'dblink_conn_str'
     LIMIT 1;
    IF conn_str IS NULL OR btrim(conn_str) = '' THEN
        conn_str := 'dbname=' || current_database() || ' user=' || current_user;
    END IF;
    sql_insert := 'INSERT INTO application_staging.etl_log_error (error_timestamp, error_src, error_msg, error_caller) '
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
        INSERT INTO application_staging.etl_log_error (
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

COMMENT ON PROCEDURE application_staging.etl_log_error_write(varchar, varchar, varchar) IS 'Writes one row to etl_log_error via dblink so it persists on rollback. Connection string from application_data.log_error_write_cfg (key dblink_conn_str) if set, else default without password. Fallback: direct INSERT if dblink fails.';

-- Unica procedura per inserimento iniziale (running) e aggiornamento finale (success/failed) su etl_monitoring.
-- p_action: 'start' = INSERT e ritorna id; 'end' = UPDATE del record p_id con state e date di fine (UTC + local da p_plant_timezone).
-- p_procedure_name: nome della procedura chiamante (es. application_staging.etl_run_all_lookups), passato dinamicamente.
-- Per 'end' con state='failed' usa dblink così l'update persiste dopo rollback.
-- DROP PROCEDURE IF EXISTS application_staging.etl_monitoring(varchar, bigint, varchar, text, varchar, varchar, date, date);
CREATE OR REPLACE PROCEDURE application_staging.etl_monitoring(
    IN p_action         varchar,
    INOUT p_id          bigint,
    IN p_state          varchar DEFAULT NULL,
    IN p_error_msg      text DEFAULT NULL,
    IN p_plant_timezone varchar DEFAULT NULL,
    IN p_procedure_name varchar DEFAULT NULL,
    IN p_date_min       date DEFAULT NULL,
    IN p_date_max       date DEFAULT NULL,
    IN p_plant_id       bigint DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    conn_name    TEXT := 'etl_mon_' || pg_backend_pid();
    conn_str     TEXT;
    rec          RECORD;
    sql_exec     TEXT;
    v_utc_ts     timestamp;
    v_local_ts   timestamp;
    esc_msg      TEXT;
    esc_proc     TEXT;
    v_end_utc    text;
    v_end_local  text;
    v_end_state  text;
BEGIN
    v_utc_ts := timezone('UTC', clock_timestamp());
    esc_proc := replace(trim(p_procedure_name), '''', '''''');

    IF p_action = 'start' THEN
        -- start_ts_local: ora locale se abbiamo il timezone del plant
        IF p_plant_timezone IS NOT NULL AND btrim(p_plant_timezone) <> '' THEN
            BEGIN
                v_local_ts := (clock_timestamp() AT TIME ZONE p_plant_timezone)::timestamp;
            EXCEPTION WHEN OTHERS THEN
                v_local_ts := NULL;
            END;
        ELSE
            v_local_ts := NULL;
        END IF;

        SELECT config_value INTO conn_str
          FROM application_data.log_error_write_cfg
         WHERE config_key = 'dblink_conn_str'
         LIMIT 1;
        IF conn_str IS NULL OR btrim(conn_str) = '' THEN
            conn_str := 'dbname=' || current_database() || ' user=' || current_user;
        END IF;

        p_id := NULL;
        PERFORM dblink_connect(conn_name, conn_str);
        sql_exec := 'INSERT INTO application_staging.etl_monitoring (procedure_name, start_ts_utc, start_ts_local, state, date_min, date_max, plant_id) '
            || 'VALUES (''' || esc_proc || ''', '''
            || to_char(v_utc_ts, 'YYYY-MM-DD HH24:MI:SS.MS') || ''', '
            || CASE WHEN v_local_ts IS NOT NULL THEN '''' || to_char(v_local_ts, 'YYYY-MM-DD HH24:MI:SS.MS') || '''' ELSE 'NULL' END
            || ', ''running'', '
            || CASE WHEN p_date_min IS NOT NULL THEN '''' || to_char(p_date_min, 'YYYY-MM-DD') || '''' ELSE 'NULL' END || ', '
            || CASE WHEN p_date_max IS NOT NULL THEN '''' || to_char(p_date_max, 'YYYY-MM-DD') || '''' ELSE 'NULL' END || ', '
            || CASE WHEN p_plant_id IS NOT NULL THEN p_plant_id::text ELSE 'NULL' END
            || ') RETURNING id';
        PERFORM dblink_send_query(conn_name, sql_exec);
        FOR rec IN SELECT * FROM dblink_get_result(conn_name) AS t(id bigint)
        LOOP
            p_id := rec.id;
            EXIT;
        END LOOP;
        PERFORM dblink_exec(conn_name, 'COMMIT');
        PERFORM dblink_disconnect(conn_name);

    ELSIF p_action = 'end' AND p_id IS NOT NULL THEN
        v_utc_ts := timezone('UTC', clock_timestamp());
        IF p_plant_timezone IS NOT NULL AND btrim(p_plant_timezone) <> '' THEN
            BEGIN
                v_local_ts := (clock_timestamp() AT TIME ZONE p_plant_timezone)::timestamp;
            EXCEPTION WHEN OTHERS THEN
                v_local_ts := NULL;
            END;
        ELSE
            v_local_ts := NULL;
        END IF;
        v_end_utc := to_char(v_utc_ts, 'YYYY-MM-DD HH24:MI:SS.MS');
        v_end_local := CASE WHEN v_local_ts IS NOT NULL THEN '''' || to_char(v_local_ts, 'YYYY-MM-DD HH24:MI:SS.MS') || '''' ELSE 'NULL' END;
        v_end_state := COALESCE(NULLIF(btrim(p_state), ''), 'success');
        esc_msg := replace(COALESCE(p_error_msg, ''), '''', '''''');

        -- success/skipped must be updated in current transaction so the AFTER UPDATE trigger
        -- can read the same snapshot (including newly loaded ft_rawdata).
        IF v_end_state IN ('success', 'skipped') THEN
            UPDATE application_staging.etl_monitoring
               SET end_ts_utc = v_utc_ts,
                   end_ts_local = v_local_ts,
                   state = v_end_state,
                   error_msg = CASE WHEN p_error_msg IS NOT NULL AND btrim(p_error_msg) <> '' THEN p_error_msg ELSE NULL END
             WHERE id = p_id;
        ELSE
            -- failed/end_orphan still persist via dblink even if caller transaction rolls back
            SELECT config_value INTO conn_str
              FROM application_data.log_error_write_cfg
             WHERE config_key = 'dblink_conn_str'
             LIMIT 1;
            IF conn_str IS NULL OR btrim(conn_str) = '' THEN
                conn_str := 'dbname=' || current_database() || ' user=' || current_user;
            END IF;
            sql_exec := 'UPDATE application_staging.etl_monitoring SET end_ts_utc = '''
                || v_end_utc || ''', end_ts_local = ' || v_end_local
                || ', state = ''' || v_end_state || ''''
                || ', error_msg = ' || CASE WHEN p_error_msg IS NOT NULL AND btrim(p_error_msg) <> '' THEN '''' || esc_msg || '''' ELSE 'NULL' END
                || ' WHERE id = ' || p_id::text;
            PERFORM dblink_connect(conn_name, conn_str);
            PERFORM dblink_exec(conn_name, sql_exec);
            PERFORM dblink_exec(conn_name, 'COMMIT');
            PERFORM dblink_disconnect(conn_name);
        END IF;

    ELSIF p_action = 'update' AND p_id IS NOT NULL AND p_plant_timezone IS NOT NULL AND btrim(p_plant_timezone) <> '' THEN
        -- Aggiorna start_ts_local e plant_id via dblink (evita lock nella transazione principale che poi bloccherebbe 'end' sulla stessa riga)
        BEGIN
            v_local_ts := (clock_timestamp() AT TIME ZONE p_plant_timezone)::timestamp;
            SELECT config_value INTO conn_str FROM application_data.log_error_write_cfg WHERE config_key = 'dblink_conn_str' LIMIT 1;
            IF conn_str IS NULL OR btrim(conn_str) = '' THEN conn_str := 'dbname=' || current_database() || ' user=' || current_user; END IF;
            sql_exec := 'UPDATE application_staging.etl_monitoring SET start_ts_local = ''' || to_char(v_local_ts, 'YYYY-MM-DD HH24:MI:SS.MS') || ''', plant_id = COALESCE(plant_id, ' || COALESCE(p_plant_id::text, 'NULL') || ') WHERE id = ' || p_id::text || ' AND start_ts_local IS NULL';
            PERFORM dblink_connect(conn_name, conn_str);
            PERFORM dblink_exec(conn_name, sql_exec);
            PERFORM dblink_exec(conn_name, 'COMMIT');
            PERFORM dblink_disconnect(conn_name);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;

    ELSIF p_action = 'end_orphan' AND p_procedure_name IS NOT NULL AND btrim(p_procedure_name) <> '' THEN
        -- Chiusura di sicurezza: chiude l'ultimo record in running per questa procedura (quando il chiamante non ha l'id, es. eccezione subito dopo start). Persiste via dblink.
        v_utc_ts := timezone('UTC', clock_timestamp());
        esc_msg := replace(COALESCE(p_error_msg, ''), '''', '''''');
        SELECT config_value INTO conn_str FROM application_data.log_error_write_cfg WHERE config_key = 'dblink_conn_str' LIMIT 1;
        IF conn_str IS NULL OR btrim(conn_str) = '' THEN
            conn_str := 'dbname=' || current_database() || ' user=' || current_user;
        END IF;
        sql_exec := 'UPDATE application_staging.etl_monitoring SET end_ts_utc = ''' || to_char(v_utc_ts, 'YYYY-MM-DD HH24:MI:SS.MS') || ''', end_ts_local = NULL, state = ''failed'', error_msg = ''' || esc_msg
            || ''' WHERE id = (SELECT id FROM application_staging.etl_monitoring WHERE state = ''running'' AND procedure_name = ''' || esc_proc || ''' ORDER BY id DESC LIMIT 1)';
        PERFORM dblink_connect(conn_name, conn_str);
        PERFORM dblink_exec(conn_name, sql_exec);
        PERFORM dblink_exec(conn_name, 'COMMIT');
        PERFORM dblink_disconnect(conn_name);
    END IF;

EXCEPTION WHEN OTHERS THEN
    IF p_action = 'start' THEN
        -- Fallback INSERT solo se non abbiamo già un id da dblink (evita doppio record: uno già committato su dblink, uno in transazione)
        IF p_id IS NULL THEN
            BEGIN
                v_local_ts := NULL;
                IF p_plant_timezone IS NOT NULL AND btrim(p_plant_timezone) <> '' THEN
                    v_local_ts := (clock_timestamp() AT TIME ZONE p_plant_timezone)::timestamp;
                END IF;
                INSERT INTO application_staging.etl_monitoring (procedure_name, start_ts_utc, start_ts_local, state, date_min, date_max, plant_id)
                VALUES (trim(p_procedure_name), timezone('UTC', clock_timestamp()), v_local_ts, 'running', p_date_min, p_date_max, p_plant_id)
                RETURNING id INTO p_id;
            EXCEPTION WHEN OTHERS THEN
                p_id := NULL;
            END;
        END IF;
    ELSIF p_action = 'end' AND p_id IS NOT NULL THEN
        -- Fallback: chiudi come 'failed' per non far scattare il trigger (che chiama populate_ft_quality_fpy e populate_ft_oee).
        -- Se chiudessimo con 'success' il trigger ri-fallirebbe.
        BEGIN
            UPDATE application_staging.etl_monitoring
            SET end_ts_utc = timezone('UTC', clock_timestamp()),
                end_ts_local = CASE WHEN p_plant_timezone IS NOT NULL AND btrim(p_plant_timezone) <> '' THEN (clock_timestamp() AT TIME ZONE p_plant_timezone)::timestamp ELSE NULL END,
                state = 'failed',
                error_msg = 'Close via dblink failed (e.g. trigger populate_ft_quality_fpy/populate_ft_oee): ' || COALESCE(SQLERRM, 'unknown')
            WHERE id = p_id;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;
    BEGIN
        PERFORM dblink_disconnect(conn_name);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;
$procedure$;

COMMENT ON PROCEDURE application_staging.etl_monitoring(varchar, bigint, varchar, text, varchar, varchar, date, date, bigint) IS 'Unica procedura ETL monitoring: start=INSERT running; update=aggiorna start_ts_local quando si ha plant_timezone; end=UPDATE success/failed. p_procedure_name = chiamante (dinamico). Usa dblink per start e per end failed.';

-- Drop old overload (single date)

CREATE OR REPLACE PROCEDURE application_staging.etl_run_all_lookups(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_dry_run boolean DEFAULT false, IN p_run_ft_rawdata boolean DEFAULT false, IN p_ft_rawdata_date_min date DEFAULT NULL::date, IN p_ft_rawdata_date_max date DEFAULT NULL::date, IN p_foreign_schema text DEFAULT 'dwh_remote'::text, IN p_foreign_schemas text[] DEFAULT NULL::text[], IN p_schema_group text DEFAULT NULL::text, IN p_continue_on_error boolean DEFAULT false)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    First runs all lookup synchronization procedures in the correct order.
--    Then always runs etl_sync_downtime for the same date(s) used for rawdata (yesterday or date range).
--    If p_run_ft_rawdata is true, runs etl_sync_ft_rawdata for each date in the range.
--    If p_ft_rawdata_date_max is NULL, loads all dates >= min present in the source.
--    If both min and max are NULL, loads yesterday only (backward compatible).
--    All in one transaction: if any step fails, everything is rolled back.
--
-- @Params:
--    - p_caller: Identifier for logging
--    - p_dry_run: If true, rolls back all changes at the end (for testing)
--    - p_run_ft_rawdata: If true, after all lookups run etl_sync_ft_rawdata (default false)
--    - p_ft_rawdata_date_min: Start date for ft_rawdata range (NULL with max NULL = yesterday only)
--    - p_ft_rawdata_date_max: End date for ft_rawdata range (NULL = no upper bound, all dates >= min from source)
--
-- @Execution Order:
--    0. etl_sync_lk_production_time_date
--    1..8. All lookup sync (plant, line, machine, component, fixture, shift, code, result)
--    8.5. etl_sync_downtime (sempre, stesse date di rawdata)
--    9. etl_sync_ft_rawdata per ogni data nel range (solo se p_run_ft_rawdata=true)
--
-- @Usage:
--    -- Lookups only:
--    CALL application_staging.etl_run_all_lookups('ETL_DAILY');
--    -- Lookups + ft_rawdata for yesterday:
--    CALL application_staging.etl_run_all_lookups('ETL_DAILY', false, true, NULL, NULL);
--    -- Lookups + ft_rawdata from a date onward (tutte le date in sorgente >= min):
--    CALL application_staging.etl_run_all_lookups('ETL_DAILY', false, true, '2026-01-01'::DATE, NULL);
--    -- Lookups + ft_rawdata for date range [min, max]:
--    CALL application_staging.etl_run_all_lookups('ETL_DAILY', false, true, '2026-01-01'::DATE, '2026-01-10'::DATE);
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_run_all_lookups';
    lp_step             NUMERIC := 0;
    lp_step_name        VARCHAR(50);
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_monitoring_id    BIGINT;
    lp_plant_timezone_for_monitoring varchar(100);
    lp_plant_id_for_monitoring bigint;
    lp_any_schema_processed BOOLEAN := FALSE;  -- TRUE if at least one schema ran steps (not skipped)
    lp_schema_started_count INT := 0;          -- Schemas that reached execution phase (not skipped)
    lp_schema_success_count INT := 0;          -- Schemas completed without exception
    lp_error_schemas    TEXT[] := ARRAY[]::TEXT[]; -- Schemas that failed when continue_on_error=true
    lp_monitoring_warning_msg TEXT;
    v_schema            TEXT;
    v_schemas           TEXT[];
    rec                 RECORD;
    -- Plant-local scheduling gate (run once/day per plant)
    v_site_key          TEXT;
    v_plant_id          BIGINT;
    v_plant_code        TEXT;
    v_plant_timezone    TEXT;
    v_local_time        TIME;
    v_local_date        DATE;
    v_yesterday_local   DATE;
    v_can_enforce_window BOOLEAN;
    v_early_skip_all    BOOLEAN := FALSE;  -- TRUE = fuori finestra 00:00-00:59, skip loop (1 sola query FDW)
BEGIN
    -- Determine list of source schemas to process
    IF p_foreign_schemas IS NOT NULL AND array_length(p_foreign_schemas, 1) > 0 THEN
        v_schemas := p_foreign_schemas;
    ELSIF p_schema_group IS NOT NULL THEN
        SELECT array_agg(schema_name ORDER BY run_order, schema_name)
        INTO v_schemas
        FROM application_staging.etl_source_schema_cfg
        WHERE enabled = TRUE
          AND group_code = p_schema_group;

        IF v_schemas IS NULL OR array_length(v_schemas, 1) = 0 THEN
            RAISE EXCEPTION 'No enabled schemas found for group % in application_staging.etl_source_schema_cfg', p_schema_group;
        END IF;
    ELSE
        v_schemas := ARRAY[p_foreign_schema];
    END IF;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Running all lookup synchronization procedures' ||
        CASE WHEN p_dry_run THEN ' [DRY RUN]' ELSE '' END ||
        ' (foreign_schemas=' || array_to_string(v_schemas, ',') || ', continue_on_error=' || p_continue_on_error::TEXT || ')',
        p_caller
    );

    -- Una riga etl_monitoring per run (un solo plant; se gli schemi mappano plant diversi -> rollback)
    CALL application_staging.etl_monitoring('start', lp_monitoring_id, NULL, NULL, NULL, lp_procedure_name, p_ft_rawdata_date_min, p_ft_rawdata_date_max, NULL);

    lp_plant_timezone_for_monitoring := NULL;
    lp_plant_id_for_monitoring := NULL;

    -- Early exit (solo modalità scheduled: date_min/date_max entrambi NULL): 1 sola query FDW sul primo schema.
    -- Se plant è fuori finestra 00:00-00:59 non iterare su tutti gli schemi (evita N query FDW lente).
    IF p_ft_rawdata_date_min IS NULL AND p_ft_rawdata_date_max IS NULL AND array_length(v_schemas, 1) > 0 THEN
        v_schema := v_schemas[1];
        v_site_key := NULL;
        BEGIN
            EXECUTE format('SELECT "SiteKey" FROM %I."Site" LIMIT 1', v_schema) INTO v_site_key;
        EXCEPTION WHEN OTHERS THEN
            v_site_key := NULL;
        END;
        IF v_site_key IS NOT NULL AND btrim(v_site_key) <> '' THEN
            SELECT plant_id, plant_timezone, plant_code INTO v_plant_id, v_plant_timezone, v_plant_code
            FROM application_data.lk_plant
            WHERE plant_code = v_site_key AND is_deleted = false LIMIT 1;
            IF v_plant_id IS NOT NULL THEN
                v_plant_timezone := COALESCE(NULLIF(btrim(v_plant_timezone), ''), 'UTC');
                BEGIN
                    v_local_time := (NOW() AT TIME ZONE v_plant_timezone)::TIME;
                EXCEPTION WHEN OTHERS THEN
                    v_local_time := (NOW() AT TIME ZONE 'UTC')::TIME;
                END;
                IF v_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
                    lp_plant_timezone_for_monitoring := v_plant_timezone;
                    lp_plant_id_for_monitoring := v_plant_id;
                    CALL application_staging.etl_monitoring('update', lp_monitoring_id, NULL, NULL, v_plant_timezone, lp_procedure_name, NULL, NULL, v_plant_id);
                    INSERT INTO application_staging.etl_log_operation (operation_timestamp, operation_src, operation_msg, operation_caller)
                    VALUES (timezone('UTC', current_timestamp), lp_procedure_name,
                        'SKIP ALL: local time ' || v_local_time::TEXT || ' (TZ=' || v_plant_timezone || ', plant=' || COALESCE(v_plant_code, v_site_key) || ') outside 00:00-00:59 window. No FDW loop.',
                        p_caller);
                    v_early_skip_all := TRUE;
                END IF;
            END IF;
        END IF;
    END IF;

    IF NOT v_early_skip_all THEN
    FOREACH v_schema IN ARRAY v_schemas LOOP
        BEGIN
            -- Pre-check (scheduled mode only): run once per day per plant in its local 00:00-00:59 window.
            v_site_key := NULL;
            v_plant_id := NULL;
            v_plant_code := NULL;
            v_plant_timezone := NULL;
            v_local_time := NULL;
            v_local_date := NULL;
            v_yesterday_local := NULL;
            v_can_enforce_window := false;

            -- Resolve plant_code from the source schema (FDW) via Site.SiteKey
            BEGIN
                EXECUTE format('SELECT "SiteKey" FROM %I."Site" LIMIT 1', v_schema)
                INTO v_site_key;
            EXCEPTION WHEN OTHERS THEN
                v_site_key := NULL;
            END;

            -- If we cannot resolve SiteKey, we cannot map the schema to a plant: log and skip everything for this schema.
            IF v_site_key IS NULL OR btrim(v_site_key) = '' THEN
                lp_err_msg := 'Cannot resolve Site.SiteKey for foreign schema=' || v_schema || ' (required to map lk_plant.plant_code). Skipping schema.';
                CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'SKIP [schema=' || v_schema || ']: ' || lp_err_msg,
                    p_caller
                );
                CONTINUE;
            END IF;

            SELECT plant_id, plant_timezone, plant_code
            INTO v_plant_id, v_plant_timezone, v_plant_code
            FROM application_data.lk_plant
            WHERE plant_code = v_site_key
              AND is_deleted = false
            LIMIT 1;

            -- If SiteKey doesn't match a plant, skip everything for this schema (configuration/mapping error).
            IF v_plant_id IS NULL THEN
                lp_err_msg := 'No plant mapping found in application_data.lk_plant for SiteKey=' || v_site_key ||
                              ' (foreign schema=' || v_schema || ', expected lk_plant.plant_code match). Skipping schema.';
                CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'SKIP [schema=' || v_schema || ']: ' || lp_err_msg,
                    p_caller
                );
                CONTINUE;
            END IF;

            -- Plant deve essere lo stesso in tutti gli schemi; se differisce -> errore e rollback
            IF lp_plant_id_for_monitoring IS NOT NULL AND lp_plant_id_for_monitoring <> v_plant_id THEN
                RAISE EXCEPTION 'Plant mismatch across schemas: schema % has plant_id % (plant_code %) but expected plant_id % from previous schema(s). ETL rollback.',
                    v_schema, v_plant_id, COALESCE(v_plant_code, '?'), lp_plant_id_for_monitoring;
            END IF;
            IF lp_plant_timezone_for_monitoring IS NULL AND v_plant_timezone IS NOT NULL THEN
                lp_plant_timezone_for_monitoring := v_plant_timezone;
                lp_plant_id_for_monitoring := v_plant_id;
                CALL application_staging.etl_monitoring('update', lp_monitoring_id, NULL, NULL, v_plant_timezone, lp_procedure_name, NULL, NULL, v_plant_id);
            END IF;

            -- If plant/timezone not found yet, fallback to UTC BUT still enforce the daily window in UTC
            -- (so the hourly schedule doesn't run 24x/day for that plant).
            IF v_plant_timezone IS NULL OR btrim(v_plant_timezone) = '' THEN
                v_plant_timezone := 'UTC';
                v_can_enforce_window := true;
            ELSE
                v_can_enforce_window := true;
            END IF;

            -- Compute local time/date (defensive: invalid TZ -> fallback UTC)
            BEGIN
                v_local_time := (NOW() AT TIME ZONE v_plant_timezone)::TIME;
                v_local_date := timezone(v_plant_timezone, current_timestamp)::DATE;
            EXCEPTION WHEN OTHERS THEN
                v_plant_timezone := 'UTC';
                v_local_time := (NOW() AT TIME ZONE 'UTC')::TIME;
                v_local_date := timezone('UTC', current_timestamp)::DATE;
                v_can_enforce_window := true;
            END;
            v_yesterday_local := (v_local_date - 1);

            IF p_ft_rawdata_date_min IS NULL AND p_ft_rawdata_date_max IS NULL AND v_can_enforce_window THEN
                IF v_local_time NOT BETWEEN TIME '00:00:00' AND TIME '00:59:59' THEN
                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'SKIP [schema=' || v_schema || ']: local time ' || COALESCE(v_local_time::TEXT, '?') ||
                        ' (TZ=' || COALESCE(v_plant_timezone, '?') || ', plant=' || COALESCE(v_plant_code, COALESCE(v_site_key, '?')) ||
                        ', plant_id=' || COALESCE(v_plant_id::TEXT, '?') || ') is outside 00:00-00:59 window.',
                        p_caller
                    );
                    CONTINUE;
                END IF;
            END IF;

            -- At least one schema passed all checks (time window, plant mapping); we will run steps
            lp_any_schema_processed := TRUE;
            lp_schema_started_count := lp_schema_started_count + 1;

            -- 0. Sync ProductionTimeDate (once per system, idempotent)
            lp_step := 0;
            lp_step_name := 'etl_sync_lk_production_time_date';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_production_time_date(p_caller, v_schema);

            -- 1. Sync Plants
            lp_step := 1;
            lp_step_name := 'etl_sync_lk_plant';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_plant(p_caller, v_schema);

            -- 2. Sync Lines
            lp_step := 2;
            lp_step_name := 'etl_sync_lk_line';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_line(p_caller, v_schema);

            -- 3. Sync Machines (from Steps)
            lp_step := 3;
            lp_step_name := 'etl_sync_lk_machine';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_machine(p_caller, v_schema);

            -- 4. Sync Components (from Machines)
            lp_step := 4;
            lp_step_name := 'etl_sync_lk_component';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_component(p_caller, v_schema);

            -- 5. Sync Fixtures
            lp_step := 5;
            lp_step_name := 'etl_sync_lk_fixture';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_fixture(p_caller, v_schema);

            -- 6. Sync Shifts
            lp_step := 6;
            lp_step_name := 'etl_sync_lk_shift';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_shift(p_caller, v_schema);

            -- 7. Sync Codes
            lp_step := 7;
            lp_step_name := 'etl_sync_lk_code';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_code(p_caller, v_schema);

            -- 8. Sync Results
            lp_step := 8;
            lp_step_name := 'etl_sync_lk_result';
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || ']',
                p_caller
            );
            CALL application_staging.etl_sync_lk_result(p_caller, v_schema);

            -- Step 8.5: Sync Downtime (always, before ft_rawdata; same date logic as rawdata)
            lp_step := 8.5;
            lp_step_name := 'etl_sync_downtime';
            IF p_ft_rawdata_date_min IS NULL AND p_ft_rawdata_date_max IS NULL THEN
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || '] (date: yesterday)',
                    p_caller
                );
                CALL application_staging.etl_sync_downtime(p_caller, v_yesterday_local, p_dry_run, v_schema);
            ELSIF p_ft_rawdata_date_min IS NOT NULL THEN
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || '] (date range: ' ||
                    p_ft_rawdata_date_min::TEXT || ' .. ' || COALESCE(p_ft_rawdata_date_max::TEXT, 'max') || ')',
                    p_caller
                );
                FOR rec IN
                    SELECT DISTINCT production_date AS prod_date
                    FROM application_data.lk_production_time_date
                    WHERE production_date >= p_ft_rawdata_date_min
                      AND (p_ft_rawdata_date_max IS NULL OR production_date <= p_ft_rawdata_date_max)
                    ORDER BY 1
                LOOP
                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Step 8.5: Loading Downtime for date ' || rec.prod_date::TEXT || ' [schema=' || v_schema || ']',
                        p_caller
                    );
                    CALL application_staging.etl_sync_downtime(p_caller, rec.prod_date, p_dry_run, v_schema);
                END LOOP;
            ELSE
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || '] (using yesterday)',
                    p_caller
                );
                CALL application_staging.etl_sync_downtime(p_caller, v_yesterday_local, p_dry_run, v_schema);
            END IF;

            -- Step 9: Sync ft_rawdata (only if requested and all lookups succeeded)
            IF p_run_ft_rawdata THEN
                lp_step := 9;
                lp_step_name := 'etl_sync_ft_rawdata';
                IF p_ft_rawdata_date_min IS NULL AND p_ft_rawdata_date_max IS NULL THEN
                    -- Backward compat: single date = yesterday
                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || '] (date: yesterday; plant_tz=' ||
                        COALESCE(v_plant_timezone, 'UTC') || ')',
                        p_caller
                    );
                    CALL application_staging.etl_sync_ft_rawdata(p_caller, v_yesterday_local, p_dry_run, v_schema);
                ELSIF p_ft_rawdata_date_min IS NOT NULL THEN
                    -- Range: dates from application_data.lk_production_time_date >= min and <= max (max NULL = no upper bound)
                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || '] (date range: ' ||
                        p_ft_rawdata_date_min::TEXT || ' .. ' || COALESCE(p_ft_rawdata_date_max::TEXT, 'max') || ')',
                        p_caller
                    );
                    FOR rec IN
                        SELECT DISTINCT production_date AS prod_date
                        FROM application_data.lk_production_time_date
                        WHERE production_date >= p_ft_rawdata_date_min
                          AND (p_ft_rawdata_date_max IS NULL OR production_date <= p_ft_rawdata_date_max)
                        ORDER BY 1
                    LOOP
                        INSERT INTO application_staging.etl_log_operation (
                            operation_timestamp, operation_src, operation_msg, operation_caller
                        ) VALUES (
                            timezone('UTC', current_timestamp),
                            lp_procedure_name,
                            'Step 9: Loading ft_rawdata for date ' || rec.prod_date::TEXT || ' [schema=' || v_schema || ']',
                            p_caller
                        );
                        CALL application_staging.etl_sync_ft_rawdata(p_caller, rec.prod_date, p_dry_run, v_schema);
                    END LOOP;
                ELSE
                    -- date_min NULL and date_max set: invalid; load yesterday
                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        'Step ' || lp_step || ': Starting ' || lp_step_name || ' [schema=' || v_schema || '] (date_min NULL, using yesterday)',
                        p_caller
                    );
                    CALL application_staging.etl_sync_ft_rawdata(p_caller, v_yesterday_local, p_dry_run, v_schema);
                END IF;
            END IF;

            -- Mark schema as successful only after all steps completed
            lp_schema_success_count := lp_schema_success_count + 1;
        EXCEPTION WHEN OTHERS THEN
            lp_err_msg := 'ERROR for schema ' || v_schema || ' at step ' || lp_step || ' (' || COALESCE(lp_step_name, 'unknown') || '): ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            IF p_continue_on_error THEN
                IF array_position(lp_error_schemas, v_schema) IS NULL THEN
                    lp_error_schemas := array_append(lp_error_schemas, v_schema);
                END IF;
                CONTINUE;
            ELSE
                RAISE;
            END IF;
        END;
    END LOOP;
    END IF;  -- NOT v_early_skip_all

    -- Chiusura etl_monitoring: success solo se almeno uno schema processato e non dry run; altrimenti skipped (persiste via dblink, non resta running)
    IF lp_any_schema_processed THEN
        lp_monitoring_warning_msg := NULL;
        IF p_continue_on_error AND COALESCE(array_length(lp_error_schemas, 1), 0) > 0 THEN
            lp_monitoring_warning_msg := 'WARNING: one or more schemas failed but execution continued (p_continue_on_error=true). Error schemas: ' || array_to_string(lp_error_schemas, ', ');
        END IF;
        IF p_dry_run THEN
            CALL application_staging.etl_monitoring('end', lp_monitoring_id, 'skipped', 'DRY RUN - rolled back', lp_plant_timezone_for_monitoring, lp_procedure_name, NULL, NULL, lp_plant_id_for_monitoring);
        ELSIF p_continue_on_error
          AND lp_schema_started_count > 0
          AND lp_schema_success_count = 0
          AND COALESCE(array_length(lp_error_schemas, 1), 0) > 0 THEN
            CALL application_staging.etl_monitoring(
                'end',
                lp_monitoring_id,
                'failed',
                'All executable schemas failed (p_continue_on_error=true). Error schemas: ' || array_to_string(lp_error_schemas, ', '),
                lp_plant_timezone_for_monitoring,
                lp_procedure_name,
                NULL,
                NULL,
                lp_plant_id_for_monitoring
            );
        ELSE
            CALL application_staging.etl_monitoring('end', lp_monitoring_id, 'success', lp_monitoring_warning_msg, lp_plant_timezone_for_monitoring, lp_procedure_name, NULL, NULL, lp_plant_id_for_monitoring);
        END IF;
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            CASE
                WHEN p_continue_on_error
                  AND lp_schema_started_count > 0
                  AND lp_schema_success_count = 0
                  AND COALESCE(array_length(lp_error_schemas, 1), 0) > 0
                THEN 'END - All executable schemas failed. etl_monitoring set to failed (error schemas=' || array_to_string(lp_error_schemas, ', ') || ').'
                ELSE 'END - All lookup synchronization completed successfully'
            END ||
            CASE WHEN p_continue_on_error
                      AND COALESCE(array_length(lp_error_schemas, 1), 0) > 0
                      AND NOT (
                          lp_schema_started_count > 0
                          AND lp_schema_success_count = 0
                      ) THEN
                ' WITH WARNINGS (error schemas=' || array_to_string(lp_error_schemas, ', ') || ')'
            ELSE '' END ||
            CASE WHEN p_run_ft_rawdata THEN '; ft_rawdata loaded.' ELSE '' END ||
            CASE WHEN p_dry_run THEN ' [DRY RUN - ROLLING BACK]' ELSE '' END,
            p_caller
        );
    ELSE
        CALL application_staging.etl_monitoring('end', lp_monitoring_id, 'skipped', 'All schemas skipped (outside 00:00-00:59 window or no plant/SiteKey mapping).', lp_plant_timezone_for_monitoring, lp_procedure_name, NULL, NULL, lp_plant_id_for_monitoring);
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'END - No schema processed (all skipped). etl_monitoring set to skipped; trigger will not run.',
            p_caller
        );
    END IF;

    -- If dry run, rollback all changes
    IF p_dry_run THEN
        RAISE EXCEPTION 'DRY RUN COMPLETED - Rolling back all changes as requested';
    END IF;

EXCEPTION WHEN OTHERS THEN
    -- Log the error with details about which step failed
    lp_err_msg := 'ERROR at step ' || lp_step || ' (' || COALESCE(lp_step_name, 'unknown') || '): ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    
    -- Chiudi sempre il record monitoring a failed (via dblink, persiste dopo rollback). Se non abbiamo l'id (eccezione subito dopo start) chiudiamo l'ultimo "running" (end_orphan).
    IF SQLERRM NOT LIKE 'DRY RUN COMPLETED%' THEN
        IF lp_monitoring_id IS NOT NULL THEN
            CALL application_staging.etl_monitoring('end', lp_monitoring_id, 'failed', lp_err_msg, lp_plant_timezone_for_monitoring, lp_procedure_name, NULL, NULL, lp_plant_id_for_monitoring);
        ELSE
            CALL application_staging.etl_monitoring('end_orphan', NULL, 'failed', lp_err_msg, NULL, lp_procedure_name, NULL, NULL, NULL);
        END IF;
    END IF;
    
    -- Note: This write will also be rolled back since we're in a failed transaction
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    
    -- Re-raise the exception - this ensures the transaction is rolled back
    -- and all changes made by previous procedures are undone
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_run_all_lookups(varchar, bool, bool, date, date, text, _text, text, bool) IS 'Master procedure: runs all lookup sync in order, then optionally etl_sync_ft_rawdata. Atomic: all succeed or all rollback. Params: p_caller, p_dry_run, p_run_ft_rawdata, p_ft_rawdata_date_min, p_ft_rawdata_date_max, p_foreign_schema, p_foreign_schemas, p_schema_group, p_continue_on_error.';

-- Trigger su etl_monitoring: quando state passa a 'success' chiama populate_ft_quality_fpy e populate_ft_oee
-- con date_min/date_max della run (coerenti con etl_run_all_lookups).
-- DROP TRIGGER IF EXISTS trg_etl_monitoring_after_success ON application_staging.etl_monitoring;
-- DROP FUNCTION IF EXISTS application_staging.fn_trg_etl_monitoring_after_success();
CREATE OR REPLACE FUNCTION application_staging.fn_trg_etl_monitoring_after_success()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF NEW.state = 'success' AND (OLD.state IS NULL OR OLD.state <> 'success') THEN
        BEGIN
            CALL application_data.populate_ft_quality_fpy(
                NEW.date_min,
                NEW.date_max,
                NEW.plant_id,
                NULL::bigint,
                9999999999999::bigint,
                'ETL_SYSTEM'::varchar
            );
        EXCEPTION WHEN OTHERS THEN
            -- Non far fallire l'UPDATE su etl_monitoring: chiudiamo la run come success, l'errore va in log.
            INSERT INTO application_staging.etl_log_error (error_timestamp, error_src, error_msg, error_caller)
            VALUES (
                timezone('UTC', current_timestamp),
                'application_staging.fn_trg_etl_monitoring_after_success.populate_ft_quality_fpy',
                SQLERRM || ' (SQLSTATE: ' || SQLSTATE || ')',
                'ETL_SYSTEM'
            );
        END;

        BEGIN
            CALL application_data.populate_ft_oee(
                NEW.date_min,
                NEW.date_max,
                NEW.plant_id,
                NULL::bigint,
                9999999999999::bigint,
                'ETL_SYSTEM'::varchar
            );
        EXCEPTION WHEN OTHERS THEN
            -- Esecuzione indipendente da FPY: eventuale errore OEE viene solo loggato.
            INSERT INTO application_staging.etl_log_error (error_timestamp, error_src, error_msg, error_caller)
            VALUES (
                timezone('UTC', current_timestamp),
                'application_staging.fn_trg_etl_monitoring_after_success.populate_ft_oee',
                SQLERRM || ' (SQLSTATE: ' || SQLSTATE || ')',
                'ETL_SYSTEM'
            );
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_etl_monitoring_after_success ON application_staging.etl_monitoring;
CREATE TRIGGER trg_etl_monitoring_after_success
    AFTER UPDATE ON application_staging.etl_monitoring
    FOR EACH ROW
    WHEN (OLD.state IS DISTINCT FROM 'success' AND NEW.state = 'success')
    EXECUTE PROCEDURE application_staging.fn_trg_etl_monitoring_after_success();

-- DROP PROCEDURE application_staging.etl_sync_ft_rawdata(varchar, date, bool, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_ft_rawdata(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_target_date date DEFAULT NULL::date, IN p_dry_run boolean DEFAULT false, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes production data from SQL Server DWH DeviceOnStepGrouped view (via FDW) 
--    to application_data.ft_rawdata fact table.
--    Designed to run daily for the previous day's data for a specific line.
--
-- @Params:
--    - p_caller (VARCHAR, DEFAULT 'ETL_SYSTEM'): Identifier of the process/user calling this procedure.
--    - p_target_date (DATE, DEFAULT NULL): The production date to load. If NULL, loads yesterday's data.
--    - p_dry_run (BOOLEAN, DEFAULT FALSE): If TRUE, rolls back all changes after execution (for testing).
--
-- @Logic:
--    - Determines the line_id and plant_id from the DWH Line table
--    - Gets the ProductionTimeDateId for the target date
--    - For each record in DeviceOnStepGrouped for that date:
--      - Resolves all source IDs to target IDs via lookup tables
--      - Skips records that already exist (based on unique source key combination)
--      - Inserts new records with both source and target references
--
-- @Dependencies:
--    - Requires all lookup ETL procedures to be executed first (lk_plant, lk_line, lk_machine,
--      lk_component, lk_fixture, lk_shift_dwh, lk_code, lk_result)
--    - Creates plant partition (ft_rawdata_plant_<id>) and monthly partition (ft_rawdata_plant_<id>_<yyyymm>)
--      dynamically via application_data.create_plant_partition and create_monthly_partition
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_ft_rawdata';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_rejected    INTEGER := 0;
    lp_rows_no_fixture  INTEGER := 0;
    lp_rows_no_machine  INTEGER := 0;
    lp_rows_no_shift    INTEGER := 0;
    lp_rows_no_component INTEGER := 0;
    lp_rows_no_code     INTEGER := 0;
    lp_rows_no_result   INTEGER := 0;
    lp_rows_no_date     INTEGER := 0;
    lp_source_rows      INTEGER := 0;
    lp_target_date      DATE;
    lp_batch_id         VARCHAR(50);
    lp_reject_samples   INTEGER := 0;
    lp_reject_sample_limit INTEGER := 20;
    
    -- Variables for line/plant context
    v_line_id           BIGINT;
    v_plant_id          BIGINT;
    v_line_source_id    INTEGER;
    v_dwh_line_id       INTEGER;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_allowed_line_ids  BIGINT[];
    
    -- Variables for date resolution
    v_production_date_id INTEGER;
    v_day_id            NUMERIC(8);
    
    -- Variables for record processing
    rec                 RECORD;
    v_fixture_id        BIGINT;
    v_machine_id        BIGINT;
    v_machine_source_id INTEGER;  -- MachineIntId DWH (da fixture) per risolvere component_id per step
    v_component_id      BIGINT;
    v_shift_dwh_id      BIGINT;
    v_code_id           BIGINT;
    v_result_id         BIGINT;
    v_exists            BOOLEAN;
    v_is_redundant      BOOLEAN := false;
    v_redundant_lines   INTEGER := 0;
    v_redundancy_rank   INTEGER := 1;
    v_line_rank         INTEGER := 0;
    
    -- Partition variables (monthly partitions like ft_attendance)
    lp_year             INT;
    lp_month            INT;
    lp_partition_name   TEXT;
    lp_plant_partition_exists  BOOLEAN;
    lp_monthly_partition_exists BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Initialize and log procedure start
    lp_step := 0;
    
    -- Determine target date (default to yesterday)
    lp_target_date := COALESCE(p_target_date, CURRENT_DATE - INTERVAL '1 day');
    
    -- Generate batch ID for tracking
    lp_batch_id := 'RAWDATA_' || TO_CHAR(lp_target_date, 'YYYYMMDD') || '_' || TO_CHAR(lp_start_ts, 'HH24MISS');
    
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing production data from DWH DeviceOnStepGrouped for date: ' || lp_target_date || 
        ', batch_id: ' || lp_batch_id || ', dry_run: ' || p_dry_run || ', foreign_schema: ' || p_foreign_schema,
        p_caller
    );

    -- Step 1: Resolve process_key / plant context (line iteration happens at Step 3).
    -- Multi-line sources: DWH "Line" populated -> loop each mapped line (LineKey -> lk_line.line_code_erp) matching process_key.
    -- Single-line sources: DWH "Line" empty     -> require exactly 1 lk_line with process_key, then loop that single row.
    lp_step := 1;

    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    -- Plant is always resolved from SiteKey
    SELECT p.plant_id
    INTO v_plant_id
    FROM application_data.lk_plant p
    WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
      AND p.is_deleted = false
    LIMIT 1;

    IF v_plant_id IS NULL THEN
        lp_err_msg := 'No plant mapping found in lk_plant for SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                      ' (foreign_schema=' || p_foreign_schema || ').';
        CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_line ln
        WHERE ln.plant_id = v_plant_id
          AND ln.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            lp_err_msg := 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=' || p_foreign_schema ||
                          ' (SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                          '; ProcessKey=' || COALESCE(v_process_key, 'NULL') || '). Expected 1 lk_line, found ' ||
                          COALESCE(v_lines_expected::text, '0') || '.';
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE EXCEPTION '%', lp_err_msg;
        END IF;
    END IF;

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Source context: plant_id=' || COALESCE(v_plant_id::TEXT, 'NULL') ||
        ', process_key=' || COALESCE(v_process_key, 'NULL') ||
        ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END,
        p_caller
    );

    -- Step 2: Get ProductionTimeDateId for target date (use Year/Month/Day to avoid FDW date type issues)
    lp_step := 2;
    
    SELECT "Id"
    INTO v_production_date_id
    FROM "ProductionTimeDate"
    WHERE "Year" = EXTRACT(YEAR FROM lp_target_date)::INT
      AND "Month" = EXTRACT(MONTH FROM lp_target_date)::INT
      AND "Day" = EXTRACT(DAY FROM lp_target_date)::INT;
    
    IF v_production_date_id IS NULL THEN
        -- No data for this date in DWH - log and exit gracefully
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'END - No ProductionTimeDate record found in DWH for date: ' || lp_target_date || '. No data to process.',
            p_caller
        );
        
        RETURN;
    END IF;
    
    -- Calculate day_id in YYYYMMDD format
    v_day_id := TO_CHAR(lp_target_date, 'YYYYMMDD')::NUMERIC(8);
    
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Date context: ProductionTimeDateId=' || v_production_date_id || ', day_id=' || v_day_id,
        p_caller
    );

    -- Step 2.5: Ensure plant partition exists (ft_rawdata_plant_<id> PARTITION BY RANGE(day_id))
    lp_step := 2.5;
    lp_partition_name := 'ft_rawdata_plant_' || v_plant_id;
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'application_data' AND table_name = lp_partition_name
    ) INTO lp_plant_partition_exists;

    IF NOT lp_plant_partition_exists THEN
        BEGIN
            PERFORM application_data.create_plant_partition('ft_rawdata', 'day_id', v_plant_id);
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Partition created: ' || lp_partition_name,
                p_caller
            );
        EXCEPTION
            WHEN SQLSTATE '42P07' THEN
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Partition already exists: ' || lp_partition_name || ', not recreated',
                    p_caller
                );
            WHEN SQLSTATE 'P0001' THEN
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Partition already exists: ' || lp_partition_name || ', not recreated',
                    p_caller
                );
        WHEN OTHERS THEN
            lp_err_msg := 'Partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE;
        END;
    END IF;

    -- Step 2.6: Ensure monthly partition exists (ft_rawdata_plant_<id>_<yyyy><mm>)
    lp_step := 2.6;
    lp_year := EXTRACT(YEAR FROM lp_target_date)::INT;
    lp_month := EXTRACT(MONTH FROM lp_target_date)::INT;
    lp_partition_name := format('ft_rawdata_plant_%s_%s%s', v_plant_id, lp_year, lpad(lp_month::text, 2, '0'));

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'application_data' AND table_name = lp_partition_name
    ) INTO lp_monthly_partition_exists;

    IF NOT lp_monthly_partition_exists THEN
        BEGIN
            PERFORM application_data.create_monthly_partition(
                'ft_rawdata',
                'day_id',
                v_plant_id,
                lp_year,
                lp_month
            );
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Monthly partition created: ' || lp_partition_name,
                p_caller
            );
        EXCEPTION WHEN SQLSTATE '42P07' THEN
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Partition already exists: ' || lp_partition_name || ', not recreated',
                p_caller
            );
        WHEN OTHERS THEN
            lp_err_msg := 'Monthly partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE;
        END;
    END IF;

    -- Step 3: Record-driven pipeline
    -- 1) Read source dataset once for the date.
    -- 2) Resolve source machine from fixture.
    -- 3) Expand only to lines associated with that machine and allowed by process scope.
    -- 4) Resolve line-scoped target keys and insert idempotently.
    lp_step := 3;

    SELECT ARRAY_AGG(x.line_id ORDER BY x.line_id)
    INTO v_allowed_line_ids
    FROM (
        SELECT DISTINCT ln.line_id
        FROM "Line" dwh_line
        JOIN application_data.lk_line ln
          ON ln.line_code_erp = dwh_line."LineKey"
         AND ln.plant_id = v_plant_id
         AND ln.is_deleted = false
         AND ln.process_key = v_process_key
        WHERE v_has_lines

        UNION ALL

        SELECT DISTINCT ln.line_id
        FROM application_data.lk_line ln
        WHERE NOT v_has_lines
          AND ln.plant_id = v_plant_id
          AND ln.is_deleted = false
          AND ln.process_key = v_process_key
    ) x;

    v_lines_processed := COALESCE(array_length(v_allowed_line_ids, 1), 0);
    IF v_lines_processed = 0 THEN
        lp_err_msg := 'No lk_line mapping found for foreign_schema=' || p_foreign_schema ||
                      ' (SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                      '; ProcessKey=' || COALESCE(v_process_key, 'NULL') || ').';
        CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    FOR rec IN
        SELECT
            dosg."ProductionTimeDateId",
            dosg."CodeIntId",
            dosg."FixtureIntId",
            dosg."ResultIntId",
            dosg."SiteIntId",
            dosg."StepIntId",
            dosg."ShiftIntId",
            dosg."PassNumber",
            dosg."TotalProduction",
            dosg."CycleTimeAvgSec",
            dosg."AvgWorkTimeSec",
            dosg."TotalWorkTimeSec"
        FROM "DeviceOnStepGrouped" dosg
        WHERE dosg."ProductionTimeDateId" IN (SELECT v_production_date_id)
    LOOP
        lp_step := 3.1;
        lp_source_rows := lp_source_rows + 1;

        v_fixture_id := NULL;
        v_machine_id := NULL;
        v_machine_source_id := NULL;
        v_component_id := NULL;
        v_shift_dwh_id := NULL;
        v_code_id := NULL;
        v_result_id := NULL;
        v_is_redundant := false;
        v_redundant_lines := 0;
        v_redundancy_rank := 1;
        v_line_rank := 0;

        -- Resolve source machine from fixture at plant scope
        SELECT f.source_machine_id
        INTO v_machine_source_id
        FROM application_data.lk_fixture f
        WHERE f.source_id = rec."FixtureIntId"
          AND f.plant_id = v_plant_id
          AND f.source_machine_id IS NOT NULL
          AND f.is_deleted = false
        LIMIT 1;

        IF v_machine_source_id IS NULL THEN
            SELECT c.source_id INTO v_machine_source_id
            FROM application_data.lk_fixture f
            JOIN application_data.lk_component c ON c.component_id = f.component_id
            WHERE f.source_id = rec."FixtureIntId"
              AND f.plant_id = v_plant_id
              AND f.is_deleted = false
            LIMIT 1;
        END IF;

        IF v_machine_source_id IS NULL THEN
            lp_rows_no_fixture := lp_rows_no_fixture + 1;
            lp_rows_rejected := lp_rows_rejected + 1;
            INSERT INTO application_staging.etl_reject_row (
                procedure_name, caller, batch_id, foreign_schema, target_date,
                plant_id, line_id, process_key, source_table, reason_code, reason_detail, source_key
            ) VALUES (
                lp_procedure_name, p_caller, lp_batch_id, p_foreign_schema, lp_target_date,
                v_plant_id, NULL, v_process_key, 'DeviceOnStepGrouped',
                'NO_FIXTURE', 'No lk_fixture mapping to resolve DWH source_machine_id (MachineIntId) for FixtureIntId',
                jsonb_build_object(
                    'ProductionTimeDateId', rec."ProductionTimeDateId",
                    'ShiftIntId', rec."ShiftIntId",
                    'StepIntId', rec."StepIntId",
                    'FixtureIntId', rec."FixtureIntId",
                    'PassNumber', rec."PassNumber",
                    'ResultIntId', rec."ResultIntId",
                    'CodeIntId', rec."CodeIntId"
                )
            );
            CONTINUE;
        END IF;

        SELECT COUNT(DISTINCT c.line_id)
        INTO v_redundant_lines
        FROM application_data.lk_component c
        WHERE c.plant_id = v_plant_id
          AND c.source_id = v_machine_source_id
          AND c.line_id = ANY(v_allowed_line_ids)
          AND c.is_deleted = false;

        IF COALESCE(v_redundant_lines, 0) = 0 THEN
            lp_rows_no_machine := lp_rows_no_machine + 1;
            lp_rows_rejected := lp_rows_rejected + 1;
            INSERT INTO application_staging.etl_reject_row (
                procedure_name, caller, batch_id, foreign_schema, target_date,
                plant_id, line_id, process_key, source_table, reason_code, reason_detail, source_key
            ) VALUES (
                lp_procedure_name, p_caller, lp_batch_id, p_foreign_schema, lp_target_date,
                v_plant_id, NULL, v_process_key, 'DeviceOnStepGrouped',
                'NO_LINE_FROM_FIXTURE_MACHINE', 'Source machine from fixture is not mapped to allowed lines',
                jsonb_build_object(
                    'ProductionTimeDateId', rec."ProductionTimeDateId",
                    'ShiftIntId', rec."ShiftIntId",
                    'StepIntId', rec."StepIntId",
                    'FixtureIntId', rec."FixtureIntId",
                    'source_machine_id', v_machine_source_id
                )
            );
            CONTINUE;
        END IF;

        v_is_redundant := COALESCE(v_redundant_lines, 0) > 1;

        FOR line_ctx IN
            SELECT DISTINCT c.line_id
            FROM application_data.lk_component c
            WHERE c.plant_id = v_plant_id
              AND c.source_id = v_machine_source_id
              AND c.line_id = ANY(v_allowed_line_ids)
              AND c.is_deleted = false
            ORDER BY c.line_id
        LOOP
            v_line_id := line_ctx.line_id;
            v_line_rank := v_line_rank + 1;
            v_redundancy_rank := CASE WHEN v_is_redundant THEN v_line_rank ELSE 1 END;

            lp_step := 3.2;
            SELECT m.machine_id
            INTO v_machine_id
            FROM application_data.lk_machine m
            WHERE m.source_id = rec."StepIntId"
              AND m.plant_id = v_plant_id
              AND m.line_id = v_line_id
              AND m.is_deleted = false;
            IF v_machine_id IS NULL THEN
                lp_rows_no_machine := lp_rows_no_machine + 1;
                lp_rows_rejected := lp_rows_rejected + 1;
                CONTINUE;
            END IF;

            v_component_id := NULL;
            SELECT c.component_id INTO v_component_id
            FROM application_data.lk_component c
            WHERE c.machine_id = v_machine_id
              AND c.source_id = v_machine_source_id
              AND c.plant_id = v_plant_id
              AND c.line_id = v_line_id
              AND c.is_deleted = false;
            IF v_component_id IS NULL THEN
                lp_rows_no_component := lp_rows_no_component + 1;
                lp_rows_rejected := lp_rows_rejected + 1;
                CONTINUE;
            END IF;

            SELECT f.fixture_id INTO v_fixture_id
            FROM application_data.lk_fixture f
            WHERE f.source_id = rec."FixtureIntId"
              AND f.plant_id = v_plant_id
              AND f.component_id = v_component_id
              AND f.line_id = v_line_id
              AND f.is_deleted = false;
            IF v_fixture_id IS NULL THEN
                lp_rows_no_fixture := lp_rows_no_fixture + 1;
                lp_rows_rejected := lp_rows_rejected + 1;
                CONTINUE;
            END IF;

            lp_step := 3.3;
            SELECT s.shift_dwh_id
            INTO v_shift_dwh_id
            FROM application_data.lk_shift_dwh s
            WHERE s.source_id = rec."ShiftIntId"
              AND s.plant_id = v_plant_id
              AND s.line_id = v_line_id
              AND s.is_deleted = false;
            IF v_shift_dwh_id IS NULL THEN
                lp_rows_no_shift := lp_rows_no_shift + 1;
                lp_rows_rejected := lp_rows_rejected + 1;
                CONTINUE;
            END IF;

            lp_step := 3.4;
            IF rec."CodeIntId" IS NULL THEN
                lp_rows_no_code := lp_rows_no_code + 1;
            ELSE
                SELECT c.code_id
                INTO v_code_id
                FROM application_data.lk_code c
                WHERE c.source_id = rec."CodeIntId"
                  AND c.plant_id = v_plant_id
                  AND c.line_id = v_line_id
                  AND c.is_deleted = false;
                IF v_code_id IS NULL THEN
                    lp_rows_no_code := lp_rows_no_code + 1;
                END IF;
            END IF;

            lp_step := 3.5;
            IF rec."ResultIntId" IS NULL THEN
                lp_rows_no_result := lp_rows_no_result + 1;
            ELSE
                SELECT r.result_id
                INTO v_result_id
                FROM application_data.lk_result r
                WHERE r.source_id = rec."ResultIntId"
                  AND r.plant_id = v_plant_id
                  AND r.line_id = v_line_id
                  AND r.is_deleted = false;
                IF v_result_id IS NULL THEN
                    lp_rows_no_result := lp_rows_no_result + 1;
                END IF;
            END IF;

            lp_step := 3.6;
            SELECT EXISTS (
                SELECT 1 FROM application_data.ft_rawdata
                WHERE plant_id = v_plant_id
                  AND line_id = v_line_id
                  AND source_date_id = rec."ProductionTimeDateId"
                  AND source_step_id = rec."StepIntId"
                  AND source_fixture_id = rec."FixtureIntId"
                  AND source_shift_id = rec."ShiftIntId"
                  AND pass_number = rec."PassNumber"
                  AND COALESCE(process_key, '') = COALESCE(v_process_key, '')
                  AND COALESCE(source_code_id, -1) = COALESCE(rec."CodeIntId", -1)
                  AND COALESCE(source_result_id, -1) = COALESCE(rec."ResultIntId", -1)
            ) INTO v_exists;
            IF v_exists THEN
                UPDATE application_data.ft_rawdata
                SET
                    day_id = v_day_id,
                    machine_id = v_machine_id,
                    component_id = v_component_id,
                    fixture_id = v_fixture_id,
                    code_id = v_code_id,
                    result_id = v_result_id,
                    shift_dwh_id = v_shift_dwh_id,
                    process_key = v_process_key,
                    is_redundant = v_is_redundant,
                    redundancy_rank = v_redundancy_rank,
                    total_production = rec."TotalProduction",
                    cycle_time_avg_sec = rec."CycleTimeAvgSec",
                    work_time_avg_sec = rec."AvgWorkTimeSec",
                    work_time_total_sec = rec."TotalWorkTimeSec",
                    etl_batch_id = lp_batch_id,
                    etl_loaded_ts = lp_start_ts
                WHERE plant_id = v_plant_id
                  AND line_id = v_line_id
                  AND source_date_id = rec."ProductionTimeDateId"
                  AND source_step_id = rec."StepIntId"
                  AND source_fixture_id = rec."FixtureIntId"
                  AND source_shift_id = rec."ShiftIntId"
                  AND pass_number = rec."PassNumber"
                  AND COALESCE(process_key, '') = COALESCE(v_process_key, '')
                  AND COALESCE(source_code_id, -1) = COALESCE(rec."CodeIntId", -1)
                  AND COALESCE(source_result_id, -1) = COALESCE(rec."ResultIntId", -1)
                  AND (
                      day_id IS DISTINCT FROM v_day_id
                      OR machine_id IS DISTINCT FROM v_machine_id
                      OR component_id IS DISTINCT FROM v_component_id
                      OR fixture_id IS DISTINCT FROM v_fixture_id
                      OR code_id IS DISTINCT FROM v_code_id
                      OR result_id IS DISTINCT FROM v_result_id
                      OR shift_dwh_id IS DISTINCT FROM v_shift_dwh_id
                      OR process_key IS DISTINCT FROM v_process_key
                      OR is_redundant IS DISTINCT FROM v_is_redundant
                      OR redundancy_rank IS DISTINCT FROM v_redundancy_rank
                      OR total_production IS DISTINCT FROM rec."TotalProduction"
                      OR cycle_time_avg_sec IS DISTINCT FROM rec."CycleTimeAvgSec"
                      OR work_time_avg_sec IS DISTINCT FROM rec."AvgWorkTimeSec"
                      OR work_time_total_sec IS DISTINCT FROM rec."TotalWorkTimeSec"
                  );

                IF FOUND THEN
                    lp_rows_updated := lp_rows_updated + 1;
                ELSE
                    lp_rows_skipped := lp_rows_skipped + 1;
                END IF;
                CONTINUE;
            END IF;

            lp_step := 3.7;
            INSERT INTO application_data.ft_rawdata (
                source_date_id, source_code_id, source_fixture_id, source_result_id, source_site_id,
                source_step_id, source_shift_id, pass_number,
                day_id, plant_id, line_id, machine_id, component_id, fixture_id, code_id, result_id, shift_dwh_id,
                process_key, is_redundant, redundancy_rank,
                total_production, cycle_time_avg_sec, work_time_avg_sec, work_time_total_sec,
                etl_batch_id, etl_loaded_ts
            ) VALUES (
                rec."ProductionTimeDateId", rec."CodeIntId", rec."FixtureIntId", rec."ResultIntId", rec."SiteIntId",
                rec."StepIntId", rec."ShiftIntId", rec."PassNumber",
                v_day_id, v_plant_id, v_line_id, v_machine_id, v_component_id, v_fixture_id, v_code_id, v_result_id, v_shift_dwh_id,
                v_process_key, v_is_redundant, v_redundancy_rank,
                rec."TotalProduction", rec."CycleTimeAvgSec", rec."AvgWorkTimeSec", rec."TotalWorkTimeSec",
                lp_batch_id, lp_start_ts
            );

            lp_rows_inserted := lp_rows_inserted + 1;
        END LOOP;
    END LOOP;

    -- Step 4: Log procedure completion
    lp_step := 4;
    
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Production data synchronized for date ' || lp_target_date || '. ' ||
        'Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped (existing): ' || lp_rows_skipped || 
        ', Rejected (not loaded): ' || lp_rows_rejected ||
        ' [No_fixture=' || lp_rows_no_fixture ||
        ', No_machine_step=' || lp_rows_no_machine ||
        ', No_component_machine=' || lp_rows_no_component ||
        ', No_shift=' || lp_rows_no_shift || ']' ||
        ', No code: ' || lp_rows_no_code || ', No result: ' || lp_rows_no_result ||
        ', batch_id: ' || lp_batch_id ||
        CASE WHEN p_dry_run THEN ' [DRY RUN - ROLLING BACK]' ELSE '' END,
        p_caller
    );

    -- If dry run: persist summary (visible after rollback) then rollback
    IF p_dry_run THEN
        CALL application_staging.etl_log_error_write(
            lp_procedure_name,
            'DRY RUN summary (date=' || lp_target_date || ', schema=' || p_foreign_schema || '): ' ||
            'Source_rows_read=' || lp_source_rows ||
            ', Inserted=' || lp_rows_inserted ||
            ', Updated=' || lp_rows_updated ||
            ', Skipped_existing=' || lp_rows_skipped ||
            ', Rejected=' || lp_rows_rejected ||
            ' (No_fixture=' || lp_rows_no_fixture ||
            ', No_machine_step=' || lp_rows_no_machine ||
            ', No_component_machine=' || lp_rows_no_component ||
            ', No_shift=' || lp_rows_no_shift || ')' ||
            ', No_code=' || lp_rows_no_code ||
            ', No_result=' || lp_rows_no_result,
            p_caller
        );
        RAISE EXCEPTION 'DRY RUN COMPLETED - Rolling back all changes as requested. Would have inserted % records.', lp_rows_inserted;
    END IF;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_ft_rawdata(varchar, date, bool, text) IS 'Synchronizes production data from DWH DeviceOnStepGrouped to ft_rawdata fact table. Designed for daily execution for previous day data.';

-- DROP PROCEDURE application_staging.etl_sync_downtime(varchar, date, bool, text);
CREATE OR REPLACE PROCEDURE application_staging.etl_sync_downtime(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_target_date date DEFAULT NULL::date, IN p_dry_run boolean DEFAULT false, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description: Synchronizes Downtime from DWH [sp203_an].[Downtime] to application_data.ft_downtime.
--               Resolves shift_dwh_id, code_id, component_id via lk_shift_dwh, lk_code, lk_component.
-- @Notes:       Run after all lookup syncs and before etl_sync_ft_rawdata. Same date/partition logic as rawdata.
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_downtime';
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_step             NUMERIC := 0;
    lp_target_date      DATE;
    lp_batch_id         VARCHAR(100);
    lp_err_msg          VARCHAR(2000);
    lp_year             INT;
    lp_month            INT;
    lp_partition_name   TEXT;
    lp_plant_partition_exists  BOOLEAN;
    lp_monthly_partition_exists BOOLEAN;
    lp_rows_inserted    BIGINT := 0;
    lp_rows_skipped     BIGINT := 0;
    lp_source_rows      BIGINT := 0;
    lp_rows_rejected    BIGINT := 0;
    -- Keep counters aligned with ft_rawdata strict summary (some may remain 0 for downtime)
    lp_rows_no_fixture      BIGINT := 0;
    lp_rows_no_machine_step BIGINT := 0;
    lp_rows_no_shift    BIGINT := 0;
    lp_rows_no_component BIGINT := 0;
    lp_reject_samples   INT := 0;
    lp_reject_sample_limit INT := 20;
    v_plant_id          BIGINT;
    v_line_id           BIGINT;
    v_dwh_line_id       INTEGER;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_production_date_id INT;
    v_day_id            NUMERIC(8);
    v_shift_dwh_id      BIGINT;
    v_code_id           BIGINT;
    v_component_id      BIGINT;
    v_exists            BOOLEAN;
    v_datetime_start    TIMESTAMP;
    v_datetime_end      TIMESTAMP;
    rec                 RECORD;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    lp_step := 0;
    lp_target_date := COALESCE(p_target_date, CURRENT_DATE - INTERVAL '1 day');
    lp_batch_id := 'DOWNTIME_' || TO_CHAR(lp_target_date, 'YYYYMMDD') || '_' || TO_CHAR(lp_start_ts, 'HH24MISS');

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing Downtime from DWH for date: ' || lp_target_date ||
        ', batch_id: ' || lp_batch_id || ', dry_run: ' || p_dry_run || ', foreign_schema: ' || p_foreign_schema,
        p_caller
    );

    -- Step 1: process_key / plant context + line iteration (multi-line vs single-line source)
    lp_step := 1;

    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    -- Plant is always resolved from SiteKey
    SELECT p.plant_id
    INTO v_plant_id
    FROM application_data.lk_plant p
    WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
      AND p.is_deleted = false
    LIMIT 1;

    IF v_plant_id IS NULL THEN
        lp_err_msg := 'No plant mapping found in lk_plant for SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                      ' (foreign_schema=' || p_foreign_schema || ').';
        CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_line ln
        WHERE ln.plant_id = v_plant_id
          AND ln.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            lp_err_msg := 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=' || p_foreign_schema ||
                          ' (SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                          '; ProcessKey=' || COALESCE(v_process_key, 'NULL') || '). Expected 1 lk_line, found ' ||
                          COALESCE(v_lines_expected::text, '0') || '.';
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE EXCEPTION '%', lp_err_msg;
        END IF;
    END IF;

    -- Step 2: ProductionTimeDateId for target date
    lp_step := 2;
    SELECT "Id"
    INTO v_production_date_id
    FROM "ProductionTimeDate"
    WHERE "Year" = EXTRACT(YEAR FROM lp_target_date)::INT
      AND "Month" = EXTRACT(MONTH FROM lp_target_date)::INT
      AND "Day" = EXTRACT(DAY FROM lp_target_date)::INT;

    IF v_production_date_id IS NULL THEN
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'END - No ProductionTimeDate for date: ' || lp_target_date || '. No downtime data to process.',
            p_caller
        );
        RETURN;
    END IF;

    v_day_id := TO_CHAR(lp_target_date, 'YYYYMMDD')::NUMERIC(8);

    -- Step 2.5: Ensure plant partition (ft_downtime_plant_<id>)
    lp_step := 2.5;
    lp_partition_name := 'ft_downtime_plant_' || v_plant_id;
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'application_data' AND table_name = lp_partition_name
    ) INTO lp_plant_partition_exists;

    IF NOT lp_plant_partition_exists THEN
        BEGIN
            PERFORM application_data.create_plant_partition('ft_downtime', 'day_id', v_plant_id);
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Partition created: ' || lp_partition_name,
                p_caller
            );
        EXCEPTION
            WHEN SQLSTATE '42P07' THEN
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Partition already exists: ' || lp_partition_name || ', not recreated',
                    p_caller
                );
            WHEN SQLSTATE 'P0001' THEN
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    'Partition already exists: ' || lp_partition_name || ', not recreated',
                    p_caller
                );
        WHEN OTHERS THEN
            lp_err_msg := 'Partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE;
        END;
    END IF;

    -- Step 2.6: Ensure monthly partition (ft_downtime_plant_<id>_<yyyy><mm>)
    lp_step := 2.6;
    lp_year := EXTRACT(YEAR FROM lp_target_date)::INT;
    lp_month := EXTRACT(MONTH FROM lp_target_date)::INT;
    lp_partition_name := format('ft_downtime_plant_%s_%s%s', v_plant_id, lp_year, lpad(lp_month::text, 2, '0'));
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'application_data' AND table_name = lp_partition_name
    ) INTO lp_monthly_partition_exists;

    IF NOT lp_monthly_partition_exists THEN
        BEGIN
            PERFORM application_data.create_monthly_partition(
                'ft_downtime',
                'day_id',
                v_plant_id,
                lp_year,
                lp_month
            );
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Monthly partition created: ' || lp_partition_name,
                p_caller
            );
        EXCEPTION WHEN SQLSTATE '42P07' THEN
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                'Partition already exists: ' || lp_partition_name || ', not recreated',
                p_caller
            );
        WHEN OTHERS THEN
            lp_err_msg := 'Monthly partition creation failed: ' || lp_partition_name || ' — ' || SQLERRM;
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE;
        END;
    END IF;

    -- Step 3: Process Downtime records for the target date (loop per line)
    lp_step := 3;
    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = v_plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, NULL::int AS dwh_line_id
            FROM application_data.lk_line ln
            WHERE NOT v_has_lines
              AND ln.plant_id = v_plant_id
              AND ln.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_dwh_line_id := line_ctx.dwh_line_id;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Line context: line_id=' || COALESCE(v_line_id::text, 'NULL') ||
            ', plant_id=' || COALESCE(v_plant_id::text, 'NULL') ||
            ', dwh_line_id=' || COALESCE(v_dwh_line_id::text, 'NULL'),
            p_caller
        );

        FOR rec IN
            SELECT
                d."Id",
                d."SeverityEn",
                d."StreamEn",
                d."ToolName",
                d."Description",
                d."CodeIntId",
                d."MachineIntId",
                d."DateTimeStart",
                d."DateTimeEnd",
                d."IntervalTimeMs",
                d."ShiftIntId",
                d."ProductionTimeHalHourId",
                d."ProductionTimeDateId"
            FROM "Downtime" d
            -- FDW workaround: with dwh_remote2, '=' against PL/pgSQL scalar variable may return 0 rows.
            -- Use IN (SELECT var) to force correct evaluation.
            WHERE d."ProductionTimeDateId" IN (SELECT v_production_date_id)
              AND (
                  v_dwh_line_id IS NULL OR d."MachineIntId" IN (
                      -- Use local line-scoped mapping to avoid FDW correlated-subquery issues.
                      SELECT c.source_id
                      FROM application_data.lk_component c
                      WHERE c.plant_id = v_plant_id
                        AND c.line_id = v_line_id
                        AND c.is_deleted = false
                        AND c.source_id IS NOT NULL
                  )
              )
        LOOP
            lp_source_rows := lp_source_rows + 1;
            v_shift_dwh_id := NULL;
            v_code_id := NULL;
            v_component_id := NULL;
            v_datetime_start := (
            regexp_replace(
                regexp_replace(
                    regexp_replace(btrim(rec."DateTimeStart"::TEXT), '\s+', ' ', 'g'),
                    ':([0-9]{1,9})(AM|PM)$',
                    '.\1 \2'
                ),
                '\.([0-9]{6})[0-9]+ (AM|PM)$',
                '.\1 \2'
            )
        )::timestamp;
        v_datetime_end := (
            regexp_replace(
                regexp_replace(
                    regexp_replace(btrim(rec."DateTimeEnd"::TEXT), '\s+', ' ', 'g'),
                    ':([0-9]{1,9})(AM|PM)$',
                    '.\1 \2'
                ),
                '\.([0-9]{6})[0-9]+ (AM|PM)$',
                '.\1 \2'
            )
        )::timestamp;

        -- Resolve shift_dwh_id
        SELECT s.shift_dwh_id
        INTO v_shift_dwh_id
        FROM application_data.lk_shift_dwh s
        WHERE s.source_id = rec."ShiftIntId"
          AND s.line_id = v_line_id
          AND s.plant_id = v_plant_id
          AND s.is_deleted = false;

        IF v_shift_dwh_id IS NULL THEN
            lp_rows_no_shift := lp_rows_no_shift + 1;
            lp_rows_rejected := lp_rows_rejected + 1;
            INSERT INTO application_staging.etl_reject_row (
                procedure_name,
                caller,
                batch_id,
                foreign_schema,
                target_date,
                plant_id,
                line_id,
                process_key,
                source_table,
                reason_code,
                reason_detail,
                source_key
            ) VALUES (
                lp_procedure_name,
                p_caller,
                lp_batch_id,
                p_foreign_schema,
                lp_target_date,
                v_plant_id,
                v_line_id,
                v_process_key,
                'Downtime',
                'NO_SHIFT',
                'No lk_shift_dwh mapping for ShiftIntId',
                jsonb_build_object(
                    'DowntimeId', rec."Id",
                    'ShiftIntId', rec."ShiftIntId",
                    'MachineIntId', rec."MachineIntId",
                    'CodeIntId', rec."CodeIntId",
                    'ProductionTimeDateId', rec."ProductionTimeDateId"
                )
            );
            IF lp_reject_samples < lp_reject_sample_limit THEN
                lp_reject_samples := lp_reject_samples + 1;
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[REJECT_NO_SHIFT] DowntimeId=' || rec."Id" || ', ShiftIntId=' || rec."ShiftIntId" ||
                    ' - Reason: no lk_shift_dwh for line_id=' || v_line_id,
                    p_caller
                );
            END IF;
            CONTINUE;
        END IF;

        -- Resolve component_id (MachineIntId = source_id in lk_component; "Machine" in DWH maps to lk_component)
        SELECT c.component_id
        INTO v_component_id
        FROM application_data.lk_component c
        WHERE c.source_id = rec."MachineIntId"
          AND c.line_id = v_line_id
          AND c.plant_id = v_plant_id
          AND c.is_deleted = false;

        IF v_component_id IS NULL THEN
            lp_rows_no_component := lp_rows_no_component + 1;
            lp_rows_rejected := lp_rows_rejected + 1;
            INSERT INTO application_staging.etl_reject_row (
                procedure_name,
                caller,
                batch_id,
                foreign_schema,
                target_date,
                plant_id,
                line_id,
                process_key,
                source_table,
                reason_code,
                reason_detail,
                source_key
            ) VALUES (
                lp_procedure_name,
                p_caller,
                lp_batch_id,
                p_foreign_schema,
                lp_target_date,
                v_plant_id,
                v_line_id,
                v_process_key,
                'Downtime',
                'NO_COMPONENT_MACHINE',
                'No lk_component mapping for MachineIntId (component by machine)',
                jsonb_build_object(
                    'DowntimeId', rec."Id",
                    'MachineIntId', rec."MachineIntId",
                    'ShiftIntId', rec."ShiftIntId",
                    'CodeIntId', rec."CodeIntId",
                    'ProductionTimeDateId', rec."ProductionTimeDateId"
                )
            );
            IF lp_reject_samples < lp_reject_sample_limit THEN
                lp_reject_samples := lp_reject_samples + 1;
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[REJECT_NO_COMPONENT] DowntimeId=' || rec."Id" || ', MachineIntId=' || rec."MachineIntId" ||
                    ' - Reason: no lk_component for line_id=' || v_line_id || ', plant_id=' || v_plant_id,
                    p_caller
                );
            END IF;
            CONTINUE;
        END IF;

        -- Resolve code_id (nullable)
        IF rec."CodeIntId" IS NOT NULL THEN
            SELECT c.code_id
            INTO v_code_id
            FROM application_data.lk_code c
            WHERE c.source_id = rec."CodeIntId"
              AND c.line_id = v_line_id
              AND c.plant_id = v_plant_id
              AND c.is_deleted = false;
        END IF;

        -- Skip if already present
        SELECT EXISTS (
            SELECT 1 FROM application_data.ft_downtime
            WHERE plant_id = v_plant_id
              AND source_downtime_id = rec."Id"
        ) INTO v_exists;

        IF v_exists THEN
            lp_rows_skipped := lp_rows_skipped + 1;
            CONTINUE;
        END IF;

        -- Insert
        INSERT INTO application_data.ft_downtime (
            source_downtime_id,
            source_shift_id,
            source_production_time_hal_hour_id,
            source_production_time_date_id,
            source_code_id,
            source_component_id,
            plant_id,
            line_id,
            day_id,
            shift_dwh_id,
            code_id,
            component_id,
            severity_en,
            stream_en,
            tool_name,
            description,
            datetime_start,
            datetime_end,
            interval_time_ms,
            etl_batch_id,
            etl_loaded_ts
        ) VALUES (
            rec."Id",
            rec."ShiftIntId",
            rec."ProductionTimeHalHourId",
            rec."ProductionTimeDateId",
            rec."CodeIntId",
            rec."MachineIntId",
            v_plant_id,
            v_line_id,
            v_day_id,
            v_shift_dwh_id,
            v_code_id,
            v_component_id,
            rec."SeverityEn"::smallint,
            rec."StreamEn"::smallint,
            rec."ToolName",
            rec."Description",
            v_datetime_start,
            v_datetime_end,
            rec."IntervalTimeMs",
            lp_batch_id,
            lp_start_ts
        );
        lp_rows_inserted := lp_rows_inserted + 1;
        END LOOP;
    END LOOP;

    IF v_lines_processed = 0 THEN
        lp_err_msg := 'No lk_line mapping found for foreign_schema=' || p_foreign_schema ||
                      ' (SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                      '; ProcessKey=' || COALESCE(v_process_key, 'NULL') || ').';
        CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_step := 4;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Downtime synchronized for date ' || lp_target_date || '. ' ||
        'Inserted: ' || lp_rows_inserted || ', Skipped (existing): ' || lp_rows_skipped ||
        ', Rejected (not loaded): ' || lp_rows_rejected ||
        ' [No_fixture=' || lp_rows_no_fixture ||
        ', No_machine_step=' || lp_rows_no_machine_step ||
        ', No_component_machine=' || lp_rows_no_component ||
        ', No_shift=' || lp_rows_no_shift || ']' ||
        ', batch_id: ' || lp_batch_id ||
        CASE WHEN p_dry_run THEN ' [DRY RUN - ROLLING BACK]' ELSE '' END,
        p_caller
    );

    IF p_dry_run THEN
        CALL application_staging.etl_log_error_write(
            lp_procedure_name,
            'DRY RUN Downtime (date=' || lp_target_date || ', schema=' || p_foreign_schema || '): ' ||
            'Source_rows=' || lp_source_rows || ', Inserted=' || lp_rows_inserted ||
            ', Skipped=' || lp_rows_skipped ||
            ', Rejected=' || lp_rows_rejected ||
            ' (No_fixture=' || lp_rows_no_fixture ||
            ', No_machine_step=' || lp_rows_no_machine_step ||
            ', No_component_machine=' || lp_rows_no_component ||
            ', No_shift=' || lp_rows_no_shift || ')',
            p_caller
        );
        RAISE EXCEPTION 'DRY RUN COMPLETED - Rolling back downtime sync. Would have inserted % records.', lp_rows_inserted;
    END IF;

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_downtime(varchar, date, bool, text) IS 'Synchronizes Downtime from DWH [sp203_an].[Downtime] to ft_downtime. Run after lookups and before etl_sync_ft_rawdata.';

-- DROP PROCEDURE application_staging.etl_sync_lk_code(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_code(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Code data from SQL Server DWH (via FDW) to application_data.lk_code.
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_code';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_removed     INTEGER := 0;
    rec                 RECORD;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_removed_this_line INT;
    v_line_id           BIGINT;
    v_plant_id          BIGINT;
    v_code_id           BIGINT;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Resolve line_id/plant_id.
    lp_step := 0;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing codes from DWH Code table (foreign_schema=' || COALESCE(p_foreign_schema, '?') || ', process_key=' || COALESCE(v_process_key, 'NULL') || ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END || ')',
        p_caller
    );

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, ln.plant_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, ln.plant_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_plant_id := line_ctx.plant_id;

        -- Step 1: Loop through DWH Code records
        lp_step := 1;
        FOR rec IN 
            SELECT c."CodeIntId",
                   c."CodeKey",
                   c."Description",
                   c."CodeTypeIntId",
                   ct."CodeTypeKey",
                   ct."Description" AS "CodeTypeDescription"
            FROM "Code" c
            LEFT JOIN "CodeType" ct
              ON ct."CodeTypeIntId" = c."CodeTypeIntId"
        LOOP
            lp_step := 1.1;
        
        -- Check if code already exists by source_id and line_id
        SELECT code_id INTO v_code_id
        FROM application_data.lk_code
        WHERE source_id = rec."CodeIntId"
          AND line_id = v_line_id;

        -- Fallback check on business key (CodeKey + CodeTypeIntId) to avoid duplicates
        -- when source_id changes in DWH for the same logical code.
        IF v_code_id IS NULL THEN
            SELECT code_id INTO v_code_id
            FROM application_data.lk_code
            WHERE plant_id = v_plant_id
              AND line_id = v_line_id
              AND code_code = rec."CodeKey"
              AND code_type_source_id IS NOT DISTINCT FROM rec."CodeTypeIntId"
            LIMIT 1;
        END IF;
        
        IF v_code_id IS NOT NULL THEN
            -- Already synced - check if update is needed
            lp_step := 1.15;
            
            UPDATE application_data.lk_code
            SET code_ds = COALESCE(rec."Description", rec."CodeKey"),
                code_type_source_id = rec."CodeTypeIntId",
                source_codetype_key = rec."CodeTypeKey",
                source_codetype_description = rec."CodeTypeDescription",
                source_id = rec."CodeIntId"
            WHERE code_id = v_code_id
              AND (
                  code_ds IS DISTINCT FROM COALESCE(rec."Description", rec."CodeKey")
                  OR code_type_source_id IS DISTINCT FROM rec."CodeTypeIntId"
                  OR source_codetype_key IS DISTINCT FROM rec."CodeTypeKey"
                  OR source_codetype_description IS DISTINCT FROM rec."CodeTypeDescription"
                  OR source_id IS DISTINCT FROM rec."CodeIntId"
              );
            
            IF FOUND THEN
                lp_rows_updated := lp_rows_updated + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[UPDATED] Code: CodeKey=' || rec."CodeKey" || ', CodeIntId=' || rec."CodeIntId" || 
                    ', CodeTypeIntId=' || COALESCE(rec."CodeTypeIntId"::TEXT, 'NULL') ||
                    ' -> code_id=' || v_code_id || ', fields updated from DWH',
                    p_caller
                );
            ELSE
                lp_rows_skipped := lp_rows_skipped + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[SKIPPED] Code: CodeKey=' || rec."CodeKey" || ', CodeIntId=' || rec."CodeIntId" || 
                    ' - Reason: already synced, no changes detected (code_id=' || v_code_id || ')',
                    p_caller
                );
            END IF;
            
            v_code_id := NULL;
            CONTINUE;
        END IF;
        
        lp_step := 1.2;
        INSERT INTO application_data.lk_code (
            code_code,
            code_ds,
            plant_id,
            line_id,
            source_id,
            code_type_source_id,
            source_codetype_key,
            source_codetype_description,
            is_active,
            creation_ts,
            creator_user,
            last_user
        ) VALUES (
            rec."CodeKey",
            COALESCE(rec."Description", rec."CodeKey"),
            v_plant_id,
            v_line_id,
            rec."CodeIntId",
            rec."CodeTypeIntId",
            rec."CodeTypeKey",
            rec."CodeTypeDescription",
            true,
            lp_start_ts,
            '9999999999999 -- ' || p_caller,
            '9999999999999 -- ' || p_caller
        );
        
        lp_rows_inserted := lp_rows_inserted + 1;
        
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            '[INSERTED] Code: CodeKey=' || rec."CodeKey" || ', CodeIntId=' || rec."CodeIntId" || 
            ', CodeTypeIntId=' || COALESCE(rec."CodeTypeIntId"::TEXT, 'NULL') || 
            ', Description=' || COALESCE(rec."Description", 'NULL') || ' -> new code created',
            p_caller
        );
    END LOOP;

    -- Step 1.5: Coherence cleanup - mark codes for this line whose source_id is no longer in DWH Code
    lp_step := 1.5;
    WITH to_remove AS (
        UPDATE application_data.lk_code
        SET is_deleted = true,
            is_active = false,
            last_modified = timezone('UTC', current_timestamp),
            last_user = '9999999999999 -- ' || p_caller
        WHERE line_id = v_line_id
          AND source_id IS NOT NULL
          AND source_id NOT IN (SELECT "CodeIntId" FROM "Code")
          AND is_deleted = false
        RETURNING code_id
    )
    SELECT COUNT(*) INTO v_removed_this_line FROM to_remove;
    lp_rows_removed := lp_rows_removed + COALESCE(v_removed_this_line, 0);
    IF COALESCE(v_removed_this_line, 0) > 0 THEN
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            '[CLEANUP] Soft-deleted ' || v_removed_this_line || ' code(s) for line_id=' || v_line_id || ' (source_id no longer in DWH)',
            p_caller
        );
    END IF;
    END LOOP;

    IF v_lines_processed = 0 THEN
        RAISE EXCEPTION 'No lk_line mapping found for foreign_schema=% (SiteKey=%; ProcessKey=%).',
            p_foreign_schema,
            COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
            COALESCE(v_process_key, 'NULL');
    END IF;

    -- Step 2: Log completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Codes synchronized. Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped || ', Orphans removed: ' || lp_rows_removed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_code(varchar, text) IS 'Synchronizes Code data from DWH to lk_code';

-- DROP PROCEDURE application_staging.etl_sync_lk_component(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_component(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Machine data from SQL Server DWH (via FDW) to application_data.lk_component.
--    Uses MachineVsStep relationship to create component under the correct machine (step).
--    DWH Machine maps to PostgreSQL lk_component (component level under station).
--    Handles M:N relationship by creating one component per (Step, Machine) pair.
--    Sets is_primary_source=true for the first component of each Machine in the line.
--
-- @Params:
--    - p_caller (VARCHAR, DEFAULT 'ETL_SYSTEM'): Identifier of the process/user calling this procedure.
--
-- @Logic:
--    - For each MachineVsStep relationship:
--      - Find the lk_machine (from Step) and create lk_component (from Machine)
--      - If component with (machine_id, source_id) exists: update if description changed, skip if identical
--      - Otherwise: insert new component
--      - First component for each (line_id, source_id) gets is_primary_source=true
-- @Dependencies:
--    - Requires etl_sync_lk_machine to be executed first
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_component';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_removed     INTEGER := 0;
    rec                 RECORD;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_removed_this_line INT;
    v_machine_id        BIGINT;  -- Target lk_machine.machine_id (from Step)
    v_line_id           BIGINT;
    v_plant_id          BIGINT;
    v_dwh_line_id       INT;
    v_component_id      BIGINT;
    v_is_primary        BOOLEAN;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Resolve line/plant context.
    -- If DWH "Line" is empty (single-line source), resolve via lk_line.process_key = DWH Process.ProcessKey.
    lp_step := 0;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing components from DWH Machine table via MachineVsStep (foreign_schema=' || COALESCE(p_foreign_schema, '?') || ', process_key=' || COALESCE(v_process_key, 'NULL') || ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END || ')',
        p_caller
    );

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, ln.plant_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, ln.plant_id, NULL::int AS dwh_line_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_plant_id := line_ctx.plant_id;
        v_dwh_line_id := line_ctx.dwh_line_id;

        -- Step 1: Loop through DWH MachineVsStep.
        -- Multi-line: enforce DWH line scope via LineVsMachine.
        -- Single-line (BY_PROCESS): keep full scope (v_dwh_line_id IS NULL).
        lp_step := 1;
        FOR rec IN 
            SELECT 
                mvs."MachineIntId",
                mvs."StepIntId",
                mvs."IdealCycleTimeMs",
                m."MachineKey",
                m."Description" AS machine_description,
                m."DisplayOrder",
                lm.machine_id AS target_machine_id,
                lm.line_id,
                lm.plant_id
            FROM "MachineVsStep" mvs
            JOIN "Machine" m ON m."MachineIntId" = mvs."MachineIntId"
            LEFT JOIN "LineVsMachine" lvm ON lvm."MachineId" = m."MachineIntId"
            JOIN application_data.lk_machine lm ON lm.source_id = mvs."StepIntId" AND lm.line_id = v_line_id AND lm.is_deleted = false
            WHERE (v_dwh_line_id IS NULL OR lvm."LineId" = v_dwh_line_id)
            ORDER BY mvs."StepIntId", mvs."MachineIntId"
        LOOP
        lp_step := 1.1;
        v_machine_id := rec.target_machine_id;
        -- v_line_id, v_plant_id from Step 0 only; do not overwrite from rec (would mix lines across DWHs)
        
        -- Check if component already exists with this (machine_id, source_id) FOR THIS LINE
        SELECT component_id INTO v_component_id
        FROM application_data.lk_component
        WHERE machine_id = v_machine_id
          AND line_id = v_line_id
          AND plant_id = v_plant_id
          AND source_id = rec."MachineIntId"
          AND is_deleted = false;
        
        IF v_component_id IS NOT NULL THEN
            -- Already synced - check if update is needed (description changed)
            lp_step := 1.15;
            
            -- Try to update only if code/description/sort/cycle values are different
            UPDATE application_data.lk_component
            SET component_code = rec."MachineKey",
                component_ds = COALESCE(rec.machine_description, rec."MachineKey"),
                component_sort = rec."DisplayOrder",
                ideal_cycle_time_ms = rec."IdealCycleTimeMs",
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            WHERE component_id = v_component_id
              AND (
                  component_code IS DISTINCT FROM rec."MachineKey"
                  OR component_ds IS DISTINCT FROM COALESCE(rec.machine_description, rec."MachineKey")
                  OR component_sort IS DISTINCT FROM rec."DisplayOrder"
                  OR ideal_cycle_time_ms IS DISTINCT FROM rec."IdealCycleTimeMs"
              );
            
            IF FOUND THEN
                -- Description was different, update was made
                lp_rows_updated := lp_rows_updated + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[UPDATED] Component: MachineKey=' || rec."MachineKey" || ', MachineIntId=' || rec."MachineIntId" || 
                    ', StepIntId=' || rec."StepIntId" || ' -> component_id=' || v_component_id || ', description updated from DWH',
                    p_caller
                );
            ELSE
                -- No changes needed, skip
                lp_rows_skipped := lp_rows_skipped + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[SKIPPED] Component: MachineKey=' || rec."MachineKey" || ', MachineIntId=' || rec."MachineIntId" || 
                    ', StepIntId=' || rec."StepIntId" || ' - Reason: already synced, no changes detected (component_id=' || v_component_id || ')',
                    p_caller
                );
            END IF;
        ELSE
            lp_step := 1.2;
            -- Determine if this should be the primary source
            -- First component for this (line_id, source_id) gets is_primary_source=true
            v_is_primary := NOT EXISTS (
                SELECT 1 FROM application_data.lk_component
                WHERE line_id = v_line_id
                  AND source_id = rec."MachineIntId"
                  AND is_primary_source = true
                  AND is_deleted = false
            );
            
            lp_step := 1.3;
            -- Insert new component
            INSERT INTO application_data.lk_component (
                component_code,
                component_ds,
                component_sort,
                ideal_cycle_time_ms,
                machine_id,
                line_id,
                plant_id,
                source_id,
                is_primary_source,
                is_active,
                is_deleted,
                creation_ts,
                creator_user,
                last_modified,
                last_user
            ) VALUES (
                rec."MachineKey",
                COALESCE(rec.machine_description, rec."MachineKey"),
                rec."DisplayOrder",
                rec."IdealCycleTimeMs",
                v_machine_id,
                v_line_id,
                v_plant_id,
                rec."MachineIntId",
                v_is_primary,
                true,
                false,
                lp_start_ts,
                '9999999999999 -- ' || p_caller,
                lp_start_ts,
                '9999999999999 -- ' || p_caller
            );
            
            lp_rows_inserted := lp_rows_inserted + 1;
            
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[INSERTED] Component: MachineKey=' || rec."MachineKey" || ', MachineIntId=' || rec."MachineIntId" || ', StepIntId=' || rec."StepIntId" || ' -> new component created under machine_id=' || v_machine_id || ', is_primary_source=' || v_is_primary,
                p_caller
            );
        END IF;
        
        v_component_id := NULL;
    END LOOP;

    -- Step 1.5: Coherence cleanup - soft delete components for this line whose source_id (MachineIntId) is no longer in DWH.
    -- Order for coherence: 1) lk_fixture -> lk_component.
    lp_step := 1.5;
    WITH valid_machine_ids AS MATERIALIZED (
        -- Keep cleanup aligned with Step 1 scope:
        -- line-filtered in multi-line; full-scope in BY_PROCESS.
        SELECT DISTINCT mvs."MachineIntId"
        FROM "MachineVsStep" mvs
        JOIN "Machine" m ON m."MachineIntId" = mvs."MachineIntId"
        LEFT JOIN "LineVsMachine" lvm ON lvm."MachineId" = m."MachineIntId"
        JOIN application_data.lk_machine lm
          ON lm.source_id = mvs."StepIntId"
         AND lm.line_id = v_line_id
         AND lm.is_deleted = false
        WHERE (v_dwh_line_id IS NULL OR lvm."LineId" = v_dwh_line_id)
    ),
    orphan_components AS (
        SELECT c.component_id
        FROM application_data.lk_component c
        JOIN application_data.lk_machine lm ON c.machine_id = lm.machine_id AND c.plant_id = lm.plant_id
        WHERE lm.line_id = v_line_id
          AND c.line_id = v_line_id
          AND c.is_deleted = false
          AND c.source_id IS NOT NULL
          AND c.source_id NOT IN (SELECT "MachineIntId" FROM valid_machine_ids)
    ),
    soft_deleted_fixtures AS (
        UPDATE application_data.lk_fixture f
        SET is_deleted = true,
            is_active = false,
            last_modified = timezone('UTC', current_timestamp),
            last_user = '9999999999999 -- ' || p_caller
        FROM orphan_components oc
        WHERE f.component_id = oc.component_id
          AND f.is_deleted = false
        RETURNING f.fixture_id
    ),
    to_remove AS (
        UPDATE application_data.lk_component c
        SET is_deleted = true,
            is_active = false,
            last_modified = timezone('UTC', current_timestamp),
            last_user = '9999999999999 -- ' || p_caller
        FROM application_data.lk_machine lm
        WHERE c.machine_id = lm.machine_id
          AND lm.line_id = v_line_id
          AND c.source_id IS NOT NULL
          AND c.source_id NOT IN (SELECT "MachineIntId" FROM valid_machine_ids)
          AND c.is_deleted = false
        RETURNING c.component_id
    )
    SELECT COUNT(*) INTO v_removed_this_line FROM to_remove;
    lp_rows_removed := lp_rows_removed + COALESCE(v_removed_this_line, 0);
    IF COALESCE(v_removed_this_line, 0) > 0 THEN
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            '[CLEANUP] Soft-deleted ' || v_removed_this_line || ' component(s) for line_id=' || v_line_id || ' (source_id no longer in DWH for this line)',
            p_caller
        );
    END IF;

    END LOOP;

    IF v_lines_processed = 0 THEN
        RAISE EXCEPTION 'No lk_line mapping found for foreign_schema=% (SiteKey=%; ProcessKey=%).',
            p_foreign_schema,
            COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
            COALESCE(v_process_key, 'NULL');
    END IF;

    -- Step 2: Log procedure completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Components synchronized. Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped || ', Orphans removed: ' || lp_rows_removed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_component(varchar, text) IS 'Synchronizes Machine data from DWH to lk_component via MachineVsStep, handling M:N to hierarchy transformation';

-- DROP PROCEDURE application_staging.etl_sync_lk_fixture(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_fixture(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description:
--    Crea una riga in lk_fixture per ogni coppia (Fixture DWH, lk_component).
--    Una fixture sorgente è associata a una Machine (MachineIntId); quella machine è replicata per step
--    in lk_component. Qui replichiamo anche la fixture: stessa source_id (FixtureIntId), più righe con
--    component_id diversi (uno per step). In ft_rawdata si userà fixture_id = lookup (source_id, component_id).
--
-- @Logic:
--    - Per ogni Fixture in DWH: per ogni lk_component con source_id = MachineIntId della fixture,
--      inserire o aggiornare una riga in lk_fixture (source_id, component_id, fixture_code, ...).
--    - Cleanup: rimuovere righe lk_fixture per questa linea la cui (source_id, component_id) non è più valida.
-- @Dependencies:
--    - Requires etl_sync_lk_component to be executed first
--    - Requires patch: uk_lk_fixture replaced by uk_lk_fixture_source_component (plant_id, line_id, source_id, component_id)
-- ============================================================================================================
DECLARE
    lp_procedure_name    VARCHAR(100) := 'application_staging.etl_sync_lk_fixture';
    lp_step              NUMERIC := 0;
    lp_err_msg           VARCHAR(2000);
    lp_start_ts          TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted     INTEGER := 0;
    lp_rows_updated      INTEGER := 0;
    lp_rows_skipped      INTEGER := 0;
    lp_rows_no_component INTEGER := 0;
    lp_rows_removed      INTEGER := 0;
    v_fixture_id         BIGINT;
    rec                  RECORD;
    comp_rec             RECORD;
    line_ctx             RECORD;
    v_lines_processed    INT := 0;
    v_lines_expected     INT;
    v_removed_this_line  INT;
    v_line_id            BIGINT;
    v_plant_id           BIGINT;
    v_dwh_line_id        INT;
    v_process_key        TEXT;
    v_has_lines          BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Resolve process_key and detect if DWH Line is populated (multi-line vs single-line source).
    lp_step := 0;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing fixtures from DWH (one row per component/step, foreign_schema=' || COALESCE(p_foreign_schema, '?') ||
        ', process_key=' || COALESCE(v_process_key, 'NULL') ||
        ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END || ')',
        p_caller
    );

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, ln.plant_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, ln.plant_id, NULL::int AS dwh_line_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_plant_id := line_ctx.plant_id;
        v_dwh_line_id := line_ctx.dwh_line_id;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Line context: line_id=' || COALESCE(v_line_id::text, 'NULL') ||
            ', plant_id=' || COALESCE(v_plant_id::text, 'NULL') ||
            ', dwh_line_id=' || COALESCE(v_dwh_line_id::text, 'NULL'),
            p_caller
        );

        -- Step 1: Per ogni Fixture DWH, per ogni lk_component di quella Machine, upsert lk_fixture (THIS line only)
        lp_step := 1;
        FOR rec IN
            SELECT
                f."FixtureIntId",
                f."FixtureKey",
                f."Desciption",
                f."MachineIntId"
            FROM "Fixture" f
            WHERE (
                v_dwh_line_id IS NULL OR f."MachineIntId" IN (
                    -- Use local line-scoped mapping to avoid FDW correlated-subquery issues.
                    SELECT c.source_id
                    FROM application_data.lk_component c
                    WHERE c.plant_id = v_plant_id
                      AND c.line_id = v_line_id
                      AND c.is_deleted = false
                      AND c.source_id IS NOT NULL
                )
            )
        LOOP
            lp_step := 1.1;
            -- Tutti i component (uno per step) per questa Machine
            FOR comp_rec IN
                SELECT c.component_id
                FROM application_data.lk_component c
                WHERE c.source_id = rec."MachineIntId"
                  AND c.plant_id = v_plant_id
                  AND c.line_id = v_line_id
                  AND c.is_deleted = false
            LOOP
                lp_step := 1.2;
                SELECT lf.fixture_id INTO v_fixture_id
                FROM application_data.lk_fixture lf
                WHERE lf.source_id = rec."FixtureIntId"
                  AND lf.line_id = v_line_id
                  AND lf.component_id = comp_rec.component_id
                  AND lf.is_deleted = false;

                IF v_fixture_id IS NOT NULL THEN
                    UPDATE application_data.lk_fixture
                    SET fixture_code = rec."FixtureKey",
                        fixture_ds = COALESCE(rec."Desciption", rec."FixtureKey"),
                        source_machine_id = rec."MachineIntId"
                    WHERE fixture_id = v_fixture_id
                      AND (
                          fixture_code IS DISTINCT FROM rec."FixtureKey"
                          OR fixture_ds IS DISTINCT FROM COALESCE(rec."Desciption", rec."FixtureKey")
                          OR source_machine_id IS DISTINCT FROM rec."MachineIntId"
                      );
                    IF FOUND THEN
                        lp_rows_updated := lp_rows_updated + 1;
                    ELSE
                        lp_rows_skipped := lp_rows_skipped + 1;
                    END IF;
                    v_fixture_id := NULL;
                ELSE
                    lp_step := 1.3;
                    INSERT INTO application_data.lk_fixture (
                        fixture_code,
                        fixture_ds,
                        component_id,
                        line_id,
                        plant_id,
                        source_id,
                        source_machine_id,
                        is_active,
                        creation_ts,
                        creator_user,
                        last_user
                    ) VALUES (
                        rec."FixtureKey",
                        COALESCE(rec."Desciption", rec."FixtureKey"),
                        comp_rec.component_id,
                        v_line_id,
                        v_plant_id,
                        rec."FixtureIntId",
                        rec."MachineIntId",
                        true,
                        lp_start_ts,
                        '9999999999999 -- ' || p_caller,
                        '9999999999999 -- ' || p_caller
                    );
                    lp_rows_inserted := lp_rows_inserted + 1;
                END IF;
            END LOOP;
        END LOOP;

        -- Step 1.5: Cleanup - rimuovere righe (source_id, component_id) non più valide per questa linea
        lp_step := 1.5;
        WITH to_remove AS (
            UPDATE application_data.lk_fixture lf
            SET is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            WHERE lf.line_id = v_line_id
              AND lf.source_id IS NOT NULL
              AND lf.is_deleted = false
              AND NOT EXISTS (
                  SELECT 1
                  FROM "Fixture" f
                  JOIN application_data.lk_component c ON c.source_id = f."MachineIntId" AND c.line_id = v_line_id AND c.is_deleted = false
                  WHERE f."FixtureIntId" = lf.source_id
                    AND c.component_id = lf.component_id
              )
            RETURNING lf.fixture_id
        )
        SELECT COUNT(*) INTO v_removed_this_line FROM to_remove;
        lp_rows_removed := lp_rows_removed + COALESCE(v_removed_this_line, 0);
        IF COALESCE(v_removed_this_line, 0) > 0 THEN
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[CLEANUP] Soft-deleted ' || v_removed_this_line || ' fixture row(s) for line_id=' || v_line_id || ' (source_id+component_id no longer valid)',
                p_caller
            );
        END IF;
    END LOOP;

    IF v_lines_processed = 0 THEN
        RAISE EXCEPTION 'No lk_line mapping found for foreign_schema=% (SiteKey=%; ProcessKey=%).',
            p_foreign_schema,
            COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
            COALESCE(v_process_key, 'NULL');
    END IF;

    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Fixtures synchronized. Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped || ', Orphans removed: ' || lp_rows_removed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_fixture(varchar, text) IS 'Synchronizes Fixture from DWH to lk_fixture: one row per (fixture source, component/step) for ft_rawdata fixture_id per step';

-- DROP PROCEDURE application_staging.etl_sync_lk_line(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_line(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Line data from SQL Server DWH (via FDW) to application_data.lk_line.
--    Maps DWH Line.LineKey to lk_line via line_code_erp.
--    Updates source_id to maintain traceability between source and target systems.
--
-- @Params:
--    - p_caller (VARCHAR, DEFAULT 'ETL_SYSTEM'): Identifier of the process/user calling this procedure.
--
-- @Logic:
--    - For each Line in DWH, find lk_line where line_code_erp = Line.LineKey and plant matches DWH Site
--    - If found: update lk_line.source_id
-- @Dependencies:
--    - Requires etl_sync_lk_plant to be executed first (plant source_id must be set)
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_line';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_no_mapping  INTEGER := 0;
    lp_rows_conflict    INTEGER := 0;
    rec                 RECORD;
    v_target_line_code  VARCHAR(50);
    v_target_plant_id   BIGINT;
    v_conflict_exists   BOOLEAN;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
    v_rows_set          INT;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Log procedure start
    lp_step := 0;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing lines from DWH Line table using mapping (foreign_schema=' || p_foreign_schema || ')',
        p_caller
    );

    -- Resolve ProcessKey (single-row table in DWH) and detect if DWH Line is populated
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    IF v_process_key IS NULL THEN
        lp_err_msg := 'Cannot run mapping: DWH Process.ProcessKey is NULL (foreign_schema=' || p_foreign_schema || ').';
        CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    -- Single-line mode: DWH Line is empty -> cannot update source_id; ensure lk_line.process_key is set.
    IF NOT v_has_lines THEN
        SELECT p.plant_id
        INTO v_target_plant_id
        FROM application_data.lk_plant p
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
        LIMIT 1;

        IF v_target_plant_id IS NULL THEN
            lp_err_msg := 'No plant mapping found in lk_plant for SiteKey=' || COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL') ||
                          ' (foreign_schema=' || p_foreign_schema || ').';
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE EXCEPTION '%', lp_err_msg;
        END IF;

        -- BY_PROCESS safety: do NOT auto-set process_key.
        -- Require that exactly one lk_line row for this plant is already configured with this ProcessKey.
        IF v_process_key IS NULL THEN
            lp_err_msg := 'Cannot run BY_PROCESS mapping: DWH Process.ProcessKey is NULL (foreign_schema=' || p_foreign_schema || ').';
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE EXCEPTION '%', lp_err_msg;
        END IF;

        SELECT COUNT(*)
        INTO v_rows_set
        FROM application_data.lk_line ln
        WHERE ln.plant_id = v_target_plant_id
          AND ln.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_rows_set <> 1 THEN
            lp_err_msg := 'BY_PROCESS mapping not configured or ambiguous: expected exactly 1 lk_line row with plant_id=' || v_target_plant_id ||
                          ' and process_key=' || v_process_key || ', found ' || COALESCE(v_rows_set::text, '0') || '. ' ||
                          'Set lk_line.process_key manually for the intended line.';
            CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
            RAISE EXCEPTION '%', lp_err_msg;
        END IF;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'END (BY_PROCESS) - DWH Line is empty. lk_line.process_key mapping found (plant_id=' || v_target_plant_id || ', process_key=' || v_process_key || ').',
            p_caller
        );
        RETURN;
    END IF;

    -- Step 1: Loop over DWH Line; match lk_line by line_code_erp = Line.LineKey and plant from Site (no LineVsMachine/Machine needed).
    lp_step := 1;
    FOR rec IN 
        SELECT DISTINCT ON (l."Id", ln.line_id)
            l."Id"   AS line_id,
            l."LineKey",
            ln.line_id   AS target_line_id,
            ln.plant_id  AS target_plant_id,
            ln.line_code AS target_line_code
        FROM "Line" l
        JOIN application_data.lk_plant p ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1) AND p.is_deleted = false
        JOIN application_data.lk_line ln ON ln.line_code_erp = l."LineKey" AND ln.plant_id = p.plant_id AND ln.is_deleted = false
          AND ln.process_key = v_process_key
        ORDER BY l."Id", ln.line_id
    LOOP
        lp_step := 1.1;
        v_target_line_code := rec.target_line_code;
        v_target_plant_id := rec.target_plant_id;

        lp_step := 1.2;
        -- Update line with source_id (same source_id in different DWHs is allowed: distinguished by line_code/plant)
        UPDATE application_data.lk_line
        SET source_id = rec.line_id,
            process_key = COALESCE(process_key, v_process_key),
            last_modified = timezone('UTC', current_timestamp),
            last_user = '9999999999999 -- ' || p_caller
        WHERE line_id = rec.target_line_id
          AND plant_id = rec.target_plant_id
          AND is_deleted = false
          AND (source_id IS NULL OR source_id != rec.line_id OR process_key IS NULL);

        IF FOUND THEN
            lp_rows_updated := lp_rows_updated + 1;
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[UPDATED] Line: LineKey=' || rec."LineKey" || ', Line.Id=' || rec.line_id || ' -> line_code_erp match, line_id=' || rec.target_line_id || ', source_id set',
                p_caller
            );
        ELSE
            IF EXISTS (
                SELECT 1 FROM application_data.lk_line
                WHERE line_id = rec.target_line_id
                  AND plant_id = rec.target_plant_id
                  AND source_id = rec.line_id
                  AND is_deleted = false
            ) THEN
                lp_rows_skipped := lp_rows_skipped + 1;
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[SKIPPED] Line: LineKey=' || rec."LineKey" || ', Line.Id=' || rec.line_id || ' -> line_id=' || rec.target_line_id || ' - already synced with same source_id',
                    p_caller
                );
            ELSE
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[NO_MATCH] Line: LineKey=' || rec."LineKey" || ', Line.Id=' || rec.line_id || ' - lk_line line_id=' || rec.target_line_id || ' not updated',
                    p_caller
                );
            END IF;
        END IF;

        v_target_line_code := NULL;
        v_target_plant_id := NULL;
    END LOOP;

    -- Step 2: Log procedure completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Lines synchronized. Updated: ' || lp_rows_updated ||
        ', Skipped: ' || lp_rows_skipped ||
        ', No mapping: ' || lp_rows_no_mapping ||
        ', Conflicts: ' || lp_rows_conflict,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_line(varchar, text) IS 'Synchronizes Line data from DWH to lk_line: matches Line.LineKey to lk_line.line_code_erp, updates source_id for traceability';

-- DROP PROCEDURE application_staging.etl_sync_lk_machine(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_machine(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Step data from SQL Server DWH (via FDW) to application_data.lk_machine.
--    Creates new lk_machine records if they don't exist, or updates source_id if they do.
--    DWH Step maps to PostgreSQL lk_machine (station/step level).
--    Also populates is_start_step and is_end_step from DWH.
--
-- @Params:
--    - p_caller (VARCHAR, DEFAULT 'ETL_SYSTEM'): Identifier of the process/user calling this procedure.
--
-- @Logic:
--    - For each Step in DWH linked to a synced line via the chain:
--      Step -> MachineVsStep -> Machine -> LineVsMachine -> Line -> lk_line (source_id)
--      - If lk_machine with same (line_id, source_id) exists: update if description or flags changed, skip if identical
--      - If lk_machine with same (line_id, machine_code) exists but no source_id: update source_id and flags
--      - Otherwise: insert new lk_machine
-- @Dependencies:
--    - Requires etl_sync_lk_line to be executed first (line source_id must be set)
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_machine';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_removed     INTEGER := 0;
    rec                 RECORD;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_removed_this_line INT;
    v_line_id           BIGINT;
    v_plant_id          BIGINT;
    v_dwh_line_id       INT;
    v_machine_id        BIGINT;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Resolve process_key and detect if DWH Line is populated (multi-line vs single-line source).
    lp_step := 0;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing machines from DWH Step table (foreign_schema=' || COALESCE(p_foreign_schema, '?') ||
        ', process_key=' || COALESCE(v_process_key, 'NULL') ||
        ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END || ')',
        p_caller
    );

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, ln.plant_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, ln.plant_id, NULL::int AS dwh_line_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_plant_id := line_ctx.plant_id;
        v_dwh_line_id := line_ctx.dwh_line_id;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Line context: line_id=' || COALESCE(v_line_id::text, 'NULL') ||
            ', plant_id=' || COALESCE(v_plant_id::text, 'NULL') ||
            ', dwh_line_id=' || COALESCE(v_dwh_line_id::text, 'NULL'),
            p_caller
        );

        -- Step 1: Loop through DWH Step records (THIS line only).
        -- Multi-line mode: restrict to steps whose machines belong to v_dwh_line_id via LineVsMachine.
        -- Single-line mode: load all steps (no LineVsMachine filter).
        lp_step := 1;
        FOR rec IN
            (
                -- Standard path only: steps linked to machines (line-scoped in multi-line mode).
                SELECT DISTINCT
                    s."StepIntId",
                    s."StepKey",
                    s."Description" AS step_description,
                    s."IsStartStep",
                    s."IsEndStep",
                    s."DisplayOrder"
                FROM "Step" s
                JOIN "MachineVsStep" mvs ON mvs."StepIntId" = s."StepIntId"
                JOIN "Machine" m ON m."MachineIntId" = mvs."MachineIntId"
                LEFT JOIN "LineVsMachine" lvm ON lvm."MachineId" = m."MachineIntId"
                WHERE (v_dwh_line_id IS NULL OR lvm."LineId" = v_dwh_line_id)
            )
        LOOP
            lp_step := 1.1;
            -- v_line_id, v_plant_id from Step 0 only; do not overwrite from rec (would mix lines across DWHs)

            -- Check if machine already exists with this source_id FOR THIS LINE
            SELECT machine_id INTO v_machine_id
            FROM application_data.lk_machine
            WHERE line_id = v_line_id
              AND source_id = rec."StepIntId"
              AND is_deleted = false;

            IF v_machine_id IS NOT NULL THEN
                -- Already synced - check if update is needed (description or flags changed)
                lp_step := 1.15;

                -- Try to update only if values are different
                UPDATE application_data.lk_machine
                SET machine_code = rec."StepKey",
                    machine_ds = COALESCE(rec.step_description, rec."StepKey"),
                    is_start_step = (rec."IsStartStep" = 1),
                    is_end_step = (rec."IsEndStep" = 1),
                    machine_sort = rec."DisplayOrder",
                    last_modified = timezone('UTC', current_timestamp),
                    last_user = '9999999999999 -- ' || p_caller
                WHERE machine_id = v_machine_id
                  AND (
                      machine_code IS DISTINCT FROM rec."StepKey"
                      OR
                      machine_ds IS DISTINCT FROM COALESCE(rec.step_description, rec."StepKey")
                      OR is_start_step IS DISTINCT FROM (rec."IsStartStep" = 1)
                      OR is_end_step IS DISTINCT FROM (rec."IsEndStep" = 1)
                      OR machine_sort IS DISTINCT FROM rec."DisplayOrder"
                  );

                IF FOUND THEN
                    lp_rows_updated := lp_rows_updated + 1;

                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        '[UPDATED] Machine: StepKey=' || rec."StepKey" || ', StepIntId=' || rec."StepIntId" ||
                        ', is_start=' || rec."IsStartStep" || ', is_end=' || rec."IsEndStep" ||
                        ' -> machine_id=' || v_machine_id || ', description/flags updated from DWH',
                        p_caller
                    );
                ELSE
                    lp_rows_skipped := lp_rows_skipped + 1;

                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        '[SKIPPED] Machine: StepKey=' || rec."StepKey" || ', StepIntId=' || rec."StepIntId" ||
                        ', line_id=' || v_line_id || ' - Reason: already synced, no changes detected (machine_id=' || v_machine_id || ')',
                        p_caller
                    );
                END IF;
            ELSE
                lp_step := 1.2;
                -- Check if machine exists by code (also handles soft-deleted rows and source_id changes)
                SELECT machine_id INTO v_machine_id
                FROM application_data.lk_machine
                WHERE line_id = v_line_id
                  AND machine_code = rec."StepKey"
                LIMIT 1;

                IF v_machine_id IS NOT NULL THEN
                    -- Update (or reactivate) existing machine with source_id, description and step flags
                    UPDATE application_data.lk_machine
                    SET source_id = rec."StepIntId",
                        machine_code = rec."StepKey",
                        machine_ds = COALESCE(rec.step_description, rec."StepKey"),
                        is_start_step = (rec."IsStartStep" = 1),
                        is_end_step = (rec."IsEndStep" = 1),
                        machine_sort = rec."DisplayOrder",
                        is_deleted = false,
                        is_active = true,
                        last_modified = timezone('UTC', current_timestamp),
                        last_user = '9999999999999 -- ' || p_caller
                    WHERE machine_id = v_machine_id;

                    lp_rows_updated := lp_rows_updated + 1;

                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        '[UPDATED] Machine: StepKey=' || rec."StepKey" || ', StepIntId=' || rec."StepIntId" ||
                        ', is_start=' || rec."IsStartStep" || ', is_end=' || rec."IsEndStep" ||
                        ' -> machine_id=' || v_machine_id || ', source_id/description/flags set (was missing source_id)',
                        p_caller
                    );
                ELSE
                    lp_step := 1.3;
                    -- Insert new machine with step flags
                    INSERT INTO application_data.lk_machine (
                        machine_code,
                        machine_ds,
                        line_id,
                        plant_id,
                        source_id,
                        is_start_step,
                        is_end_step,
                        machine_sort,
                        is_active,
                        is_deleted,
                        creation_ts,
                        creator_user,
                        last_modified,
                        last_user
                    ) VALUES (
                        rec."StepKey",
                        COALESCE(rec.step_description, rec."StepKey"),
                        v_line_id,
                        v_plant_id,
                        rec."StepIntId",
                        (rec."IsStartStep" = 1),
                        (rec."IsEndStep" = 1),
                        rec."DisplayOrder",
                        true,
                        false,
                        lp_start_ts,
                        '9999999999999 -- ' || p_caller,
                        lp_start_ts,
                        '9999999999999 -- ' || p_caller
                    );

                    lp_rows_inserted := lp_rows_inserted + 1;

                    INSERT INTO application_staging.etl_log_operation (
                        operation_timestamp, operation_src, operation_msg, operation_caller
                    ) VALUES (
                        timezone('UTC', current_timestamp),
                        lp_procedure_name,
                        '[INSERTED] Machine: StepKey=' || rec."StepKey" || ', StepIntId=' || rec."StepIntId" || ', is_start=' || rec."IsStartStep" || ', is_end=' || rec."IsEndStep" || ' -> new machine created for line_id=' || v_line_id,
                        p_caller
                    );
                END IF;
            END IF;

            v_machine_id := NULL;
        END LOOP;

        -- Step 1.5: Coherence cleanup - delete lk_machine for this line whose source_id is no longer in DWH Step.
        -- Order for FK: 1) lk_result -> lk_machine, 2) lk_component -> lk_machine, 3) lk_machine.
        lp_step := 1.5;
        WITH valid_step_ids AS MATERIALIZED (
            SELECT s."StepIntId"
            FROM "Step" s
            JOIN "MachineVsStep" mvs ON mvs."StepIntId" = s."StepIntId"
            JOIN "Machine" mc ON mc."MachineIntId" = mvs."MachineIntId"
            LEFT JOIN "LineVsMachine" lvm ON lvm."MachineId" = mc."MachineIntId"
            WHERE (v_dwh_line_id IS NULL OR lvm."LineId" = v_dwh_line_id)
        ),
        orphan_machines AS (
            SELECT m.machine_id, m.plant_id
            FROM application_data.lk_machine m
            WHERE m.line_id = v_line_id
              AND m.source_id IS NOT NULL
              AND m.source_id NOT IN (SELECT "StepIntId" FROM valid_step_ids)
        ),
        soft_deleted_results AS (
            UPDATE application_data.lk_result r
            SET is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            FROM orphan_machines om
            WHERE r.machine_id = om.machine_id
              AND r.plant_id = om.plant_id
              AND r.is_deleted = false
            RETURNING r.result_id
        ),
        soft_deleted_components AS (
            UPDATE application_data.lk_component c
            SET is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            FROM orphan_machines om
            WHERE c.machine_id = om.machine_id
              AND c.plant_id = om.plant_id
              AND c.is_deleted = false
            RETURNING c.component_id
        ),
        to_remove AS (
            UPDATE application_data.lk_machine m
            SET is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            WHERE m.line_id = v_line_id
              AND m.source_id IS NOT NULL
              AND m.source_id NOT IN (SELECT "StepIntId" FROM valid_step_ids)
              AND m.is_deleted = false
            RETURNING m.machine_id
        )
        SELECT COUNT(*) INTO v_removed_this_line FROM to_remove;
        lp_rows_removed := lp_rows_removed + COALESCE(v_removed_this_line, 0);
        IF COALESCE(v_removed_this_line, 0) > 0 THEN
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[CLEANUP] Soft-deleted ' || v_removed_this_line || ' machine(s) for line_id=' || v_line_id || ' (source_id no longer in DWH Step for this line)',
                p_caller
            );
        END IF;
    END LOOP;

    IF v_lines_processed = 0 THEN
        RAISE EXCEPTION 'No lk_line mapping found for foreign_schema=% (SiteKey=%; ProcessKey=%).',
            p_foreign_schema,
            COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
            COALESCE(v_process_key, 'NULL');
    END IF;

    -- Step 2: Log procedure completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Machines synchronized. Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped || ', Orphans removed: ' || lp_rows_removed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_machine(varchar, text) IS 'Synchronizes Step data from DWH to lk_machine with proper line association and step flags';

-- DROP PROCEDURE application_staging.etl_sync_lk_plant(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_plant(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Site data from SQL Server DWH (via FDW) to application_data.lk_plant.
--    Updates source_id to maintain traceability between source and target systems.
--
-- @Params:
--    - p_caller (VARCHAR, DEFAULT 'ETL_SYSTEM'): Identifier of the process/user calling this procedure.
--
-- @Logic:
--    - For each Site in DWH, find matching plant by plant_code = SiteKey
--    - If found: update source_id if not already set
--    - If not found: log warning (manual plant creation required)
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_plant';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    rec                 RECORD;
BEGIN
    -- Point unqualified source object references (e.g. "Site") to the desired FDW schema.
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Log procedure start
    lp_step := 0;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing plants from DWH Site table (foreign_schema=' || p_foreign_schema || ')',
        p_caller
    );

    -- Step 1: Loop through DWH Site records
    lp_step := 1;
    FOR rec IN 
        SELECT "SiteIntId", "SiteKey", "Description"
        FROM "Site"
    LOOP
        lp_step := 1.1;
        
        -- Try to update matching plant by plant_code
        UPDATE application_data.lk_plant
        SET source_id = rec."SiteIntId",
            last_modified = timezone('UTC', current_timestamp),
            last_user = '9999999999999 -- ' || p_caller
        WHERE plant_code = rec."SiteKey"
          AND is_deleted = false
          AND (source_id IS NULL OR source_id != rec."SiteIntId");
        
        IF FOUND THEN
            lp_rows_updated := lp_rows_updated + 1;
            
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[UPDATED] Plant: SiteKey=' || rec."SiteKey" || ', SiteIntId=' || rec."SiteIntId" || ' -> source_id set',
                p_caller
            );
        ELSE
            -- Check if plant exists but already has correct source_id
            IF EXISTS (
                SELECT 1 FROM application_data.lk_plant 
                WHERE plant_code = rec."SiteKey" 
                  AND source_id = rec."SiteIntId"
                  AND is_deleted = false
            ) THEN
                lp_rows_skipped := lp_rows_skipped + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[SKIPPED] Plant: SiteKey=' || rec."SiteKey" || ', SiteIntId=' || rec."SiteIntId" || ' - Reason: already synced with same source_id',
                    p_caller
                );
            ELSE
                -- Plant not found - log warning
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[NO_MATCH] Plant: SiteKey=' || rec."SiteKey" || ', SiteIntId=' || rec."SiteIntId" || ' - Reason: no plant with plant_code=' || rec."SiteKey" || ' found in lk_plant. Manual creation required.',
                    p_caller
                );
            END IF;
        END IF;
    END LOOP;

    -- Step 2: Log procedure completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Plants synchronized. Updated: ' || lp_rows_updated || ', Skipped (already synced): ' || lp_rows_skipped,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_plant(varchar, text) IS 'Synchronizes Site data from DWH to lk_plant, updating source_id for traceability';

-- DROP PROCEDURE application_staging.etl_sync_lk_production_time_date(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_production_time_date(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description: 
--    Syncs [sp203_an].[ProductionTimeDate] from DWH to application_data.lk_production_time_date.
--    The calendar is stored per line_id to avoid cross-line source_id collisions.
--    For each mapped line, the procedure loads the full source calendar (line-scoped idempotent upsert).
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_production_time_date';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    rec                 RECORD;
    line_ctx            RECORD;
    v_id_day            NUMERIC(8);
    v_has_lines         BOOLEAN;
    v_process_key       TEXT;
    v_site_key          TEXT;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    lp_step := 0;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing ProductionTimeDate from DWH (line-scoped) (foreign_schema=' || p_foreign_schema || ')',
        p_caller
    );

    lp_step := 0.1;
    SELECT "SiteKey" INTO v_site_key FROM "Site" LIMIT 1;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = v_site_key
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE(v_site_key, 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    lp_step := 1;
    FOR line_ctx IN
        (
            -- Multi-line mode: each DWH line is mapped through line_code_erp and process_key.
            SELECT ln.line_id, ln.plant_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = v_site_key
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line mode: DWH Line empty, process is mapped to exactly one lk_line.
            SELECT ln.line_id, ln.plant_id, NULL::int AS dwh_line_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = v_site_key
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Line context: line_id=' || line_ctx.line_id || ', plant_id=' || line_ctx.plant_id ||
            ', dwh_line_id=' || COALESCE(line_ctx.dwh_line_id::text, 'NULL'),
            p_caller
        );

        FOR rec IN
            SELECT "Id", "Year", "Month", "Day", "Weekday", "WeekNumber", "Quarter"
            FROM "ProductionTimeDate"
        LOOP
            lp_step := 1.1;
            -- Build date from Year/Month/Day (FDW may return "Date" as free text).
            v_id_day := (rec."Year" * 10000 + rec."Month" * 100 + rec."Day")::NUMERIC(8);

            -- 1) Try update by (line_id, source_id)
            lp_step := 1.2;
            UPDATE application_data.lk_production_time_date
            SET production_date = make_date(rec."Year", rec."Month", rec."Day"),
                id_day = v_id_day,
                year_num = rec."Year",
                month_num = rec."Month",
                day_num = rec."Day",
                weekday_name = rec."Weekday",
                week_number = rec."WeekNumber",
                quarter_num = rec."Quarter"
            WHERE line_id = line_ctx.line_id
              AND source_id = rec."Id"
              AND (id_day IS DISTINCT FROM v_id_day
                   OR year_num IS DISTINCT FROM rec."Year"
                   OR month_num IS DISTINCT FROM rec."Month"
                   OR day_num IS DISTINCT FROM rec."Day"
                   OR weekday_name IS DISTINCT FROM rec."Weekday"
                   OR week_number IS DISTINCT FROM rec."WeekNumber"
                   OR quarter_num IS DISTINCT FROM rec."Quarter");

            IF FOUND THEN
                lp_rows_updated := lp_rows_updated + 1;
                CONTINUE;
            END IF;

            -- 2) If the day already exists for this line with a different source_id, align source_id.
            lp_step := 1.25;
            UPDATE application_data.lk_production_time_date
            SET source_id = rec."Id",
                production_date = make_date(rec."Year", rec."Month", rec."Day"),
                year_num = rec."Year",
                month_num = rec."Month",
                day_num = rec."Day",
                weekday_name = rec."Weekday",
                week_number = rec."WeekNumber",
                quarter_num = rec."Quarter"
            WHERE line_id = line_ctx.line_id
              AND id_day = v_id_day
              AND source_id <> rec."Id";

            IF FOUND THEN
                lp_rows_updated := lp_rows_updated + 1;
                CONTINUE;
            END IF;

            -- 3) Insert new line-scoped calendar row (idempotent).
            lp_step := 1.3;
            INSERT INTO application_data.lk_production_time_date (
                line_id, source_id, production_date, id_day, year_num, month_num, day_num,
                weekday_name, week_number, quarter_num
            ) VALUES (
                line_ctx.line_id, rec."Id", make_date(rec."Year", rec."Month", rec."Day"), v_id_day,
                rec."Year", rec."Month", rec."Day",
                rec."Weekday", rec."WeekNumber", rec."Quarter"
            )
            ON CONFLICT (line_id, source_id)
            DO UPDATE SET
                production_date = EXCLUDED.production_date,
                id_day = EXCLUDED.id_day,
                year_num = EXCLUDED.year_num,
                month_num = EXCLUDED.month_num,
                day_num = EXCLUDED.day_num,
                weekday_name = EXCLUDED.weekday_name,
                week_number = EXCLUDED.week_number,
                quarter_num = EXCLUDED.quarter_num;

            IF FOUND THEN
                lp_rows_inserted := lp_rows_inserted + 1;
            ELSE
                lp_rows_skipped := lp_rows_skipped + 1;
            END IF;
        END LOOP;
    END LOOP;

    IF v_lines_processed = 0 THEN
        lp_err_msg := 'No lk_line mapping found for foreign_schema=' || p_foreign_schema ||
                      ' (SiteKey=' || COALESCE(v_site_key, 'NULL') ||
                      '; ProcessKey=' || COALESCE(v_process_key, 'NULL') || ').';
        CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;

    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - ProductionTimeDate synchronized. Inserted: ' || lp_rows_inserted ||
        ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped ||
        ', Lines processed: ' || v_lines_processed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_production_time_date(varchar, text) IS 'Syncs DWH ProductionTimeDate to lk_production_time_date by line_id. Replicates source calendar on each mapped line.';

-- DROP PROCEDURE application_staging.etl_sync_lk_result(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_result(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Result data from SQL Server DWH (via FDW) to application_data.lk_result.
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_result';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_no_machine  INTEGER := 0;
    lp_rows_removed     INTEGER := 0;
    rec                 RECORD;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_removed_this_line INT;
    v_line_id           BIGINT;
    v_plant_id          BIGINT;
    v_result_id         BIGINT;
    v_machine_id        BIGINT;
    v_dwh_line_id       INT;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Resolve process_key and detect if DWH Line is populated (multi-line vs single-line source).
    lp_step := 0;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing results from DWH Result table (foreign_schema=' || COALESCE(p_foreign_schema, '?') ||
        ', process_key=' || COALESCE(v_process_key, 'NULL') ||
        ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END || ')',
        p_caller
    );

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, ln.plant_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, ln.plant_id, NULL::int AS dwh_line_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_plant_id := line_ctx.plant_id;
        v_dwh_line_id := line_ctx.dwh_line_id;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Line context: line_id=' || COALESCE(v_line_id::text, 'NULL') ||
            ', plant_id=' || COALESCE(v_plant_id::text, 'NULL') ||
            ', dwh_line_id=' || COALESCE(v_dwh_line_id::text, 'NULL'),
            p_caller
        );

        -- Step 1: Loop through DWH Result records (filtered by line when DWH Line is populated) (THIS line only)
        lp_step := 1;
        FOR rec IN
            SELECT "ResultIntId", "ResultKey", "Description", "IsGood", "StepIntId"
            FROM "Result"
            WHERE (
                v_dwh_line_id IS NULL OR "StepIntId" IN (
                    -- Use local line-scoped mapping to avoid FDW correlated-subquery issues.
                    SELECT m.source_id
                    FROM application_data.lk_machine m
                    WHERE m.plant_id = v_plant_id
                      AND m.line_id = v_line_id
                      AND m.is_deleted = false
                      AND m.source_id IS NOT NULL
                )
            )
        LOOP
        lp_step := 1.1;
        
        -- Find machine_id from StepIntId (DWH Step -> lk_machine via source_id)
        SELECT machine_id INTO v_machine_id
        FROM application_data.lk_machine
        WHERE source_id = rec."StepIntId"
          AND line_id = v_line_id
          AND is_deleted = false;
        
        IF v_machine_id IS NULL THEN
            lp_rows_no_machine := lp_rows_no_machine + 1;
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[NO_MACHINE] Result: ResultKey=' || rec."ResultKey" || ', ResultIntId=' || rec."ResultIntId" || 
                ', StepIntId=' || rec."StepIntId" || ' - No matching machine found, loading with machine_id=NULL',
                p_caller
            );
        END IF;
        
        lp_step := 1.2;
        -- Check if result already exists by source_id and line_id
        SELECT result_id INTO v_result_id
        FROM application_data.lk_result
        WHERE source_id = rec."ResultIntId"
          AND line_id = v_line_id;
        
        IF v_result_id IS NOT NULL THEN
            -- Already synced - check if update is needed
            lp_step := 1.15;
            
            UPDATE application_data.lk_result
            SET result_ds = COALESCE(rec."Description", rec."ResultKey"),
                is_good = (rec."IsGood" = 1),
                machine_id = v_machine_id,
                step_source_id = rec."StepIntId"
            WHERE result_id = v_result_id
              AND (
                  result_ds IS DISTINCT FROM COALESCE(rec."Description", rec."ResultKey")
                  OR is_good IS DISTINCT FROM (rec."IsGood" = 1)
                  OR machine_id IS DISTINCT FROM v_machine_id
                  OR step_source_id IS DISTINCT FROM rec."StepIntId"
              );
            
            IF FOUND THEN
                lp_rows_updated := lp_rows_updated + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[UPDATED] Result: ResultKey=' || rec."ResultKey" || ', ResultIntId=' || rec."ResultIntId" || 
                    ', IsGood=' || COALESCE(rec."IsGood"::TEXT, 'NULL') || ', StepIntId=' || COALESCE(rec."StepIntId"::TEXT, 'NULL') ||
                    ' -> result_id=' || v_result_id || ', fields updated from DWH',
                    p_caller
                );
            ELSE
                lp_rows_skipped := lp_rows_skipped + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[SKIPPED] Result: ResultKey=' || rec."ResultKey" || ', ResultIntId=' || rec."ResultIntId" || 
                    ' - Reason: already synced, no changes detected (result_id=' || v_result_id || ')',
                    p_caller
                );
            END IF;
            
            v_result_id := NULL;
            CONTINUE;
        END IF;
        
        lp_step := 1.3;
        INSERT INTO application_data.lk_result (
            result_code,
            result_ds,
            is_good,
            machine_id,
            step_source_id,
            plant_id,
            line_id,
            source_id,
            is_active,
            creation_ts,
            creator_user,
            last_user
        ) VALUES (
            rec."ResultKey",
            COALESCE(rec."Description", rec."ResultKey"),
            (rec."IsGood" = 1),
            v_machine_id,
            rec."StepIntId",
            v_plant_id,
            v_line_id,
            rec."ResultIntId",
            true,
            lp_start_ts,
            '9999999999999 -- ' || p_caller,
            '9999999999999 -- ' || p_caller
        );
        
        lp_rows_inserted := lp_rows_inserted + 1;
        
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            '[INSERTED] Result: ResultKey=' || rec."ResultKey" || ', ResultIntId=' || rec."ResultIntId" || 
            ', IsGood=' || COALESCE(rec."IsGood"::TEXT, 'NULL') || ', StepIntId=' || COALESCE(rec."StepIntId"::TEXT, 'NULL') ||
            ' -> machine_id=' || COALESCE(v_machine_id::TEXT, 'NULL') || ', Description=' || COALESCE(rec."Description", 'NULL') || ' -> new result created',
            p_caller
        );
        END LOOP;

        -- Step 1.5: Coherence cleanup - mark results for this line whose source_id is no longer in DWH Result
        lp_step := 1.5;
        WITH valid_result_ids AS MATERIALIZED (
            SELECT r."ResultIntId"
            FROM "Result" r
            WHERE (
                v_dwh_line_id IS NULL OR r."StepIntId" IN (
                    -- Use local line-scoped mapping to avoid FDW correlated-subquery issues.
                    SELECT m.source_id
                    FROM application_data.lk_machine m
                    WHERE m.plant_id = v_plant_id
                      AND m.line_id = v_line_id
                      AND m.is_deleted = false
                      AND m.source_id IS NOT NULL
                )
            )
        ),
        to_remove AS (
            UPDATE application_data.lk_result
            SET is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            WHERE line_id = v_line_id
              AND source_id IS NOT NULL
              AND source_id NOT IN (SELECT "ResultIntId" FROM valid_result_ids)
              AND is_deleted = false
            RETURNING result_id
        )
        SELECT COUNT(*) INTO v_removed_this_line FROM to_remove;
        lp_rows_removed := lp_rows_removed + COALESCE(v_removed_this_line, 0);
        IF COALESCE(v_removed_this_line, 0) > 0 THEN
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[CLEANUP] Soft-deleted ' || v_removed_this_line || ' result(s) for line_id=' || v_line_id || ' (source_id no longer in DWH)',
                p_caller
            );
        END IF;
    END LOOP;

    IF v_lines_processed = 0 THEN
        RAISE EXCEPTION 'No lk_line mapping found for foreign_schema=% (SiteKey=%; ProcessKey=%).',
            p_foreign_schema,
            COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
            COALESCE(v_process_key, 'NULL');
    END IF;

    -- Step 2: Log completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Results synchronized. Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped || ', No machine: ' || lp_rows_no_machine || ', Orphans removed: ' || lp_rows_removed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_result(varchar, text) IS 'Synchronizes Result data from DWH to lk_result';

-- DROP PROCEDURE application_staging.etl_sync_lk_shift(varchar, text);

CREATE OR REPLACE PROCEDURE application_staging.etl_sync_lk_shift(IN p_caller character varying DEFAULT 'ETL_SYSTEM'::character varying, IN p_foreign_schema text DEFAULT 'dwh_remote'::text)
 LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Author:     ETL System
-- @Project:    DWH Integration
-- @Description: 
--    Synchronizes Shift data from SQL Server DWH (via FDW) to application_data.lk_shift_dwh.
--
-- @Params:
--    - p_caller (VARCHAR, DEFAULT 'ETL_SYSTEM'): Identifier of the process/user calling this procedure.
-- ============================================================================================================
DECLARE
    lp_procedure_name   VARCHAR(100) := 'application_staging.etl_sync_lk_shift';
    lp_step             NUMERIC := 0;
    lp_err_msg          VARCHAR(2000);
    lp_start_ts         TIMESTAMP := timezone('UTC', current_timestamp);
    lp_rows_inserted    INTEGER := 0;
    lp_rows_updated     INTEGER := 0;
    lp_rows_skipped     INTEGER := 0;
    lp_rows_removed     INTEGER := 0;
    rec                 RECORD;
    line_ctx            RECORD;
    v_lines_processed   INT := 0;
    v_lines_expected    INT;
    v_removed_this_line INT;
    v_line_id           BIGINT;
    v_plant_id          BIGINT;
    v_shift_id          BIGINT;
    v_dwh_line_id       INT;
    v_process_key       TEXT;
    v_has_lines         BOOLEAN;
BEGIN
    PERFORM set_config(
        'search_path',
        quote_ident(p_foreign_schema) || ', application_staging, application_data, public',
        true
    );

    -- Step 0: Resolve process_key and detect if DWH Line is populated (multi-line vs single-line source).
    lp_step := 0;
    SELECT "ProcessKey" INTO v_process_key FROM "Process" LIMIT 1;
    v_has_lines := EXISTS (SELECT 1 FROM "Line");

    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        lp_start_ts,
        lp_procedure_name,
        'START - Synchronizing shifts from DWH Shift table (foreign_schema=' || COALESCE(p_foreign_schema, '?') ||
        ', process_key=' || COALESCE(v_process_key, 'NULL') ||
        ', mode=' || CASE WHEN v_has_lines THEN 'DWH_LINE' ELSE 'BY_PROCESS' END || ')',
        p_caller
    );

    -- BY_PROCESS safety: DWH Line empty implies exactly 1 lk_line must be configured for this ProcessKey.
    IF NOT v_has_lines THEN
        SELECT COUNT(*)
        INTO v_lines_expected
        FROM application_data.lk_plant p
        JOIN application_data.lk_line ln
          ON ln.plant_id = p.plant_id
         AND ln.is_deleted = false
        WHERE p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
          AND p.is_deleted = false
          AND ln.process_key = v_process_key;

        IF v_lines_expected <> 1 THEN
            RAISE EXCEPTION 'BY_PROCESS mapping not configured or ambiguous for foreign_schema=% (SiteKey=%; ProcessKey=%). Expected 1 lk_line, found %.',
                p_foreign_schema,
                COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
                COALESCE(v_process_key, 'NULL'),
                COALESCE(v_lines_expected::text, '0');
        END IF;
    END IF;

    FOR line_ctx IN
        (
            -- Multi-line: iterate each DWH line mapped via (LineKey -> lk_line.line_code_erp) and matching process_key.
            SELECT ln.line_id, ln.plant_id, dwh_line."Id" AS dwh_line_id
            FROM "Line" dwh_line
            JOIN application_data.lk_plant p
              ON p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
             AND p.is_deleted = false
            JOIN application_data.lk_line ln
              ON ln.line_code_erp = dwh_line."LineKey"
             AND ln.plant_id = p.plant_id
             AND ln.is_deleted = false
             AND ln.process_key = v_process_key
            WHERE v_has_lines

            UNION ALL

            -- Single-line: DWH Line empty -> iterate the unique lk_line bound by process_key.
            SELECT ln.line_id, ln.plant_id, NULL::int AS dwh_line_id
            FROM application_data.lk_plant p
            JOIN application_data.lk_line ln
              ON ln.plant_id = p.plant_id
             AND ln.is_deleted = false
            WHERE NOT v_has_lines
              AND p.plant_code = (SELECT "SiteKey" FROM "Site" LIMIT 1)
              AND p.is_deleted = false
              AND ln.process_key = v_process_key
        )
    LOOP
        v_lines_processed := v_lines_processed + 1;
        v_line_id := line_ctx.line_id;
        v_plant_id := line_ctx.plant_id;
        v_dwh_line_id := line_ctx.dwh_line_id;

        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            'Line context: line_id=' || COALESCE(v_line_id::text, 'NULL') ||
            ', plant_id=' || COALESCE(v_plant_id::text, 'NULL') ||
            ', dwh_line_id=' || COALESCE(v_dwh_line_id::text, 'NULL'),
            p_caller
        );

        -- Step 1: Loop through DWH Shift records (DWH Shift is NOT line-scoped).
        -- We therefore replicate each Shift row for each target line_id.
        -- Note: StartTime/EndTime are text from DWH (SQL Server datetime format), need to extract time part
        lp_step := 1;
        FOR rec IN
            SELECT "ShiftIntId", "ShiftKey", "Description",
                   CASE
                       WHEN "StartTime" LIKE '%PM' AND SUBSTRING("StartTime" FROM '\d{2}:\d{2}:\d{2}')::TIME < '12:00:00'::TIME
                       THEN (SUBSTRING("StartTime" FROM '\d{2}:\d{2}:\d{2}')::TIME + INTERVAL '12 hours')::TIME
                       WHEN "StartTime" LIKE '%AM' AND SUBSTRING("StartTime" FROM '\d{2}:\d{2}:\d{2}')::TIME >= '12:00:00'::TIME
                       THEN (SUBSTRING("StartTime" FROM '\d{2}:\d{2}:\d{2}')::TIME - INTERVAL '12 hours')::TIME
                       ELSE SUBSTRING("StartTime" FROM '\d{2}:\d{2}:\d{2}')::TIME
                   END AS "StartTime",
                   CASE
                       WHEN "EndTime" LIKE '%PM' AND SUBSTRING("EndTime" FROM '\d{2}:\d{2}:\d{2}')::TIME < '12:00:00'::TIME
                       THEN (SUBSTRING("EndTime" FROM '\d{2}:\d{2}:\d{2}')::TIME + INTERVAL '12 hours')::TIME
                       WHEN "EndTime" LIKE '%AM' AND SUBSTRING("EndTime" FROM '\d{2}:\d{2}:\d{2}')::TIME >= '12:00:00'::TIME
                       THEN (SUBSTRING("EndTime" FROM '\d{2}:\d{2}:\d{2}')::TIME - INTERVAL '12 hours')::TIME
                       ELSE SUBSTRING("EndTime" FROM '\d{2}:\d{2}:\d{2}')::TIME
                   END AS "EndTime"
            FROM "Shift"
        LOOP
        lp_step := 1.1;
        
        -- Check if shift already exists by source_id and line_id
        SELECT shift_dwh_id INTO v_shift_id
        FROM application_data.lk_shift_dwh
        WHERE source_id = rec."ShiftIntId"
          AND line_id = v_line_id;
        
        IF v_shift_id IS NOT NULL THEN
            -- Already synced - check if update is needed
            lp_step := 1.15;
            
            UPDATE application_data.lk_shift_dwh
            SET shift_ds = COALESCE(rec."Description", rec."ShiftKey"),
                shift_start_time = rec."StartTime",
                shift_end_time = rec."EndTime"
            WHERE shift_dwh_id = v_shift_id
              AND (
                  shift_ds IS DISTINCT FROM COALESCE(rec."Description", rec."ShiftKey")
                  OR shift_start_time IS DISTINCT FROM rec."StartTime"
                  OR shift_end_time IS DISTINCT FROM rec."EndTime"
              );
            
            IF FOUND THEN
                lp_rows_updated := lp_rows_updated + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[UPDATED] Shift: ShiftKey=' || rec."ShiftKey" || ', ShiftIntId=' || rec."ShiftIntId" || 
                    ' -> shift_id=' || v_shift_id || ', description/times updated from DWH',
                    p_caller
                );
            ELSE
                lp_rows_skipped := lp_rows_skipped + 1;
                
                INSERT INTO application_staging.etl_log_operation (
                    operation_timestamp, operation_src, operation_msg, operation_caller
                ) VALUES (
                    timezone('UTC', current_timestamp),
                    lp_procedure_name,
                    '[SKIPPED] Shift: ShiftKey=' || rec."ShiftKey" || ', ShiftIntId=' || rec."ShiftIntId" || 
                    ' - Reason: already synced, no changes detected (shift_id=' || v_shift_id || ')',
                    p_caller
                );
            END IF;
            
            v_shift_id := NULL;
            CONTINUE;
        END IF;
        
        lp_step := 1.2;
        -- Insert new shift
        INSERT INTO application_data.lk_shift_dwh (
            shift_code,
            shift_ds,
            shift_start_time,
            shift_end_time,
            plant_id,
            line_id,
            source_id,
            is_active,
            creation_ts,
            creator_user,
            last_user
        ) VALUES (
            rec."ShiftKey",
            COALESCE(rec."Description", rec."ShiftKey"),
            rec."StartTime",
            rec."EndTime",
            v_plant_id,
            v_line_id,
            rec."ShiftIntId",
            true,
            lp_start_ts,
            '9999999999999 -- ' || p_caller,
            '9999999999999 -- ' || p_caller
        );
        
        lp_rows_inserted := lp_rows_inserted + 1;
        
        INSERT INTO application_staging.etl_log_operation (
            operation_timestamp, operation_src, operation_msg, operation_caller
        ) VALUES (
            timezone('UTC', current_timestamp),
            lp_procedure_name,
            '[INSERTED] Shift: ShiftKey=' || rec."ShiftKey" || ', ShiftIntId=' || rec."ShiftIntId" || ', StartTime=' || rec."StartTime" || ', EndTime=' || rec."EndTime" || ' -> new shift created',
            p_caller
        );
        END LOOP;

        -- Step 1.5: Coherence cleanup - mark shifts for this line whose source_id is no longer in DWH Shift
        lp_step := 1.5;
        WITH to_remove AS (
            UPDATE application_data.lk_shift_dwh
            SET is_deleted = true,
                is_active = false,
                last_modified = timezone('UTC', current_timestamp),
                last_user = '9999999999999 -- ' || p_caller
            WHERE line_id = v_line_id
              AND source_id IS NOT NULL
              AND source_id NOT IN (SELECT "ShiftIntId" FROM "Shift")
              AND is_deleted = false
            RETURNING shift_dwh_id
        )
        SELECT COUNT(*) INTO v_removed_this_line FROM to_remove;
        lp_rows_removed := lp_rows_removed + COALESCE(v_removed_this_line, 0);
        IF COALESCE(v_removed_this_line, 0) > 0 THEN
            INSERT INTO application_staging.etl_log_operation (
                operation_timestamp, operation_src, operation_msg, operation_caller
            ) VALUES (
                timezone('UTC', current_timestamp),
                lp_procedure_name,
                '[CLEANUP] Soft-deleted ' || v_removed_this_line || ' shift(s) for line_id=' || v_line_id || ' (source_id no longer in DWH)',
                p_caller
            );
        END IF;
    END LOOP;

    IF v_lines_processed = 0 THEN
        RAISE EXCEPTION 'No lk_line mapping found for foreign_schema=% (SiteKey=%; ProcessKey=%).',
            p_foreign_schema,
            COALESCE((SELECT "SiteKey" FROM "Site" LIMIT 1), 'NULL'),
            COALESCE(v_process_key, 'NULL');
    END IF;

    -- Step 2: Log procedure completion
    lp_step := 2;
    INSERT INTO application_staging.etl_log_operation (
        operation_timestamp, operation_src, operation_msg, operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'END - Shifts synchronized. Inserted: ' || lp_rows_inserted || ', Updated: ' || lp_rows_updated || ', Skipped: ' || lp_rows_skipped || ', Orphans removed: ' || lp_rows_removed,
        p_caller
    );

EXCEPTION WHEN OTHERS THEN
    lp_err_msg := 'ERROR at step ' || lp_step || ': ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE;
    CALL application_staging.etl_log_error_write(lp_procedure_name, lp_err_msg, p_caller);
    RAISE;
END;
$procedure$
;

COMMENT ON PROCEDURE application_staging.etl_sync_lk_shift(varchar, text) IS 'Synchronizes Shift data from DWH to lk_shift_dwh';