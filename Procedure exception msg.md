### application_data.create_future_partitions

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be NULL.';` | static | `User ID and Fullname cannot be NULL.` |
| `RAISE EXCEPTION 'Both p_date_min and p_date_max are NULL in manual mode.';` | static | `Both p_date_min and p_date_max are NULL in manual mode.` |
| `'create_plant_partition(ft_oee_shift) failed for plant_id=' \|\| v_plant_rec.plant_id::TEXT \|\| ': ' \|\| SQLERRM` | variable | `create_plant_partition(ft_oee_shift) failed for plant_id=****: ****` |
| `'create_plant_partition(ft_oee) failed for plant_id=' \|\| v_plant_rec.plant_id::TEXT \|\| ': ' \|\| SQLERRM` | variable | `create_plant_partition(ft_oee) failed for plant_id=****: ****` |
| `'create_plant_partition(ft_kpi_target) failed for plant_id=' \|\| v_plant_rec.plant_id::TEXT \|\| ': ' \|\| SQLERRM` | variable | `create_plant_partition(ft_kpi_target) failed for plant_id=****: ****` |
| `'create_monthly_partition(ft_oee_shift) failed for plant_id=' \|\| v_plant_rec.plant_id::TEXT \|\| ', year=' \|\| p_year::TEXT \|\| ', month=' \|\| p_month::TEXT \|\| ': ' \|\| SQLERRM` | variable | `create_monthly_partition(ft_oee_shift) failed for plant_id=****, year=****, month=****: ****` |
| `'create_monthly_partition(ft_oee) failed for plant_id=' \|\| v_plant_rec.plant_id::TEXT \|\| ', year=' \|\| p_year::TEXT \|\| ', month=' \|\| p_month::TEXT \|\| ': ' \|\| SQLERRM` | variable | `create_monthly_partition(ft_oee) failed for plant_id=****, year=****, month=****: ****` |
| `'create_monthly_partition(ft_kpi_target) failed for plant_id=' \|\| v_plant_rec.plant_id::TEXT \|\| ', year=' \|\| p_year::TEXT \|\| ', month=' \|\| p_month::TEXT \|\| ': ' \|\| SQLERRM` | variable | `create_monthly_partition(ft_kpi_target) failed for plant_id=****, year=****, month=****: ****` |
| `'ERROR: ' \|\| SQLERRM \|\| ', SQLSTATE=' \|\| SQLSTATE \|\| ', step=' \|\| lp_step::TEXT` | variable | `ERROR: ****, SQLSTATE=****, step=****` |

### application_data.populate_ft_oee

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `'Partition already exists: %', full_table_name` | variable | `Partition already exists: ****` |
| `'LIST partition already exists: table "%", plant_id %, column "%"', p_table_name, p_plant_id, p_range_column` | variable | `LIST partition already exists: table "****", plant_id ****, column "****"` |

### application_data.manage_ft_kpi_target

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_ft_safety_cross

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be NULL';` | static | `User ID and Fullname cannot be NULL` |
| `RAISE EXCEPTION 'Missing mandatory fields for INSERT';` | static | `Missing mandatory fields for INSERT` |
| `RAISE EXCEPTION 'Invalid operation_type: %', operation_type;` | variable | `Invalid operation_type: ****` |

### application_data.manage_lk_action

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Mandatory fields are missing!';` | static | `Mandatory fields are missing!` |
| `RAISE EXCEPTION 'Invalid operation type: %', p_operation_type;` | variable | `Invalid operation type: ****` |

### application_data.manage_lk_action_files

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Invalid action. Use INSERT or DELETE';` | static | `Invalid action. Use INSERT or DELETE` |

