-- ==============================================================
-- Script: 3_create_view.sql
-- Purpose: Create application views for a single tenant
-- Scope:   Single tenant
--
-- Run as:  tenant_<tenantID>_user
-- Target:  Database: dlmo_tenant_<tenantID>_db
--
-- Order:   3 - After 2_create_table.sql, before 4_create_function_procedure.sql
--
-- Version: 1.0.0
-- Last updated: 2025-01-15
-- Notes:
--   - Defines views over tables in application_data
--   - Requires all referenced tables to be created by 2_create_table.sql
-- ==============================================================

-- application_data.vw_lk_tier source

CREATE OR REPLACE VIEW application_data.vw_lk_tier
AS SELECT lk_tier.tier_id,
    lk_tier.tier_code,
    lk_tier.tier_ds,
    lk_tier.plant_id,
    lk_tier.creation_ts,
    lk_tier.creator_user,
    lk_tier.is_active,
    lk_tier.is_deleted,
    lk_tier.is_editable,
    lk_tier.last_modified,
    lk_tier.last_user,
    lk_tier.tier_sort,
    lk_tier.frequency_id
   FROM application_data.lk_tier;


-- application_data.vw_plant_module source

CREATE OR REPLACE VIEW application_data.vw_plant_module
AS SELECT lp.plant_id,
    lp.plant_ds,
    lm.module_id,
    lm.module_ds
   FROM application_data.lk_plant lp
     JOIN application_data.lk_module lm ON lm.plant_id = lp.plant_id;
	 
	
-- application_data.vw_action_count_by_structure source

CREATE OR REPLACE VIEW application_data.vw_action_count_by_structure
AS WITH base_combinations AS (
         SELECT l.line_id,
            l.line_ds,
            m.module_id,
            m.module_ds,
            p.plant_id,
            p.plant_ds,
            wt.tier_id AS assigned_tier_id,
            wt.tier_ds AS assigned_tier_ds,
            kc.kpi_category_id,
            kc.kpi_category_ds,
            ap.action_priority_id,
            ap.action_priority_ds,
            ap.action_priority_cd
           FROM application_data.lk_line l
             JOIN application_data.lk_module m ON l.module_id = m.module_id AND l.plant_id = m.plant_id
             JOIN application_data.lk_plant p ON m.plant_id = p.plant_id
             JOIN application_data.vw_lk_tier wt ON wt.plant_id = p.plant_id
             JOIN application_data.lk_kpi_category kc ON kc.plant_id = p.plant_id
             CROSS JOIN application_data.lk_action_priority ap
          WHERE ap.action_priority_cd::text <> '<#U/>'::text
        )
 SELECT bc.line_id,
    bc.line_ds,
    bc.module_id,
    bc.module_ds,
    bc.plant_id,
    bc.plant_ds,
    bc.assigned_tier_id,
    bc.assigned_tier_ds,
    bc.kpi_category_id,
    bc.kpi_category_ds,
    bc.action_priority_id,
    bc.action_priority_ds,
    COALESCE(count(a.action_id), 0::bigint) AS num_actions,
    COALESCE(min(a.opening_day_local_id), 19700101) AS opening_day_local_id
   FROM base_combinations bc
     LEFT JOIN ( SELECT a_1.plant_id,
            a_1.action_id,
            a_1.action_cd,
            a_1.action_html_ds,
            a_1.action_ds,
            a_1.module_id,
            a_1.line_id,
            a_1.action_priority_id,
            a_1.action_status_id,
            a_1.kpi_category_id,
            a_1.opening_tier_id,
            a_1.assign_tier_id,
            a_1.action_owner,
            a_1.action_raiser,
            a_1.opening_day_local_id,
            a_1.opening_local_ts,
            a_1.opening_utc_ts,
            a_1.closure_day_local_id,
            a_1.closure_local_ts,
            a_1.closure_utc_ts,
            a_1.due_date_day_local_id,
            a_1.due_date_local_ts,
            a_1.due_date_utc_ts,
            a_1.owner_closure_day_local_id,
            a_1.owner_closure_local_ts,
            a_1.owner_closure_utc_ts,
            a_1.creation_day_local_id,
            a_1.creation_local_ts,
            a_1.creation_utc_ts,
            a_1.creator_user,
            a_1.last_modified_utc_ts,
            a_1.last_modified_local_day_id,
            a_1.last_modified_local_ts,
            a_1.last_user,
            a_1.is_escalated,
            a_1.is_no_escalation,
            a_1.is_on_time,
            a_1.is_on_hold,
            a_1.is_top_action,
			a_1.meeting_id AS comment_ds,
            s.action_status_id,
            s.action_status_cd,
            s.action_status_ds,
            s.action_status_sort,
            s.creation_ts,
            s.creator_user,
            s.last_modified,
            s.last_user
           FROM application_data.lk_action a_1
             JOIN application_data.lk_action_status s ON a_1.action_status_id = s.action_status_id
          WHERE s.action_status_cd::text <> ALL (ARRAY['<#Cancelled/>'::character varying, '<#ClosedbyRaiser/>'::character varying, '<#CompletedbyOwner/>'::character varying]::text[])) a(plant_id, action_id, action_cd, action_html_ds, action_ds, module_id, line_id, action_priority_id, action_status_id, kpi_category_id, opening_tier_id, assign_tier_id, action_owner, action_raiser, opening_day_local_id, opening_local_ts, opening_utc_ts, closure_day_local_id, closure_local_ts, closure_utc_ts, due_date_day_local_id, due_date_local_ts, due_date_utc_ts, owner_closure_day_local_id, owner_closure_local_ts, owner_closure_utc_ts, creation_day_local_id, creation_local_ts, creation_utc_ts, creator_user, last_modified_utc_ts, last_modified_local_day_id, last_modified_local_ts, last_user, is_escalated, is_no_escalation, is_on_time, is_on_hold, is_top_action, comment_ds, action_status_id_1, action_status_cd, action_status_ds, action_status_sort, creation_ts, creator_user_1, last_modified, last_user_1) ON a.line_id = bc.line_id AND a.module_id = bc.module_id AND a.plant_id = bc.plant_id AND a.assign_tier_id = bc.assigned_tier_id AND a.kpi_category_id = bc.kpi_category_id AND a.action_priority_id = bc.action_priority_id
  GROUP BY bc.line_id, bc.line_ds, bc.module_id, bc.module_ds, bc.plant_id, bc.plant_ds, bc.assigned_tier_id, bc.assigned_tier_ds, bc.kpi_category_id, bc.kpi_category_ds, bc.action_priority_id, bc.action_priority_ds
  ORDER BY bc.line_id, bc.line_ds, bc.module_id, bc.module_ds, bc.plant_id, bc.plant_ds, bc.assigned_tier_id, bc.assigned_tier_ds, bc.kpi_category_id, bc.kpi_category_ds, bc.action_priority_id, bc.action_priority_ds;


