-- QA checks for application_data.populate_ft_oee
-- Set your filters here:
-- \set plant_id 100
-- \set line_id 600
-- \set day_id 20260218

-- 1) Shift count coherence (ft_oee vs ft_rawdata)
SELECT
    o.plant_id,
    o.line_id,
    o.day_id,
    MAX(o.shift_count) AS shift_count_ft_oee,
    COUNT(DISTINCT fr.shift_dwh_id) FILTER (WHERE fr.pass_number = 0) AS shift_count_raw
FROM application_data.ft_oee o
LEFT JOIN application_data.ft_rawdata fr
       ON fr.plant_id = o.plant_id
      AND fr.line_id = o.line_id
      AND fr.day_id = o.day_id
WHERE o.plant_id = :plant_id
  AND o.line_id = :line_id
  AND o.day_id = :day_id
GROUP BY o.plant_id, o.line_id, o.day_id;

-- 2) Parallel step coherence (effective cycle = ideal / parallel_count)
SELECT
    plant_id,
    line_id,
    day_id,
    source_step_id,
    machine_id,
    component_id,
    ideal_cycle_time_ms,
    parallel_component_count_step,
    effective_step_cycle_time_ms,
    CASE
        WHEN ideal_cycle_time_ms > 0 AND parallel_component_count_step > 0
            THEN round(ideal_cycle_time_ms::numeric / parallel_component_count_step::numeric, 3)
        ELSE NULL
    END AS expected_effective_step_cycle_time_ms
FROM application_data.ft_oee
WHERE plant_id = :plant_id
  AND line_id = :line_id
  AND day_id = :day_id
ORDER BY source_step_id, machine_id, component_id;

-- 3) End-step uniqueness/coverage
SELECT
    plant_id,
    line_id,
    day_id,
    COUNT(DISTINCT source_step_id) FILTER (WHERE is_end_step) AS end_step_count,
    SUM(good_first_pass) FILTER (WHERE is_end_step) AS good_output_end_step
FROM application_data.ft_oee
WHERE plant_id = :plant_id
  AND line_id = :line_id
  AND day_id = :day_id
GROUP BY plant_id, line_id, day_id;

-- 4) Bottleneck step detection (max effective step cycle)
SELECT
    plant_id,
    line_id,
    day_id,
    source_step_id,
    MAX(effective_step_cycle_time_ms) AS step_cycle_ms
FROM application_data.ft_oee
WHERE plant_id = :plant_id
  AND line_id = :line_id
  AND day_id = :day_id
GROUP BY plant_id, line_id, day_id, source_step_id
ORDER BY step_cycle_ms DESC NULLS LAST;

-- 5) OEE line component check vs ft_kpi_target
WITH line_calc AS (
    SELECT
        plant_id,
        line_id,
        day_id AS target_date_iso,
        MAX(line_output_good) AS line_output_good,
        MAX(line_capacity_ideal) AS line_capacity_ideal,
        CASE
            WHEN MAX(line_capacity_ideal) > 0
                THEN round((MAX(line_output_good)::numeric / MAX(line_capacity_ideal)::numeric) * 100, 6)
            ELSE NULL
        END AS expected_oee_pct
    FROM application_data.ft_oee
    WHERE plant_id = :plant_id
      AND line_id = :line_id
      AND day_id = :day_id
    GROUP BY plant_id, line_id, day_id
)
SELECT
    lc.plant_id,
    lc.line_id,
    lc.target_date_iso,
    lc.line_output_good,
    lc.line_capacity_ideal,
    lc.expected_oee_pct,
    tgt.kpi_value AS ft_kpi_target_oee_pct
FROM line_calc lc
LEFT JOIN application_data.lk_kpi k
       ON k.plant_id = lc.plant_id
      AND k.kpi_code = 'OEE'
      AND k.is_deleted = FALSE
LEFT JOIN application_data.ft_kpi_target tgt
       ON tgt.plant_id = lc.plant_id
      AND tgt.line_id = lc.line_id
      AND tgt.target_date_iso = lc.target_date_iso
      AND tgt.kpi_id = k.kpi_id;
