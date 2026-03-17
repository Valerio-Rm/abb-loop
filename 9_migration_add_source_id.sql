-- ==============================================================
-- Script: 9_migration_add_source_id.sql
-- Purpose: Add source_id to lookup tables for DWH integration
-- Run when: Tables already exist without source_id
-- ==============================================================

-- ================================================================
-- Rimozione vecchi indici UNIQUE su source_id (se presenti)
-- I source_id possono coincidere tra diversi DB DWH; si usano solo indici non univoci.
-- ================================================================
DROP INDEX IF EXISTS application_data.lk_plant_source_uidx;
DROP INDEX IF EXISTS application_data.lk_line_plant_source_uidx;
DROP INDEX IF EXISTS application_data.lk_machine_line_source_uidx;
DROP INDEX IF EXISTS application_data.lk_component_machine_source_uidx;
DROP INDEX IF EXISTS application_data.lk_component_primary_source_uidx;

-- ================================================================
-- lk_result: vincolo univoco per (line_id, result_code, machine_id)
-- così la stessa combinazione (result_code, machine_id) può esistere per linee diverse (es. DS203 vs RCBO).
-- ================================================================
ALTER TABLE application_data.lk_result DROP CONSTRAINT IF EXISTS uk_lk_result;
ALTER TABLE application_data.lk_result ADD CONSTRAINT uk_lk_result UNIQUE (line_id, result_code, machine_id);

-- ================================================================
-- lk_plant: add source_id (SiteIntId dal DWH)
-- ================================================================
ALTER TABLE application_data.lk_plant
  ADD COLUMN IF NOT EXISTS source_id int4 NULL;

-- Nota: source_id può coincidere su sorgenti diverse; manteniamo solo un indice non univoco
CREATE INDEX IF NOT EXISTS lk_plant_source_idx
  ON application_data.lk_plant (source_id)
  WHERE source_id IS NOT NULL;

COMMENT ON COLUMN application_data.lk_plant.source_id IS 'Id sorgente DWH: SiteIntId dalla tabella [sp203_an].[Site]';


-- ================================================================
-- lk_line: add source_id (Line.Id dal DWH)
-- ================================================================
ALTER TABLE application_data.lk_line
  ADD COLUMN IF NOT EXISTS source_id int4 NULL;

-- Anche per le linee, source_id può coincidere tra diversi DWH: indice solo per performance
CREATE INDEX IF NOT EXISTS lk_line_plant_source_idx
  ON application_data.lk_line (plant_id, source_id)
  WHERE source_id IS NOT NULL;

COMMENT ON COLUMN application_data.lk_line.source_id IS 'Id sorgente DWH: Id dalla tabella [sp203_an].[Line]';


-- ================================================================
-- lk_machine: add source_id (id step sorgente DWH = StepIntId)
-- ================================================================
ALTER TABLE application_data.lk_machine
  ADD COLUMN IF NOT EXISTS source_id int8 NULL;

-- Non imponiamo più univocità (line_id, source_id): i source_id possono ripetersi su più sorgenti
CREATE INDEX IF NOT EXISTS lk_machine_line_source_idx
  ON application_data.lk_machine (line_id, source_id)
  WHERE source_id IS NOT NULL;

COMMENT ON COLUMN application_data.lk_machine.source_id IS 'Id sorgente DWH: StepIntId dalla tabella [sp203_an].[Step]';

-- lk_machine: add is_start_step and is_end_step flags
ALTER TABLE application_data.lk_machine
  ADD COLUMN IF NOT EXISTS is_start_step BOOLEAN DEFAULT false;
ALTER TABLE application_data.lk_machine
  ADD COLUMN IF NOT EXISTS is_end_step BOOLEAN DEFAULT false;

COMMENT ON COLUMN application_data.lk_machine.is_start_step IS 'Indicates if this is the first step in the production process (from DWH Step.IsStartStep)';
COMMENT ON COLUMN application_data.lk_machine.is_end_step IS 'Indicates if this is the last step in the production process (from DWH Step.IsEndStep)';

-- lk_machine: add fpy_active flag (First Pass Yield active)
ALTER TABLE application_data.lk_machine
  ADD COLUMN IF NOT EXISTS fpy_active BOOLEAN NOT NULL DEFAULT true;
COMMENT ON COLUMN application_data.lk_machine.fpy_active IS 'FPY active flag (boolean) - controls FPY calculations/behavior for the machine';

-- lk_component: add source_id (id machine sorgente DWH = MachineIntId)
ALTER TABLE application_data.lk_component
  ADD COLUMN IF NOT EXISTS source_id int8 NULL;

-- lk_component: add is_primary_source (flag per identificare il component "principale" tra i duplicati)
ALTER TABLE application_data.lk_component
  ADD COLUMN IF NOT EXISTS is_primary_source bool DEFAULT false NOT NULL;

-- Indici solo per performance: non imponiamo più univocità sui source_id
CREATE INDEX IF NOT EXISTS lk_component_machine_source_idx
  ON application_data.lk_component (machine_id, source_id)
  WHERE source_id IS NOT NULL;

