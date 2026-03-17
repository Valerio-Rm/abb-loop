# Modalita di esecuzione procedure ETL

Questo documento raccoglie tutte le modalita operative per:

- `application_staging.etl_run_all_lookups`
- `application_staging.etl_sync_ft_rawdata`
- `application_data.populate_ft_quality_fpy`
- `application_data.populate_ft_oee`

## 1) `application_staging.etl_run_all_lookups`

### Firma

```sql
CALL application_staging.etl_run_all_lookups(
  p_caller               VARCHAR DEFAULT 'ETL_SYSTEM',
  p_dry_run              BOOLEAN DEFAULT false,
  p_run_ft_rawdata       BOOLEAN DEFAULT false,
  p_ft_rawdata_date_min  DATE    DEFAULT NULL,
  p_ft_rawdata_date_max  DATE    DEFAULT NULL,
  p_foreign_schema       TEXT    DEFAULT 'dwh_remote',
  p_foreign_schemas      TEXT[]  DEFAULT NULL,
  p_schema_group         TEXT    DEFAULT NULL,
  p_continue_on_error    BOOLEAN DEFAULT false
);
```

### Modalita di esecuzione

1. **Schedulata standard (lookups only)**
   - `p_ft_rawdata_date_min = NULL` e `p_ft_rawdata_date_max = NULL`
   - Esegue solo i lookup (+ downtime), senza `ft_rawdata` se `p_run_ft_rawdata=false`.
   - Applica time-gate per plant locale `00:00-00:59` (fuori finestra -> skip).

2. **Schedulata completa (lookups + ft_rawdata di ieri)**
   - Stesse date `NULL/NULL`, ma `p_run_ft_rawdata=true`.
   - Carica downtime e `ft_rawdata` per **ieri locale**.

3. **Manuale con data minima (range aperto)**
   - `p_ft_rawdata_date_min` valorizzata, `p_ft_rawdata_date_max = NULL`.
   - Carica tutte le date `>= p_ft_rawdata_date_min` presenti in `lk_production_time_date`.
   - In questa modalita non usa la finestra oraria schedulata.

4. **Manuale con range chiuso**
   - `p_ft_rawdata_date_min` e `p_ft_rawdata_date_max` valorizzate.
   - Carica intervallo `[min, max]` (downtime + eventualmente `ft_rawdata`).

5. **Caso anomalo: solo `date_max`**
   - `p_ft_rawdata_date_min = NULL`, `p_ft_rawdata_date_max` valorizzata.
   - Il codice ricade su caricamento di ieri (fallback).

6. **Selezione sorgente: schema singolo**
   - Usa `p_foreign_schema` (default `dwh_remote`).

7. **Selezione sorgente: multi-schema esplicito**
   - Usa `p_foreign_schemas` (array), che ha priorita su `p_foreign_schema`.

8. **Selezione sorgente: gruppo schema**
   - Usa `p_schema_group` con risoluzione da `application_staging.etl_source_schema_cfg`.
   - Se il gruppo non ha schemi abilitati -> eccezione.

9. **Error handling strict (default)**
   - `p_continue_on_error=false`: errore su uno schema => rollback run.

10. **Error handling tollerante**
    - `p_continue_on_error=true`: continua sugli altri schemi; traccia warning/fail in monitoring.

11. **Dry run**
    - `p_dry_run=true`: esegue i passi ma forza rollback finale.

### Esempi pratici

```sql
-- Lookups only (schedulata)
CALL application_staging.etl_run_all_lookups('ETL_DAILY');

-- Lookups + ft_rawdata di ieri
CALL application_staging.etl_run_all_lookups('ETL_DAILY', false, true, NULL, NULL);

-- Lookups + ft_rawdata da una data in avanti
CALL application_staging.etl_run_all_lookups('ETL_MANUAL', false, true, '2026-01-01', NULL);

-- Lookups + ft_rawdata su range chiuso
CALL application_staging.etl_run_all_lookups('ETL_MANUAL', false, true, '2026-01-01', '2026-01-10');

-- Esecuzione multi-schema esplicita
CALL application_staging.etl_run_all_lookups(
  p_caller => 'ETL_MULTI',
  p_foreign_schemas => ARRAY['dwh_remote', 'dwh_remote2']
);

-- Esecuzione per gruppo schema
CALL application_staging.etl_run_all_lookups(
  p_caller => 'ETL_GROUP',
  p_schema_group => 'ABB_EU'
);

-- Continua anche se uno schema fallisce
CALL application_staging.etl_run_all_lookups(
  p_caller => 'ETL_TOLERANT',
  p_continue_on_error => true
);

-- Dry run
CALL application_staging.etl_run_all_lookups(
  p_caller => 'ETL_TEST',
  p_dry_run => true,
  p_run_ft_rawdata => true,
  p_ft_rawdata_date_min => '2026-01-01',
  p_ft_rawdata_date_max => '2026-01-02'
);
```

