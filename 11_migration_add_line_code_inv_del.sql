-- ==============================================================
-- Script: 11_migration_add_line_code_inv_del.sql
-- Purpose: Add line_code_inv and line_code_del to lk_line
--          and update manage_lk_line procedure in a safe/idempotent way.
-- Run when: Existing environments already populated and fresh installs.
-- ==============================================================

-- ==============================================================
-- application_data.lk_line: add new nullable business columns
-- ==============================================================
ALTER TABLE application_data.lk_line
  ADD COLUMN IF NOT EXISTS line_code_inv varchar(255) NULL;

ALTER TABLE application_data.lk_line
  ADD COLUMN IF NOT EXISTS line_code_del varchar(255) NULL;

COMMENT ON COLUMN application_data.lk_line.line_code_inv IS
  'Inventory-specific line code (optional).';
COMMENT ON COLUMN application_data.lk_line.line_code_del IS
  'Delivery-specific line code (optional).';

-- Performance indexes scoped by plant. Non-unique by design.
CREATE INDEX IF NOT EXISTS lk_line_plant_line_code_inv_idx
  ON application_data.lk_line (plant_id, line_code_inv)
  WHERE line_code_inv IS NOT NULL;

CREATE INDEX IF NOT EXISTS lk_line_plant_line_code_del_idx
  ON application_data.lk_line (plant_id, line_code_del)
  WHERE line_code_del IS NOT NULL;

-- ==============================================================
-- AUDIT TABLE ALIGNMENT
-- Keep column order aligned with lk_line because triggers use:
-- INSERT INTO application_audit.au_lk_line SELECT NEW.*, 'I', now();
-- ==============================================================
DO $$
BEGIN
  IF to_regclass('application_audit.au_lk_line') IS NOT NULL THEN
    EXECUTE 'DROP TABLE IF EXISTS application_audit.au_lk_line_bkp';
    EXECUTE 'CREATE TABLE application_audit.au_lk_line_bkp AS SELECT * FROM application_audit.au_lk_line';
  ELSE
    EXECUTE 'DROP TABLE IF EXISTS application_audit.au_lk_line_bkp';
  END IF;
END $$;

DROP TABLE IF EXISTS application_audit.au_lk_line;
CREATE TABLE application_audit.au_lk_line AS
SELECT *, NULL::varchar(1) AS change_type, NULL::timestamptz AS au_operation_ts
FROM application_data.lk_line
WHERE false;

COMMENT ON TABLE application_audit.au_lk_line IS
  'Audit table for lk_line - recreated to include line_code_inv and line_code_del with correct column order';

DO $$
DECLARE
  cols text;
BEGIN
  IF to_regclass('application_audit.au_lk_line_bkp') IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY c.ordinal_position)
  INTO cols
  FROM information_schema.columns c
  WHERE c.table_schema = 'application_audit'
    AND c.table_name = 'au_lk_line_bkp'
    AND c.column_name IN (
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = 'application_audit'
        AND table_name = 'au_lk_line'
    );

  IF cols IS NOT NULL AND length(cols) > 0 THEN
    EXECUTE format(
      'INSERT INTO application_audit.au_lk_line (%s) SELECT %s FROM application_audit.au_lk_line_bkp',
      cols, cols
    );
  END IF;

  EXECUTE 'DROP TABLE IF EXISTS application_audit.au_lk_line_bkp';
END $$;

-- ============================================================================================================
-- DROP PROCEDURE application_data.manage_lk_line(varchar, int8, varchar, varchar, varchar, int8, varchar, bool, int8, varchar, varchar, varchar);
-- ============================================================================================================
CREATE OR REPLACE PROCEDURE application_data.manage_lk_line(
    operation_type character varying,
    p_line_id bigint DEFAULT NULL::bigint,
    p_line_code character varying DEFAULT NULL::character varying,
    p_line_code_erp character varying DEFAULT NULL::character varying,
    p_line_ds character varying DEFAULT NULL::character varying,
    p_user_id bigint DEFAULT NULL::bigint,
    p_user_fullname character varying DEFAULT NULL::character varying,
    p_is_active boolean DEFAULT NULL::boolean,
    p_module_id bigint DEFAULT NULL::bigint,
    p_process_key character varying DEFAULT NULL::character varying,
    p_line_code_inv character varying DEFAULT NULL::character varying,
    p_line_code_del character varying DEFAULT NULL::character varying
)
LANGUAGE plpgsql
AS $procedure$
-- ============================================================================================================
-- @Description:
--   Manage application_data.lk_line with insert/update/logical-delete/physical-delete.
--   Supports two optional business codes:
--   - p_line_code_inv -> lk_line.line_code_inv
--   - p_line_code_del -> lk_line.line_code_del
--
-- @Call examples:
--   Insert:
--     CALL application_data.manage_lk_line('I', NULL, 'L01', 'ERP_L01', 'Line 01', 1, 'User', true, 10, 'sp203_an', 'INV_L01', 'DEL_L01');
--   Update:
--     CALL application_data.manage_lk_line('U', 100, NULL, NULL, 'Line 01 Updated', 1, 'User', true, 10, 'sp203_an', 'INV_L01X', NULL);
--   Logical delete:
--     CALL application_data.manage_lk_line('LD', 100, NULL, NULL, NULL, 1, 'User', NULL, 10, NULL, NULL, NULL);
-- ============================================================================================================
DECLARE
    lp_last_user varchar;
    lp_plant_id bigint;
    lp_kpi_safety_id bigint;
    lp_line_id bigint;
    lp_step numeric;
    lp_procedure_name varchar(50) := 'application_data.manage_lk_line';
    lp_err_msg varchar(2000);
    v_image_ref varchar;

    tier_cursor CURSOR FOR
    SELECT tier_id
    FROM application_data.lk_tier
    WHERE plant_id = lp_plant_id
      AND is_active = true
      AND is_deleted = false
    ORDER BY tier_sort;

    v_tier_id bigint;