### application_data.manage_lk_attendance_role

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Required fields (attendance_role_code, attendance_role_ds, plant_id) cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Required fields (attendance_role_code, attendance_role_ds, plant_id) cannot be NULL for insertion.` |
| `RAISE EXCEPTION 'ERROR: The record is not editable (is_modify = FALSE).';` | static | `ERROR: The record is not editable (is_modify = FALSE).` |
| `RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';` | static | `ERROR: The record is not modifiable (is_modify = FALSE).` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_lk_component

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Required values cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Required values cannot be NULL for insertion.` |
| `lp_err_msg := 'ERROR: Component ID , Plant ID , Machine Id cannot be NULL for update.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Component ID , Plant ID , Machine Id cannot be NULL for update.` |
| `lp_err_msg := 'ERROR: Component ID and Plant ID cannot be NULL for deletion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Component ID and Plant ID cannot be NULL for deletion.` |
| `RAISE EXCEPTION 'ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Delete).';` | static | `ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Delete).` |

### application_data.manage_lk_department

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Required fields (department_code, department_ds, plant_id) cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Required fields (department_code, department_ds, plant_id) cannot be NULL for insertion.` |
| `RAISE EXCEPTION 'ERROR: The record is not modifiable (is_modify = FALSE).';` | static | `ERROR: The record is not modifiable (is_modify = FALSE).` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_lk_external_link

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Required fields (url_code, url_sh_ds, plant_id tier_id) cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Required fields (url_code, url_sh_ds, plant_id tier_id) cannot be NULL for insertion.` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_lk_files

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Invalid action. Use INSERT or DELETE';` | static | `Invalid action. Use INSERT or DELETE` |

### application_data.manage_lk_issue

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Mandatory fields are missing!';` | static | `Mandatory fields are missing!` |
| `RAISE EXCEPTION 'Invalid operation_type: %, must be I, U, or D.', p_operation_type;` | variable | `Invalid operation_type: ****, must be I, U, or D.` |

### application_data.manage_lk_issue_files

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Invalid action. Use INSERT or DELETE';` | static | `Invalid action. Use INSERT or DELETE` |

### application_data.manage_lk_kpi

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Required fields (kpi_code, plant_id, kpi_group_id, kpi_category_id, aggregation_rule_id, kpi_uom_id,target_tendency_id) cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Required fields (kpi_code, plant_id, kpi_group_id, kpi_category_id, aggregation_rule_id, kpi_uom_id,target_tendency_id) cannot be NULL for insertion.` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_lk_kpi_category

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID, Fullname or Plant cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID, Fullname or Plant cannot be NULL.` |
| `lp_err_msg := 'ERROR: kpi_category_code, kpi_category_sort and plant_id cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: kpi_category_code, kpi_category_sort and plant_id cannot be NULL for insertion.` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_lk_kpi_group

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: kpi_group_code, kpi_group_ds, kpi_group_sort, plant_id, and kpi_category_id cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: kpi_group_code, kpi_group_ds, kpi_group_sort, plant_id, and kpi_category_id cannot be NULL for insertion.` |
| `lp_err_msg := 'ERROR: Invalid operation_type.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Invalid operation_type.` |

### application_data.manage_lk_line

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR LAST USER FULLNAME AND ID CANNOT BE NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR LAST USER FULLNAME AND ID CANNOT BE NULL.` |
| `RAISE EXCEPTION 'ERROR IS_EDITABLE CANNOT BE FALSE';` | static | `ERROR IS_EDITABLE CANNOT BE FALSE` |
| `RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';` | static | `ERROR INVALID OPERATION_TYPE` |

### application_data.manage_lk_machine

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Required values cannot be NULL for insertion.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Required values cannot be NULL for insertion.` |
| `RAISE EXCEPTION 'ERROR: Plant timezone not found for plant_id %', p_plant_id;` | variable | `ERROR: Plant timezone not found for plant_id ****` |
| `lp_err_msg := 'ERROR: Machine ID and Plant ID cannot be NULL for update.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: Machine ID and Plant ID cannot be NULL for update.` |
| `RAISE EXCEPTION 'ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Delete).';` | static | `ERROR: Invalid operation type. Allowed values: I (Insert), U (Update), LD (Logical Delete), D (Delete).` |