---

## 2) `application_staging.etl_sync_ft_rawdata`

### Firma

```sql
CALL application_staging.etl_sync_ft_rawdata(
  p_caller         VARCHAR DEFAULT 'ETL_SYSTEM',
  p_target_date    DATE    DEFAULT NULL,
  p_dry_run        BOOLEAN DEFAULT false,
  p_foreign_schema TEXT    DEFAULT 'dwh_remote'
);
```

### Modalita di esecuzione

1. **Default schedulata (giorno precedente)**
   - `p_target_date=NULL` -> usa ieri (`CURRENT_DATE - 1`).

2. **Manuale singolo giorno**
   - `p_target_date` valorizzata -> carica solo quel giorno.

3. **Per schema sorgente specifico**
   - `p_foreign_schema` consente di scegliere il FDW schema.

4. **Dry run**
   - `p_dry_run=true` per test con rollback.

5. **No data per data target**
   - Se non esiste `ProductionTimeDate` per il giorno richiesto, termina senza errore (log "No data to process").

### Esempi pratici

```sql
-- Ieri, schema di default
CALL application_staging.etl_sync_ft_rawdata();

-- Giorno specifico
CALL application_staging.etl_sync_ft_rawdata(
  p_caller => 'ETL_MANUAL',
  p_target_date => '2026-03-01'
);

-- Giorno specifico su schema alternativo
CALL application_staging.etl_sync_ft_rawdata(
  p_caller => 'ETL_ALT_SCHEMA',
  p_target_date => '2026-03-01',
  p_foreign_schema => 'dwh_remote2'
);

-- Dry run
CALL application_staging.etl_sync_ft_rawdata(
  p_caller => 'ETL_TEST',
  p_target_date => '2026-03-01',
  p_dry_run => true
);
```

---

## 3) `application_data.populate_ft_quality_fpy`

### Firma

```sql
CALL application_data.populate_ft_quality_fpy(
  p_date_min      DATE    DEFAULT NULL,
  p_date_max      DATE    DEFAULT NULL,
  p_plant_id      BIGINT  DEFAULT NULL,
  p_line_id       BIGINT  DEFAULT NULL,
  p_user_id       BIGINT  DEFAULT NULL,
  p_user_fullname VARCHAR DEFAULT NULL
);
```

### Vincoli importanti

- `p_user_id` e `p_user_fullname` sono **obbligatori**: se `NULL` la procedura va in eccezione.
- In modalita schedulata (`date_min/date_max` entrambe `NULL`) applica time-gate locale plant `00:00-00:59`.
- Aggiorna `ft_kpi_target` solo su record esistenti (no insert nuovi target).

### Modalita di esecuzione

1. **Schedulata globale**
   - `p_date_min=NULL`, `p_date_max=NULL`, `p_plant_id=NULL`, `p_line_id=NULL`.
   - Processa tutti i plant attivi/cancellati=false, ma solo se nella finestra oraria locale.
   - Usa "ieri locale" per ogni plant.

2. **Schedulata per plant**
   - Come sopra, ma con `p_plant_id` valorizzato.

3. **Manuale con range chiuso**
   - `p_date_min` e `p_date_max` valorizzate.
   - Nessun vincolo di finestra oraria schedulata.

4. **Manuale con range aperto**
   - `p_date_min` valorizzata, `p_date_max=NULL` (equivale a da `date_min` in avanti nel filtro della procedura).

5. **Manuale single-day**
   - `p_date_min = p_date_max`.

6. **Filtro linea**
   - `p_line_id` valorizzato (con eventuale `p_plant_id`) per limitare il calcolo a una linea.