-- Component "primary" per (line_id, source_id), ma senza vincolo di univocità hard
CREATE INDEX IF NOT EXISTS lk_component_primary_source_idx
  ON application_data.lk_component (line_id, source_id)
  WHERE source_id IS NOT NULL AND is_primary_source = true;

COMMENT ON COLUMN application_data.lk_component.source_id IS 'Id sorgente DWH: MachineIntId dalla tabella [sp203_an].[Machine]';
COMMENT ON COLUMN application_data.lk_component.is_primary_source IS 'Se true, questo è il component principale per source_id nella linea (uno solo per line_id+source_id)';

-- lk_component: add ideal_cycle_time_ms (from DWH MachineVsStep.IdealCycleTimeMs)
ALTER TABLE application_data.lk_component
  ADD COLUMN IF NOT EXISTS ideal_cycle_time_ms int4 NULL;
COMMENT ON COLUMN application_data.lk_component.ideal_cycle_time_ms IS 'Tempo ciclo ideale in millisecondi - da [sp203_an].[MachineVsStep].IdealCycleTimeMs';


-- ================================================================
-- AUDIT TABLES: Recreate to match main table column order
-- IMPORTANT: Audit tables must have columns in the same order as main tables,
-- with change_type and au_operation_ts at the END.
-- This is required because triggers use: INSERT INTO au_xxx SELECT NEW.*, 'I', now()
-- ================================================================

-- au_lk_plant: drop and recreate with source_id in correct position
DROP TABLE IF EXISTS application_audit.au_lk_plant;
CREATE TABLE application_audit.au_lk_plant AS 
SELECT *, NULL::VARCHAR(1) AS change_type, NULL::TIMESTAMPTZ AS au_operation_ts 
FROM application_data.lk_plant WHERE false;
COMMENT ON TABLE application_audit.au_lk_plant IS 'Audit table for lk_plant - recreated for DWH integration';

-- au_lk_line: drop and recreate with source_id in correct position
DROP TABLE IF EXISTS application_audit.au_lk_line;
CREATE TABLE application_audit.au_lk_line AS 
SELECT *, NULL::VARCHAR(1) AS change_type, NULL::TIMESTAMPTZ AS au_operation_ts 
FROM application_data.lk_line WHERE false;
COMMENT ON TABLE application_audit.au_lk_line IS 'Audit table for lk_line - recreated for DWH integration';

-- au_lk_machine: drop and recreate with source_id, is_start_step, is_end_step in correct position
-- Backup existing audit data before recreation
DO $$
BEGIN
  -- Backup only if the audit table already exists
  IF to_regclass('application_audit.au_lk_machine') IS NOT NULL THEN
    EXECUTE 'DROP TABLE IF EXISTS application_audit.au_lk_machine_bkp';
    EXECUTE 'CREATE TABLE application_audit.au_lk_machine_bkp AS SELECT * FROM application_audit.au_lk_machine';
  ELSE
    EXECUTE 'DROP TABLE IF EXISTS application_audit.au_lk_machine_bkp';
  END IF;
END $$;

-- Recreate audit table so column order matches application_data.lk_machine (now includes fpy_active)
DROP TABLE IF EXISTS application_audit.au_lk_machine;
CREATE TABLE application_audit.au_lk_machine AS
SELECT *, NULL::VARCHAR(1) AS change_type, NULL::TIMESTAMPTZ AS au_operation_ts
FROM application_data.lk_machine WHERE false;
COMMENT ON TABLE application_audit.au_lk_machine IS 'Audit table for lk_machine - recreated (includes source_id, is_start_step, is_end_step, fpy_active)';

-- Restore previously saved audit data (copy intersection of columns; new columns will be NULL)
DO $$
DECLARE
  cols TEXT;
BEGIN
  IF to_regclass('application_audit.au_lk_machine_bkp') IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY c.ordinal_position)
  INTO cols
  FROM information_schema.columns c
  WHERE c.table_schema = 'application_audit'
    AND c.table_name = 'au_lk_machine_bkp'
    AND c.column_name IN (
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = 'application_audit'
        AND table_name = 'au_lk_machine'
    );

  IF cols IS NOT NULL AND length(cols) > 0 THEN
    EXECUTE format(
      'INSERT INTO application_audit.au_lk_machine (%s) SELECT %s FROM application_audit.au_lk_machine_bkp',
      cols, cols
    );
  END IF;
END $$;

-- au_lk_component: drop and recreate with source_id and is_primary_source in correct position
DROP TABLE IF EXISTS application_audit.au_lk_component;
CREATE TABLE application_audit.au_lk_component AS 
SELECT *, NULL::VARCHAR(1) AS change_type, NULL::TIMESTAMPTZ AS au_operation_ts 
FROM application_data.lk_component WHERE false;
COMMENT ON TABLE application_audit.au_lk_component IS 'Audit table for lk_component - recreated for DWH integration (includes is_primary_source, ideal_cycle_time_ms)';