BEGIN
    lp_step := 0;
    INSERT INTO application_data.log_operation (
        operation_timestamp,
        operation_src,
        operation_msg,
        operation_caller
    ) VALUES (
        timezone('UTC', current_timestamp),
        lp_procedure_name,
        'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_line_code: ' || COALESCE(p_line_code, 'NULL') || ', ' ||
            'p_line_code_erp: ' || COALESCE(p_line_code_erp, 'NULL') || ', ' ||
            'p_process_key: ' || COALESCE(p_process_key, 'NULL') || ', ' ||
            'p_line_code_inv: ' || COALESCE(p_line_code_inv, 'NULL') || ', ' ||
            'p_line_code_del: ' || COALESCE(p_line_code_del, 'NULL') || ', ' ||
            'p_line_ds: ' || COALESCE(p_line_ds, 'NULL') || ', ' ||
            'p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_module_id: ' || COALESCE(p_module_id::text, 'NULL') || ', ' || ']',
        p_user_id::text || ' -- ' || p_user_fullname
    );

    lp_step := 0.1;
    IF p_user_fullname IS NULL OR p_user_id IS NULL THEN
        lp_err_msg := 'ERROR LAST USER FULLNAME AND ID CANNOT BE NULL.';
        RAISE EXCEPTION '%', lp_err_msg;
    END IF;
    lp_last_user := p_user_id::text || ' -- ' || p_user_fullname;

    SELECT plant_id
    INTO lp_plant_id
    FROM application_data.lk_module md
    WHERE md.module_id = p_module_id;

    SELECT kpi_id
    INTO lp_kpi_safety_id
    FROM application_data.lk_kpi kpi
    WHERE kpi.kpi_code = 'safety events'
      AND kpi.plant_id = lp_plant_id;

    CASE operation_type
        WHEN 'I' THEN
            lp_step := 1;
            IF p_line_code IS NULL OR p_line_ds IS NULL OR p_module_id IS NULL THEN
                lp_err_msg := 'ERROR VALUES CANNOT BE NULL TO INSERT A NEW LINE';
                RAISE EXCEPTION '%', lp_err_msg;
            END IF;

            lp_step := 1.1;
            v_image_ref := NULL;

            lp_step := 1.3;
            INSERT INTO application_data.lk_line (
                line_code,
                line_code_erp,
                line_code_inv,
                line_code_del,
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
                p_line_code_inv,
                p_line_code_del,
                p_process_key,
                p_line_ds,
                p_module_id,
                lp_plant_id,
                v_image_ref,
                timezone('UTC', current_timestamp),
                lp_last_user,
                lp_last_user,
                timezone('UTC', current_timestamp),
                p_is_active
            );

            SELECT line_id
            INTO lp_line_id
            FROM application_data.lk_line
            WHERE line_code = p_line_code
              AND plant_id = lp_plant_id;

            BEGIN
                OPEN tier_cursor;
                LOOP
                    FETCH tier_cursor INTO v_tier_id;
                    EXIT WHEN NOT FOUND;

                    CALL application_data.manage_assoc_module_line_tier_kpi(
                        'I',
                        NULL,
                        lp_kpi_safety_id,
                        v_tier_id,
                        lp_line_id,
                        p_module_id,
                        lp_plant_id,
                        TRUE,
                        p_user_id,
                        p_user_fullname
                    );
                END LOOP;

                CLOSE tier_cursor;

                INSERT INTO application_data.sh_lk_line_pattern_default
                    (plant_id, line_id, week_day_id, au_user_id, au_change_type, au_change_day_id, au_change_ts)
                SELECT
                    lp_plant_id,
                    lp_line_id,
                    generate_series(1, 7),
                    1111111111111,
                    'I',
                    to_char(timezone('UTC', current_timestamp), 'YYYYMMDD')::int,
                    timezone('UTC', current_timestamp);
            END;

        WHEN 'U' THEN
            lp_step := 2;
            PERFORM 1
            FROM application_data.lk_line
            WHERE line_id = p_line_id
              AND is_editable = false;
            IF FOUND THEN
                RAISE EXCEPTION 'ERROR IS_EDITABLE CANNOT BE FALSE';
            END IF;

            v_image_ref := NULL;

            lp_step := 2.1;
            UPDATE application_data.lk_line
            SET
                module_id = COALESCE(p_module_id, module_id),
                line_code = COALESCE(p_line_code, line_code),
                line_code_erp = COALESCE(p_line_code_erp, line_code_erp),
                line_code_inv = COALESCE(p_line_code_inv, line_code_inv),
                line_code_del = COALESCE(p_line_code_del, line_code_del),
                process_key = COALESCE(p_process_key, process_key),
                line_ds = COALESCE(p_line_ds, line_ds),
                image_ref = COALESCE(v_image_ref, image_ref),
                last_user = lp_last_user,
                last_modified = timezone('UTC', current_timestamp),
                is_active = COALESCE(p_is_active, is_active)
            WHERE line_id = p_line_id;

        WHEN 'LD' THEN
            lp_step := 3;
            UPDATE application_data.lk_line
            SET
                line_code = line_code || '***' || line_id || '***',
                line_code_inv = CASE
                    WHEN line_code_inv IS NULL THEN NULL
                    ELSE line_code_inv || '***' || line_id || '***'
                END,
                line_code_del = CASE
                    WHEN line_code_del IS NULL THEN NULL
                    ELSE line_code_del || '***' || line_id || '***'
                END,
                is_deleted = true,
                is_active = false,
                is_editable = false
            WHERE line_id = p_line_id;

        WHEN 'D' THEN
            lp_step := 4;
            DELETE FROM application_data.lk_line
            WHERE line_id = p_line_id;

        ELSE
            RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';
    END CASE;

