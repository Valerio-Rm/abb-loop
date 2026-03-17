# Report: sostituzioni INSERT → log_error_write in 4_create_function_procedure.sql

**Data:** sessione corrente  
**File modificato:** `4_create_function_procedure.sql`  
**Backup:** `4_create_function_procedure_backup.sql`

---

## 1. Verifica assenza INSERT in application_data.log_error

**Controllo eseguito:** ricerca di `INTO application_data.log_error` nel file.

**Risultato:** **SUPERATO**

Rimangono **solo 3 occorrenze**, tutte **volute**:

| Riga (circa) | Contesto | Motivo |
|--------------|----------|--------|
| 1954 | `manage_lk_threshold` (blocco EXCEPTION interno) | Fallback quando la chiamata a `log_error_write` fallisce; evita ricorsione e garantisce scrittura nella stessa transazione. **Lasciato intenzionalmente.** |
| 10754 | `log_error_write` | Stringa SQL costruita per `dblink_exec` (non è un INSERT eseguito direttamente). |
| 10767 | `log_error_write` (blocco EXCEPTION) | Fallback INSERT diretto se dblink fallisce. **Parte della procedura stessa.** |

**Conclusione:** Non esistono più `INSERT INTO application_data.log_error` (o `INTO application_data.log_error`) al di fuori della procedura `log_error_write` e del fallback in `manage_lk_threshold`.

---

## 2. Coerenza variabili per procedura

**Controllo:** Per ogni chiamata `CALL application_data.log_error_write(src, msg, caller)` si è verificato che i tre argomenti corrispondano a variabili (o espressioni) definite e coerenti nella procedura/funzione che la invoca.

**Risultato:** **COERENTE**

Sintesi degli argomenti usati e verifica:

| Tipo argomenti | Utilizzo | Coerenza |
|----------------|----------|----------|
| `lp_procedure_name`, `lp_err_msg`, `lp_last_user` | Molte procedure (manage_target, manage_ft_safety_cross, update_ft_kpi_target, ecc.) | Tutte dichiarano queste variabili; `lp_last_user` spesso impostato come `p_user_id::TEXT \|\| ' -- ' \|\| p_user_fullname`. |
| `lp_procedure_name`, `lp_err_msg`, `p_user_id::TEXT \|\| ' -- ' \|\| p_user_fullname` | Procedure che non usano `lp_last_user` ma passano direttamente l’identità utente | Coerente: parametri di ingresso presenti. |
| `lp_procedure_name`, `lp_err_msg`, `'Backend'` / `'TRIGGER'` | Chiamate da trigger o da contesto backend | Coerente: caller fisso. |
| `lp_procedure_name`, `lp_error_msg`, `lp_user` | `manage_lk_action_files`, `manage_lk_issue_files` | Coerente: in entrambe le procedure sono dichiarate `lp_error_msg` e `lp_user` (e usate anche in `log_operation`). |
| `lp_function_name`, msg/espressione, `lp_operation_caller` | `create_future_partitions`, `setup_new_plant_partitions` | Coerente: variabili dichiarate nelle rispettive funzioni. |
| `procedure_name`, `err_msg`, `p_au_user_id::text` | `manage_sh_line_pattern_default`, `manage_sh_lk_pattern`, e altra con `procedure_name`/`err_msg` | Coerente: nomi diversi ma dichiarati nelle rispettive procedure. |
| `lp_procedure_name`, messaggio costruito (es. `'NON-CRITICAL ALL → ...'`), `lp_caller` | `sp_shift_pattern_default`, `sp_shift_calendar`, `sp_master_shift_processing`, ecc. | Coerente: `lp_caller` e `lp_procedure_name` dichiarati. |

**Note:**  
- Le due procedure che usano `lp_error_msg` e `lp_user` (invece di `lp_err_msg` e `lp_last_user`) sono state lasciate così perché i nomi sono quelli effettivamente dichiarati in quelle routine.  
- Nessuna chiamata a `log_error_write` usa variabili inesistenti o non inizializzate nel blocco EXCEPTION.

---

## 3. Modifiche apportate: prima / dopo (per pattern)

Per ogni **pattern** sotto è indicato il **prima** (blocco INSERT) e il **dopo** (chiamata a `log_error_write`). Le sostituzioni sono state applicate in modo uniforme in tutto il file.

---

### Pattern 1: (lp_procedure_name, lp_err_msg, lp_last_user)

**Prima:**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    lp_err_msg,
    lp_last_user
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, lp_last_user);
```

**Procedure/funzioni interessate (esempi):**  
`manage_target`, `manage_ft_safety_cross`, `update_ft_kpi_target`, `manage_assoc_module_line_tier_kpi`, `create_future_partitions` (con msg costruito), `update_ft_kpi_target_from_safety_cross_tiered`, `manage_ft_safety_cross` (partition failed), `import_file_*`, `sp_sync_lk_shift_from_calendar`, `sp_shift_manage_single`, ecc.

---

### Pattern 2: (lp_procedure_name, lp_err_msg, p_user_id::TEXT || ' -- ' || p_user_fullname)

**Prima:**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    lp_err_msg,
    p_user_id::TEXT || ' -- ' || p_user_fullname
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, p_user_id::TEXT || ' -- ' || p_user_fullname);
```

**Procedure interessate (esempi):**  
Diverse `manage_*` con parametri `p_user_id`, `p_user_fullname`; funzioni di import che ricevono l’utente come parametro.

---

### Pattern 3: (lp_procedure_name, lp_err_msg, 'TRIGGER')

