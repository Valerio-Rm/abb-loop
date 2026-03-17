# ETL Flow: DWH SQL Server -> Application PostgreSQL

Guida operativa del flusso ETL tra sorgenti DWH (via FDW) e target PostgreSQL.

## Quick Summary

- Orchestratore: `application_staging.etl_run_all_lookups`
- Target principale: `application_data` (lookup + fact)
- Log/stato: `application_staging.etl_log_operation`, `application_staging.etl_log_error`, `application_staging.etl_monitoring`
- Post-processing automatico: trigger su monitoring `success` -> `application_data.populate_ft_quality_fpy`

---

## 1) Architettura

```text
SQL Server DWH (piu database, stessa struttura)
        |
        | FDW schemas (es. dwh_remote, dwh_remote2, ...)
        v
application_staging (procedure ETL + logging + monitoring)
        |
        v
application_data (lookup + fact partizionate)
```

---

## 2) Mappatura Entita DWH -> Target

| DWH | Target | source_id | Note |
|---|---|---|---|
| `ProductionTimeDate` | `lk_production_time_date` | `ProductionTimeDate.Id` | calendario produzione, `id_day` in formato `YYYYMMDD` |
| `Site` | `lk_plant` | `SiteIntId` | mapping plant (`plant_code = SiteKey`) |
| `Line` | `lk_line` | `Line.Id` | mapping tramite `line_code_erp = LineKey` |
| `Step` | `lk_machine` | `StepIntId` | include `is_start_step`, `is_end_step` |
| `Machine` (via `MachineVsStep`) | `lk_component` | `MachineIntId` | include `ideal_cycle_time_ms`, `is_primary_source` |
| `Fixture` | `lk_fixture` | `FixtureIntId` | una riga per `(fixture, component_id)`; include `source_machine_id` |
| `Shift` | `lk_shift_dwh` | `ShiftIntId` | turni DWH |
| `Code` | `lk_code` | `CodeIntId` | codici produzione/scarto |
| `Result` | `lk_result` | `ResultIntId` | esito produzione |
| `DeviceOnStepGrouped` | `ft_rawdata` | chiavi sorgente multiple | fact giornaliera per step/fixture/pass |
| `Downtime` | `ft_downtime` | `Downtime.Id` | fact downtime |

---

## 3) Procedure ETL Coinvolte

| Procedura | Ruolo |
|---|---|
| `etl_run_all_lookups` | master flow: lookup + downtime + opzionale rawdata |
| `etl_monitoring` | stato run (`running/success/failed/skipped`) |
| `etl_log_error_write` | persistenza errori via dblink |
| `etl_sync_lk_production_time_date` | sync calendario date |
| `etl_sync_lk_plant` | sync plant |
| `etl_sync_lk_line` | sync linee |
| `etl_sync_lk_machine` | sync step su `lk_machine` |
| `etl_sync_lk_component` | sync machine su `lk_component` |
| `etl_sync_lk_fixture` | sync fixture |
| `etl_sync_lk_shift` | sync shift |
| `etl_sync_lk_code` | sync code |
| `etl_sync_lk_result` | sync result |
| `etl_sync_downtime` | load downtime |
| `etl_sync_ft_rawdata` | load produzione |

---

## 4) Ordine Esecutivo Reale

Ordine interno di `etl_run_all_lookups`:

1. `etl_sync_lk_production_time_date`
2. `etl_sync_lk_plant`
3. `etl_sync_lk_line`
4. `etl_sync_lk_machine`
5. `etl_sync_lk_component`
6. `etl_sync_lk_fixture`
7. `etl_sync_lk_shift`
8. `etl_sync_lk_code`
9. `etl_sync_lk_result`
10. `etl_sync_downtime` (sempre)
11. `etl_sync_ft_rawdata` (solo se `p_run_ft_rawdata = true`)

Questo ordine rispetta le dipendenze di mapping/FK.

---

## 5) Modalita di Esecuzione Master

Firma corrente:

```sql
CALL application_staging.etl_run_all_lookups(
  p_caller,
  p_dry_run,
  p_run_ft_rawdata,
  p_ft_rawdata_date_min,
  p_ft_rawdata_date_max,
  p_foreign_schema,
  p_foreign_schemas,
  p_schema_group,
  p_continue_on_error
);
```

Modalita:

- **Schedulata (ieri):** `date_min = NULL` e `date_max = NULL`
- **Manuale range chiuso:** `date_min` e `date_max` valorizzate
- **Manuale range aperto:** `date_min` valorizzata, `date_max = NULL`
- **Schema singolo:** `p_foreign_schema`
- **Multi-schema:** `p_foreign_schemas` o `p_schema_group`
- **Dry-run:** `p_dry_run = true` (rollback finale)
- **Best effort:** `p_continue_on_error = true`

---

## 6) Vincoli Operativi

### Time gate locale plant
- In modalità schedulata (`NULL/NULL`), l'esecuzione per plant è valida solo tra `00:00` e `00:59` ora locale.

### Coerenza plant in una run
- Tutti gli schemi elaborati nella stessa chiamata devono mappare allo stesso `plant_id`.

### Configurazioni critiche
- `application_data.log_error_write_cfg` (`dblink_conn_str`)
- `application_staging.etl_source_schema_cfg` (necessaria se usi `p_schema_group`)
- `application_data.lk_plant` coerente con `Site.SiteKey`

### Prerequisito estensione
- `CREATE EXTENSION IF NOT EXISTS dblink;`

---

## 7) Log, Monitoring e Trigger

| Oggetto | Uso |
|---|---|
| `etl_log_operation` | traccia step operativi |
| `etl_log_error` | persistenza errori ETL |
| `etl_monitoring` | stato run e metadati run |

Trigger:
- `trg_etl_monitoring_after_success`
- Su transizione a `state='success'` chiama `application_data.populate_ft_quality_fpy(date_min, date_max, plant_id, ...)`

---

## 8) Logica di Caricamento `ft_rawdata` (sintesi)

Passi principali in `etl_sync_ft_rawdata`:

1. risolvi `target_date` (`NULL` -> ieri)
2. risolvi contesto `plant` + `line` (supporta anche BY_PROCESS quando DWH `Line` è vuota)
3. risolvi `ProductionTimeDateId` e `day_id`
4. crea partizioni mancanti (`plant`, `monthly`)
5. leggi `DeviceOnStepGrouped` e risolvi chiavi target tramite lookup
6. insert/update idempotente su `ft_rawdata`

Nota:
- la risoluzione fixture/component usa `lk_fixture` + `source_machine_id` nel contesto plant/line/step.

---

## 9) Conversione Date

| Sorgente | Target |
|---|---|
| `ProductionTimeDate.Id` | `lk_production_time_date.source_id` |
| `Year/Month/Day` DWH | `day_id` (`YYYYMMDD`) su fact |

`etl_sync_lk_production_time_date` mantiene il calendario; `etl_sync_ft_rawdata` usa quel contesto per mappare la data di produzione.

---

## 10) Modello Dati (vista logica)

```text
lk_plant 1:N lk_line 1:N lk_machine 1:N lk_component
                          ^
                          |
                    lk_fixture (per step/component)

ft_rawdata -> lk_date/lk_production_time_date
          -> lk_plant
          -> lk_line
          -> lk_machine
          -> lk_component
          -> lk_fixture
          -> lk_shift_dwh
          -> lk_code (opzionale)
          -> lk_result (opzionale)
```

---

## 11) Esempi Chiamata

```sql
-- Solo lookup + downtime (schedulata)
CALL application_staging.etl_run_all_lookups('ETL_DAILY');

-- Lookup + rawdata per ieri
CALL application_staging.etl_run_all_lookups('ETL_DAILY', false, true, NULL, NULL);

-- Lookup + rawdata su range
CALL application_staging.etl_run_all_lookups('ETL_MANUAL', false, true, '2026-01-01', '2026-01-10');

-- Dry run
CALL application_staging.etl_run_all_lookups('ETL_TEST', true, true, '2026-01-01', '2026-01-02');
```

---

## 12) File di Riferimento

- `10_etl_procedures_ByProcess_SoftDelete.sql` (versione corrente usata in progetto)
- `10_etl_procedures.sql` (variante storica/base)
- `8_dwh_integration_ddl.sql` (DDL integrazione + config tabelle staging)
- `9_migration_add_source_id.sql` (migrazione campi source_id e correlati)
- `deploy_etl_monitoring.sql`, `deploy_etl_monitoring_procs.sql`
- `deploy_populate_ft_quality_fpy.sql`