EXCEPTION
    WHEN OTHERS THEN
        lp_err_msg := 'ERROR: ' || SQLERRM || ', SQLSTATE: ' || SQLSTATE || ', ' ||
            'lp_step: ' || lp_step::text || ', ' ||
            'Input: [operation_type: ' || COALESCE(operation_type, 'NULL') || ', ' ||
            'p_line_id: ' || COALESCE(p_line_id::text, 'NULL') || ', ' ||
            'p_line_code: ' || COALESCE(p_line_code, 'NULL') || ', ' ||
            'p_line_code_erp: ' || COALESCE(p_line_code_erp, 'NULL') || ', ' ||
            'p_process_key: ' || COALESCE(p_process_key, 'NULL') || ', ' ||
            'p_line_code_inv: ' || COALESCE(p_line_code_inv, 'NULL') || ', ' ||
            'p_line_code_del: ' || COALESCE(p_line_code_del, 'NULL') || ', ' ||
            'p_line_ds: ' || COALESCE(p_line_ds, 'NULL') || ', ' ||
            'V_image_ref: ' || COALESCE(V_image_ref, 'NULL') || ', ' ||
            'p_user_id: ' || COALESCE(p_user_id::text, 'NULL') || ', ' ||
            'p_user_fullname: ' || COALESCE(p_user_fullname, 'NULL') || ', ' ||
            'p_is_active: ' || COALESCE(p_is_active::text, 'NULL') || ', ' ||
            'p_module_id: ' || COALESCE(p_module_id::text, 'NULL') || ', ' || ']';
        BEGIN
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
            COMMIT;
        END;
        RAISE;
END;
$procedure$;

-- ============================================================================================================
-- Backward-compatible wrapper with previous signature
-- ============================================================================================================
-- DROP PROCEDURE application_data.manage_lk_line(varchar, int8, varchar, varchar, varchar, int8, varchar, bool, int8, varchar);
CREATE OR REPLACE PROCEDURE application_data.manage_lk_line(
    operation_type character varying,
    p_line_id bigint DEFAULT NULL::bigint,
    p_line_code character varying DEFAULT NULL::character varying,
    p_line_code_erp character varying DEFAULT NULL::character varying,
    p_line_ds character varying DEFAULT NULL::character varying,
    p_user_id bigint DEFAULT NULL::bigint,
    p_user_fullname character varying DEFAULT NULL::character varying,
    p_is_active boolean DEFAULT NULL::boolean,
    p_module_id bigint DEFAULT NULL::bigint,
    p_process_key character varying DEFAULT NULL::character varying
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    CALL application_data.manage_lk_line(
        operation_type,
        p_line_id,
        p_line_code,
        p_line_code_erp,
        p_line_ds,
        p_user_id,
        p_user_fullname,
        p_is_active,
        p_module_id,
        p_process_key,
        NULL::character varying,
        NULL::character varying
    );
END;
$procedure$;