### application_data.manage_lk_machine_target

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: ' \|\| SQLERRM \|\| ', SQLSTATE=' \|\| SQLSTATE \|\| ', step=' \|\| lp_step::TEXT;` / `CALL application_data.log_error_write(..., lp_err_msg, ...);` | variable | `ERROR: ****, SQLSTATE=****, step=****` |
| `RAISE EXCEPTION 'Timezone not found for plant_id %', p_plant_id::TEXT;` | variable | `Timezone not found for plant_id ****` |

### application_data.manage_assoc_module_line_tier_kpi

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'ERROR: User ID and Fullname cannot be NULL.';` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `RAISE EXCEPTION 'ERROR: Required fields for INSERT are missing';` | static | `ERROR: Required fields for INSERT are missing` |
| `RAISE EXCEPTION '%', lp_err_msg;` (after `CALL application_data.log_error_write(...)`) | variable | `****` |
| `RAISE EXCEPTION 'ERROR: Invalid operation_type';` | static | `ERROR: Invalid operation_type` |

### application_data.setup_kpi_into_ft_kpi_target

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be NULL';` | static | `User ID and Fullname cannot be NULL` |

### application_data.update_ft_kpi_target_from_safety_cross

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be NULL';` | static | `User ID and Fullname cannot be NULL` |
| `RAISE EXCEPTION '❌ Plant code "%" not found', rec.plant;` | variable | `❌ Plant code "****" not found` |
| `RAISE EXCEPTION '❌ Line code "%" not found for plant_id=%', rec.line, v_plant_id;` | variable | `❌ Line code "****" not found for plant_id=****` |
| `RAISE EXCEPTION '❌ KPI "%" not found for plant_id=%', rec.kpi, v_plant_id;` | variable | `❌ KPI "****" not found for plant_id=****` |
| `RAISE EXCEPTION '❌ Tier "%" not found for plant_id=%', rec.tier, v_plant_id;` | variable | `❌ Tier "****" not found for plant_id=****` |

### application_data.update_ft_kpi_target_from_safety_cross_tiered

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be NULL';` | static | `User ID and Fullname cannot be NULL` |
| `RAISE EXCEPTION '❌ Plant code "%" not found', rec.plant;` | variable | `❌ Plant code "****" not found` |
| `RAISE EXCEPTION '❌ Line code "%" not found for plant_id=%', rec.line, v_plant_id;` | variable | `❌ Line code "****" not found for plant_id=****` |
| `RAISE EXCEPTION '❌ Safety category "%" not found for plant_id=%', rec.safety_category, v_plant_id;` | variable | `❌ Safety category "****" not found for plant_id=****` |
| `RAISE EXCEPTION '❌ Safety type "%" not found', rec.safety_type;` | variable | `❌ Safety type "****" not found` |

### application_data.manage_ft_pareto_data

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be null';` | static | `User ID and Fullname cannot be null` |
| `RAISE EXCEPTION 'Invalid format for p_day: %', p_day;` | variable | `Invalid format for p_day: ****` |
| `RAISE EXCEPTION 'Missing required fields for INSERT';` | static | `Missing required fields for INSERT` |
| `RAISE EXCEPTION 'pareto_data_id is required for UPDATE';` | static | `pareto_data_id is required for UPDATE` |
| `RAISE EXCEPTION 'Cannot update: record is not editable';` | static | `Cannot update: record is not editable` |
| `RAISE EXCEPTION 'Invalid operation_type';` | static | `Invalid operation_type` |

