# ETL Procedures Overview (`10_etl_procedures.sql`)

Panoramica operativa delle procedure ETL in `application_staging`: scopo, dipendenze, vincoli e flusso.

## Quick View

- Entry point principale: `application_staging.etl_run_all_lookups`
- Origine dati: SQL Server DWH via FDW (`dwh_remote`, `dwh_remote2`, ...)
- Target dati: `application_data` (lookup + fact)
- Log/stato: `application_staging.etl_log_operation`, `application_staging.etl_log_error`, `application_staging.etl_monitoring`
- Post-success automatico: trigger su monitoring -> `application_data.populate_ft_quality_fpy` + `application_data.populate_ft_oee`

---

## 1) Procedure e Ruolo

| Procedura | Scopo |
|---|---|
| `etl_run_all_lookups` | Master ETL: esegue tutte le sync lookup, poi downtime, poi opzionale rawdata; singola transazione |
| `etl_monitoring` | Start/update/end run ETL (`running`, `success`, `failed`, `skipped`) |
| `etl_log_error_write` | Persistenza errori via dblink (anche dopo rollback) |
| `etl_sync_lk_production_time_date` | Sync calendario produzione |
| `etl_sync_lk_plant` | Sync plant (`source_id` da Site) |
| `etl_sync_lk_line` | Sync linee |
| `etl_sync_lk_machine` | Sync step/macchine (`lk_machine`) |
| `etl_sync_lk_component` | Sync componenti (`lk_component`) |
| `etl_sync_lk_fixture` | Sync fixture |
| `etl_sync_lk_shift` | Sync turni (`lk_shift_dwh`) |
| `etl_sync_lk_code` | Sync codici |
| `etl_sync_lk_result` | Sync risultati |
| `etl_sync_downtime` | Load downtime su `ft_downtime` |
| `etl_sync_ft_rawdata` | Load produzione su `ft_rawdata` |

---

## 2) Chi Chiama Cosa

### Chiamante principale
- `etl_run_all_lookups` viene invocata da scheduler/job/script esterni.
- È il punto di ingresso standard dell’intero flusso ETL.

### Chiamate interne
- `etl_run_all_lookups` chiama:
  - `etl_monitoring` (`start`, `update`, `end`)
  - tutte le `etl_sync_*`
  - `etl_log_error_write` nei percorsi errore

### Trigger automatico post-success
- Trigger `trg_etl_monitoring_after_success` su `application_staging.etl_monitoring`
- Condizione: `state = 'success'`
- Azione:
  - `CALL application_data.populate_ft_quality_fpy(...)`
  - `CALL application_data.populate_ft_oee(...)`
- Le due chiamate sono gestite in blocchi separati: eventuale errore su una non blocca l'altra.

---

## 3) Ordine di Esecuzione Effettivo

Ordine interno della master:

1. `etl_sync_lk_production_time_date`
2. `etl_sync_lk_plant`
3. `etl_sync_lk_line`
4. `etl_sync_lk_machine`
5. `etl_sync_lk_component`
6. `etl_sync_lk_fixture`
7. `etl_sync_lk_shift`
8. `etl_sync_lk_code`
9. `etl_sync_lk_result`
10. `etl_sync_downtime`
11. `etl_sync_ft_rawdata` (solo se abilitato)

Perche questo ordine:
- `downtime` e `ft_rawdata` dipendono dalle lookup gia valorizzate (FK/logica di mapping).

---

## 4) Dipendenze Tecniche

| Dipendenza | Dove serve | Nota |
|---|---|---|
| `application_data.create_plant_partition` | `etl_sync_downtime`, `etl_sync_ft_rawdata` | crea partizioni plant |
| `application_data.create_monthly_partition` | `etl_sync_downtime`, `etl_sync_ft_rawdata` | crea partizioni mensili |
| FDW schema (`p_foreign_schema`) | tutte le `etl_sync_*` | deve esporre le tabelle/viste DWH attese |
| `etl_source_schema_cfg` | `etl_run_all_lookups` con `p_schema_group` | risolve lista schemi da processare |

---

## 5) Configurazioni da Verificare

### Obbligatorie o fortemente consigliate

| Oggetto | Uso | Cosa verificare |
|---|---|---|
| `application_data.log_error_write_cfg` | connessione dblink (`dblink_conn_str`) | presente e valorizzata |
| `application_staging.etl_source_schema_cfg` | gruppi schemi sorgente | necessario solo con `p_schema_group` |
| `application_data.lk_plant` | mapping `plant_code = Site.SiteKey` + timezone | mapping coerente per ogni schema |

---

## 6) Vincoli Operativi

### Finestra oraria locale
- In modalità “ieri” (`date_min`/`date_max` NULL), la run valida è nella finestra plant locale `00:00-00:59`.
- Fuori finestra: schema skip con log operativo.

### Un solo plant per run master
- Tutti gli schemi passati nella stessa chiamata devono risolvere lo stesso `plant_id`.
- Mismatch plant -> errore + rollback.

### Requisiti FDW
- Gli schemi devono avere le strutture attese (`Site`, `Line`, `MachineVsStep`, `Fixture`, `Code`, `Result`, `ProductionTimeDate`, `DeviceOnStepGrouped`, `Downtime`, ...).

### Partizionamento
- Le funzioni di creazione partizioni devono essere deployate e funzionanti.

---

## 7) Logging e Stato Run

| Tabella | Contenuto |
|---|---|
| `application_staging.etl_monitoring` | stato run (`running`/`success`/`failed`/`skipped`), date e plant |
| `application_staging.etl_log_operation` | log operativo degli step |
| `application_staging.etl_log_error` | log errori persistenti via `etl_log_error_write` |

Nota:
- Se tutti gli schemi vengono saltati, lo stato finale è `skipped` e il trigger post-success non parte.

---

## 8) Flusso End-to-End

1. `CALL application_staging.etl_run_all_lookups(...)`
2. `etl_monitoring('start')` -> run `running`
3. loop sugli schemi FDW:
   - risoluzione plant/timezone
   - eventuale gate orario
   - esecuzione sync in ordine
4. chiusura run:
   - `success` -> trigger -> `populate_ft_quality_fpy` + `populate_ft_oee`
   - `failed` -> log errore persistente + rollback transazione
   - `skipped` -> nessun trigger post-success

---

## 9) Riferimenti File

- Definizioni ETL/trigger: `10_etl_procedures.sql`
- Deploy monitoring: `deploy_etl_monitoring.sql`, `deploy_etl_monitoring_procs.sql`
- Config schemi sorgente: `8_dwh_integration_ddl.sql` (`etl_source_schema_cfg`)
- Config dblink error logging: `deploy_log_error_write_cfg.sql`
- Procedure post-success: `4_create_function_procedure.sql`, `deploy_populate_ft_quality_fpy.sql`, `deploy_populate_ft_oee.sql`