**Prima:**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp), lp_procedure_name, lp_err_msg, 'TRIGGER'
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, 'TRIGGER');
```

**Contesto:** Procedure invocate da trigger (es. trigger su `ft_kpi_target`).

---

### Pattern 4: (lp_procedure_name, lp_err_msg, 'Backend')

**Prima:**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    lp_err_msg,
    'Backend'
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, 'Backend');
```

**Contesto:** `update_ft_kpi_target_from_safety_cross_tiered` e simili (chiamate da backend).

---

### Pattern 5: (lp_procedure_name, messaggio costruito, lp_last_user) – es. partition failed / file partial

**Prima (esempio partition):**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', CURRENT_TIMESTAMP),
    lp_procedure_name,
    '❌ Partition creation failed for ' || lp_partition_name || ': ' || SQLERRM,
    lp_last_user
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, '❌ Partition creation failed for ' || lp_partition_name || ': ' || SQLERRM, lp_last_user);
```

**Altri esempi:**  
- “Error populating KPI value from safety_cross…”, “⚠️ Partition creation failed…”, “⚠️ File %s partially processed…”  
- Stesso schema: messaggio costruito + `lp_last_user` (o equivalente).

---

### Pattern 6: (lp_function_name, msg/skipping/error creating…, lp_operation_caller)

**Prima (esempio):**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_function_name,
    'Skipping setup for table ' || table_rec.table_name || ': No suitable range column...',
    lp_operation_caller
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_function_name, 'Skipping setup for table ' || table_rec.table_name || ': No suitable range column (day_id/target_date_iso) found.', lp_operation_caller);
```

**Contesto:** `create_future_partitions`, `setup_new_plant_partitions` (skipping table, error creating LIST/Current Month/Next Month partition).

---

### Pattern 7: (lp_procedure_name, lp_error_msg, lp_user)

**Prima:**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    lp_error_msg,
    lp_user
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, lp_error_msg, lp_user);
```

**Procedure:** `manage_lk_action_files`, `manage_lk_issue_files` (variabili `lp_error_msg` e `lp_user` dichiarate in procedura).

---

### Pattern 8: (procedure_name, err_msg, p_au_user_id::text)

**Prima:**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    procedure_name,
    err_msg,
    p_au_user_id::text
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(procedure_name, err_msg, p_au_user_id::text);
```

**Procedure:** `manage_sh_line_pattern_default`, `manage_sh_lk_pattern`, e altra con `procedure_name`/`err_msg` e parametro `p_au_user_id`.

---

### Pattern 9: sp_shift_pattern_default / sp_shift_calendar / sp_master_shift_processing (NON-CRITICAL / CRITICAL / GENERIC, ALL / LIST / SINGLE)

**Prima (esempio):**
```sql
INSERT INTO application_data.log_error (
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    lp_now_utc,
    lp_procedure_name,
    'NON-CRITICAL ALL → plant='||v_code||' → '||SQLERRM,
    lp_caller
);
CONTINUE;
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, 'NON-CRITICAL ALL → plant='||v_code||' → '||SQLERRM, lp_caller);
CONTINUE;
```

**Varianti:** Stesso schema per CRITICAL/GENERIC e per ALL/LIST/SINGLE; in alcuni punti il timestamp era `timezone('UTC', current_timestamp)` invece di `lp_now_utc`. Il caller è sempre `lp_caller` (o equivalente). Il timestamp non viene più passato: è gestito internamente da `log_error_write`.

---

### Pattern 10: sp_shift_manage, sp_shift_calendar (NON-CRITICAL / CRITICAL in shift_manage / shift_calendar / pattern_default)

**Prima (esempio):**
```sql
INSERT INTO application_data.log_error(
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    'NON-CRITICAL in shift_manage → '||SQLERRM,
    lp_caller
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, 'NON-CRITICAL in shift_manage → '||SQLERRM, lp_caller);
```

**Stesso schema** per “CRITICAL in shift_manage”, “NON-CRITICAL/CRITICAL in shift_calendar”, “NON-CRITICAL/CRITICAL in pattern_default”.

---

### Pattern 11: Skipping plant / Invalid plant (sp_master_shift_processing)

**Prima:**
```sql
INSERT INTO application_data.log_error(
    error_timestamp, error_src, error_msg, error_caller
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    'Skipping plant (No Timezone defined): ' || v_plant_code,
    lp_caller
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, 'Skipping plant (No Timezone defined): ' || v_plant_code, lp_caller);
```

**Analogo** per “Invalid plant or No Timezone in list”.

---

### Pattern 12: (lp_procedure_name, lp_err_msg, COALESCE(lp_caller, 'UNKNOWN CALLER'))

**Prima:**
```sql
INSERT INTO application_data.log_error (
    ...
) VALUES (
    timezone('UTC', current_timestamp),
    lp_procedure_name,
    lp_err_msg,
    COALESCE(lp_caller, 'UNKNOWN CALLER')
);
```

**Dopo:**
```sql
CALL application_data.log_error_write(lp_procedure_name, lp_err_msg, COALESCE(lp_caller, 'UNKNOWN CALLER'));
```

**Procedure:** `sp_shift_pattern_default_single` e contesti in cui il caller può essere NULL.

---

## 4. Riepilogo

| Voce | Esito |
|------|--------|
| Backup `4_create_function_procedure_backup.sql` | Presente (già creato in sessione precedente) |
| Sostituzioni INSERT → log_error_write | Completate per tutte le occorrenze escluse quelle volute in `log_error_write` e in `manage_lk_threshold` |
| Verifica assenza INSERT in log_error | Superata: solo 3 occorrenze volute |
| Coerenza variabili (src, msg, caller) | Verificata procedura per procedura; nessuna incoerenza rilevata |
| Report prima/dopo | Sintesi per pattern sopra |

---

**Fine report.**