### Esempi pratici

```sql
-- Schedulata globale (richiede utente tecnico valorizzato)
CALL application_data.populate_ft_quality_fpy(
  NULL, NULL, NULL, NULL,
  9999999999999,
  'ETL_SYSTEM'
);

-- Schedulata per plant
CALL application_data.populate_ft_quality_fpy(
  NULL, NULL, 101, NULL,
  9999999999999,
  'ETL_SYSTEM'
);

-- Manuale range chiuso per plant
CALL application_data.populate_ft_quality_fpy(
  '2026-03-01', '2026-03-07',
  101, NULL,
  9999999999999,
  'ETL_SYSTEM'
);

-- Manuale single-day per linea
CALL application_data.populate_ft_quality_fpy(
  '2026-03-05', '2026-03-05',
  101, 2001,
  9999999999999,
  'ETL_SYSTEM'
);
```

---

## 4) `application_data.populate_ft_oee`

### Firma

```sql
CALL application_data.populate_ft_oee(
  p_date_min      DATE    DEFAULT NULL,
  p_date_max      DATE    DEFAULT NULL,
  p_plant_id      BIGINT  DEFAULT NULL,
  p_line_id       BIGINT  DEFAULT NULL,
  p_user_id       BIGINT  DEFAULT NULL,
  p_user_fullname VARCHAR DEFAULT NULL
);
```

### Vincoli importanti

- `p_user_id` e `p_user_fullname` sono **obbligatori**: se `NULL` la procedura va in eccezione.
- In modalita schedulata (`date_min/date_max` entrambe `NULL`) applica time-gate locale plant `00:00-00:59`.
- In modalita manuale usa direttamente il range richiesto (`p_date_min/p_date_max`).
- Popola tabelle OEE (`ft_oee_shift`, `ft_oee`) e aggiorna KPI OEE su `ft_kpi_target`.

### Modalita di esecuzione

1. **Schedulata globale**
   - `p_date_min=NULL`, `p_date_max=NULL`, `p_plant_id=NULL`, `p_line_id=NULL`.
   - Processa ieri locale per ogni plant nella finestra oraria consentita.

2. **Schedulata per plant**
   - Come sopra, ma con `p_plant_id` valorizzato.

3. **Manuale con range chiuso**
   - `p_date_min` e `p_date_max` valorizzate.

4. **Manuale con range aperto**
   - `p_date_min` valorizzata, `p_date_max=NULL`.

5. **Manuale single-day**
   - `p_date_min = p_date_max`.

6. **Filtro linea**
   - `p_line_id` valorizzato (con eventuale `p_plant_id`) per limitare il calcolo.

### Esempi pratici

```sql
-- Schedulata globale
CALL application_data.populate_ft_oee(
  NULL, NULL, NULL, NULL,
  9999999999999,
  'ETL_SYSTEM'
);

-- Schedulata per plant
CALL application_data.populate_ft_oee(
  NULL, NULL, 101, NULL,
  9999999999999,
  'ETL_SYSTEM'
);

-- Manuale range chiuso per plant
CALL application_data.populate_ft_oee(
  '2026-03-01', '2026-03-07',
  101, NULL,
  9999999999999,
  'ETL_SYSTEM'
);

-- Manuale single-day per linea
CALL application_data.populate_ft_oee(
  '2026-03-05', '2026-03-05',
  101, 2001,
  9999999999999,
  'ETL_SYSTEM'
);
```

---

## Nota operativa di catena ETL

Nello script ETL e presente un trigger su `application_staging.etl_monitoring` che, quando una run passa a `success`, invoca automaticamente:

```sql
CALL application_data.populate_ft_quality_fpy(
  NEW.date_min,
  NEW.date_max,
  NEW.plant_id,
  NULL,
  9999999999999,
  'ETL_SYSTEM'
);

CALL application_data.populate_ft_oee(
  NEW.date_min,
  NEW.date_max,
  NEW.plant_id,
  NULL,
  9999999999999,
  'ETL_SYSTEM'
);
```

Quindi, in catena orchestrata, sia `populate_ft_quality_fpy` sia `populate_ft_oee` possono partire automaticamente a valle di `etl_run_all_lookups` (se monitoring chiude in `success`).