-- application_data.vw_oee_step_shift source
-- OEE step (machine_id) at shift level.
CREATE OR REPLACE VIEW application_data.vw_oee_step_shift
AS
SELECT
    s.plant_id,
    s.line_id,
    s.day_id,
    s.production_date,
    s.shift_dwh_id,
    s.machine_id,
    m.machine_code,
    m.machine_ds,
    SUM(s.good_first_pass)::BIGINT AS good_first_pass,
    SUM(s.total_pcs)::BIGINT AS total_pcs,
    MAX(s.shift_working_duration_sec) AS observed_duration_sec,
    MAX(s.ideal_capacity_step) AS ideal_capacity_step,
    CASE
        WHEN MAX(s.ideal_capacity_step) > 0
            THEN ROUND((SUM(s.good_first_pass)::NUMERIC / MAX(s.ideal_capacity_step)::NUMERIC) * 100, 6)
        ELSE NULL
    END AS oee_step_pct
FROM application_data.ft_oee_shift s
LEFT JOIN application_data.lk_machine m
       ON m.plant_id = s.plant_id
      AND m.line_id = s.line_id
      AND m.machine_id = s.machine_id
      AND m.is_deleted = FALSE
GROUP BY
    s.plant_id,
    s.line_id,
    s.day_id,
    s.production_date,
    s.shift_dwh_id,
    s.machine_id,
    m.machine_code,
    m.machine_ds;


-- application_data.vw_oee_step_day source
-- OEE step (machine_id) at daily level.
CREATE OR REPLACE VIEW application_data.vw_oee_step_day
AS
WITH machine_shift AS (
    SELECT
        s.plant_id,
        s.line_id,
        s.day_id,
        s.production_date,
        s.shift_dwh_id,
        s.machine_id,
        SUM(s.good_first_pass)::BIGINT AS good_first_pass,
        SUM(s.total_pcs)::BIGINT AS total_pcs,
        MAX(s.shift_working_duration_sec)::NUMERIC(20,5) AS observed_duration_sec,
        MAX(s.ideal_capacity_step)::NUMERIC(18,3) AS ideal_capacity_step
    FROM application_data.ft_oee_shift s
    GROUP BY
        s.plant_id,
        s.line_id,
        s.day_id,
        s.production_date,
        s.shift_dwh_id,
        s.machine_id
)
SELECT
    ms.plant_id,
    ms.line_id,
    ms.day_id,
    ms.production_date,
    ms.machine_id,
    m.machine_code,
    m.machine_ds,
    COUNT(DISTINCT ms.shift_dwh_id)::INT AS shift_count,
    SUM(ms.good_first_pass)::BIGINT AS good_first_pass,
    SUM(ms.total_pcs)::BIGINT AS total_pcs,
    SUM(ms.observed_duration_sec)::NUMERIC(20,5) AS observed_duration_sec,
    SUM(ms.ideal_capacity_step)::NUMERIC(18,3) AS ideal_capacity_step,
    CASE
        WHEN SUM(ms.ideal_capacity_step) > 0
            THEN ROUND((SUM(ms.good_first_pass)::NUMERIC / SUM(ms.ideal_capacity_step)::NUMERIC) * 100, 6)
        ELSE NULL
    END AS oee_step_pct
FROM machine_shift ms
LEFT JOIN application_data.lk_machine m
       ON m.plant_id = ms.plant_id
      AND m.line_id = ms.line_id
      AND m.machine_id = ms.machine_id
      AND m.is_deleted = FALSE
GROUP BY
    ms.plant_id,
    ms.line_id,
    ms.day_id,
    ms.production_date,
    ms.machine_id,
    m.machine_code,
    m.machine_ds;