### application_data.sp_shift_pattern_default

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'ERROR: User ID and Fullname cannot be NULL';` | static | `ERROR: User ID and Fullname cannot be NULL` |
| `RAISE EXCEPTION '❌ Plant code "%" not found', rec.plant;` | variable | `❌ Plant code "****" not found` |
| `RAISE EXCEPTION '❌ Line code "%" not found for plant_id=%', rec.line, v_plant_id;` | variable | `❌ Line code "****" not found for plant_id=****` |
| `RAISE EXCEPTION '❌ KPI "%" not found for plant_id=%', rec.kpi, v_plant_id;` | variable | `❌ KPI "****" not found for plant_id=****` |
| `RAISE EXCEPTION '❌ Tier "%" not found for plant_id=%', rec.tier, v_plant_id;` | variable | `❌ Tier "****" not found for plant_id=****` |

### application_data.sp_shift_pattern_default_single

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'ERROR: User ID and Fullname cannot be NULL.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `ERROR: User ID and Fullname cannot be NULL.` |
| `lp_err_msg := 'ERROR: Plant with code ' \|\| COALESCE(p_plant_code, 'NULL') \|\| ' not found or not active.';` / `RAISE EXCEPTION '%', lp_err_msg;` | variable | `ERROR: Plant with code **** not found or not active.` |

### application_data.sp_sync_lk_shift_from_calendar

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'p_plant_id cannot be NULL';` | static | `p_plant_id cannot be NULL` |
| `RAISE EXCEPTION 'User info cannot be NULL';` | static | `User info cannot be NULL` |
| `RAISE EXCEPTION 'Invalid plant_id: %', p_plant_id;` | variable | `Invalid plant_id: ****` |
| `RAISE EXCEPTION 'Offset value is not valid: %', end_offset;` | variable | `Offset value is not valid: ****` |

### application_data.sp_master_shift_processing

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Invalid plant_code or No Timezone: %', v_plant_code;` | variable | `Invalid plant_code or No Timezone: ****` |

### application_data.sp_shift_calendar

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'Invalid interval unit: %. Allowed: days, weeks, months, years.', p_interval_unit;` | variable | `Invalid interval unit: ****. Allowed: days, weeks, months, years.` |

### application_data.sp_shift_calendar_single

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID and Fullname cannot be NULL';` | static | `User ID and Fullname cannot be NULL` |
| `RAISE EXCEPTION 'Invalid plant_code: %', p_plant_code;` | variable | `Invalid plant_code: ****` |

### application_data.sp_shift_manage

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'User ID or fullname cannot be NULL';` | static | `User ID or fullname cannot be NULL` |
| `RAISE EXCEPTION 'Invalid plant_code: %', p_plant_code;` | variable | `Invalid plant_code: ****` |

### application_data.manage_lk_non_production_days

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `lp_err_msg := 'User fullname and ID cannot be null.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `User fullname and ID cannot be null.` |
| `lp_err_msg := 'Plant ID, Line ID, and Non-Working Date must be set.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `Plant ID, Line ID, and Non-Working Date must be set.` |
| `lp_err_msg := 'The line does not belong to the specified plant.';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `The line does not belong to the specified plant.` |
| `lp_err_msg := 'Invalid operation type';` / `RAISE EXCEPTION '%', lp_err_msg;` | static | `Invalid operation type` |

### application_data.manage_sh_line_pattern_default

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'au_user_id CANNOT BE NULL';` | static | `au_user_id CANNOT BE NULL` |
| `RAISE EXCEPTION 'ERROR VALUES CANNOT BE NULL';` | static | `ERROR VALUES CANNOT BE NULL` |
| `RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';` | static | `ERROR INVALID OPERATION_TYPE` |

### application_data.manage_sh_lk_pattern

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `RAISE EXCEPTION 'au_user_id CANNOT BE NULL';` | static | `au_user_id CANNOT BE NULL` |
| `RAISE EXCEPTION 'VALUES CANNOT BE NULL TO INSERT A NEW SHIFT_DEFINITION';` | static | `VALUES CANNOT BE NULL TO INSERT A NEW SHIFT_DEFINITION` |
| `RAISE EXCEPTION 'VALUES CANNOT BE NULL TO UPDATE A SHIFT_DEFINITION';` | static | `VALUES CANNOT BE NULL TO UPDATE A SHIFT_DEFINITION` |
| `RAISE EXCEPTION 'au_user_id CANNOT BE NULL';` (update branch) | static | `au_user_id CANNOT BE NULL` |
| `RAISE EXCEPTION 'ERROR INVALID OPERATION_TYPE';` | static | `ERROR INVALID OPERATION_TYPE` |

### application_data.log_error_write

| **Error message (full expression)** | **Type (static/variable)** | **Static mask (variables → `****`)** |
| --- | --- | --- |
| `CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, lp_last_user);` (various procedures) | variable | `****` |

