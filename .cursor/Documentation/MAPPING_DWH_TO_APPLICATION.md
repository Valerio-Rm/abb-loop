# Mappatura DWH (SQL Server) -> Application (PostgreSQL)

Documento di riferimento per capire come vengono mappati e sincronizzati i dati DWH nel modello `application_data`.

## Sintesi Rapida

- `Step` DWH -> `lk_machine` (con `source_id = StepIntId`)
- `Machine` DWH -> `lk_component` (con `source_id = MachineIntId`)
- Chiavi target restano a sequence (`machine_id`, `component_id`, ...)
- `source_id` serve per tracciabilita e lookup ETL contestuali, non come vincolo hard di unicita

---

## 1) Contesto e Obiettivo

**Sorgente**
- SQL Server DWH (schema replicato per linea/processo)

**Destinazione**
- PostgreSQL, schema unico `application_data`

**Obiettivo**
- unificare dati multi-linea evitando collisioni di ID sorgente
- mantenere intatte le PK applicative target
- tracciare l'origine tramite `source_id`

---

## 2) Strategia `source_id`

| Tabella target | `source_id` da DWH | Uso principale | Stato unicita |
|---|---|---|---|
| `lk_plant` | `SiteIntId` | mapping plant | indice non univoco |
| `lk_line` | `Line.Id` | mapping linea | indice non univoco su `(plant_id, source_id)` |
| `lk_machine` | `StepIntId` | mapping step | indice non univoco su `(line_id, source_id)` |
| `lk_component` | `MachineIntId` | mapping machine | indice non univoco su `(machine_id, source_id)` |

Note:
- gli indici su `source_id` sono di supporto (performance + tracciabilita)
- le PK target non cambiano
- i lookup ETL risolvono sempre in contesto (`plant_id` / `line_id` / `machine_id`)

---

## 3) Mappatura Entita

| Sorgente DWH | Target PostgreSQL | Significato |
|---|---|---|
| `[sp203_an].[Step]` | `application_data.lk_machine` | stazione/step di linea |
| `[sp203_an].[Machine]` | `application_data.lk_component` | componente associato allo step |

In pratica:
- uno `StepIntId` identifica la riga in `lk_machine` nel contesto linea
- uno `MachineIntId` identifica la riga in `lk_component` nel contesto macchina-step

---

## 4) Relazione M:N `MachineVsStep` -> Gerarchia Target

Nel DWH, `Machine` e `Step` sono molti-a-molti.

Nel target, la relazione viene appiattita in:

`Linea -> lk_machine (step) -> lk_component (machine)`

Regola ETL:
1. risolvi gli step della linea -> `lk_machine(line_id, source_id=StepIntId)`
2. per ogni coppia `(StepIntId, MachineIntId)` -> risolvi/crea `lk_component(machine_id, source_id=MachineIntId)`

---

## 5) Flusso Operativo ETL (alto livello)

1. sync plant/line
2. sync step -> `lk_machine`
3. sync machine -> `lk_component`
4. sync fixture/result/code/shift
5. load `ft_rawdata`

Lookup chiave usati:
- step: `(line_id, source_id=StepIntId)` su `lk_machine`
- machine: `(machine_id, source_id=MachineIntId)` su `lk_component`

---

## 6) Modalita BY_PROCESS (DWH `Line` vuota)

Le procedure correnti gestiscono il caso in cui la tabella DWH `Line` sia vuota:
- `etl_sync_lk_machine`
- `etl_sync_lk_component`
- `etl_sync_lk_fixture`
- `etl_sync_ft_rawdata`

Comportamento:
- risoluzione linea via `Process.ProcessKey` <-> `application_data.lk_line.process_key`
- validazione di coerenza: deve esistere una sola linea target compatibile, altrimenti errore

---

## 7) `is_primary_source` su `lk_component`

### A cosa serve

Quando la stessa `MachineIntId` compare su piu step, si creano piu record `lk_component` con stesso `source_id`.

`is_primary_source` aiuta a marcare un componente "preferito" per `(line_id, source_id)`.

### Stato reale attuale

- impostato dalla logica ETL (primo componente creato)
- **non** protetto da vincolo univoco hard a livello DB

### Importante per i join

Nel flusso corrente di `ft_rawdata`, il path principale senza `StepIntId` non dipende solo da `is_primary_source`, ma passa da:
- `lk_fixture.source_machine_id`
- risoluzione `lk_fixture(source_id, component_id)` nel contesto plant/line

Esempio pattern corrente:

```sql
SELECT lf.fixture_id, lf.line_id, lf.component_id, c.source_id AS machine_source_id
FROM application_data.lk_fixture lf
JOIN application_data.lk_component c ON c.component_id = lf.component_id
WHERE lf.source_id = :fixture_int_id
  AND lf.plant_id = :plant_id
  AND lf.is_deleted = false;
```

---

## 8) Script Coinvolti e Ordine

1. `9_migration_add_source_id.sql`
   - aggiunge `source_id` alle lookup legacy
   - aggiunge campi: `is_start_step`, `is_end_step`, `is_primary_source`, `ideal_cycle_time_ms`
   - ricrea audit table coinvolte

2. `8_dwh_integration_ddl.sql`
   - crea tabelle integrazione DWH (`lk_code`, `lk_shift_dwh`, `lk_fixture`, `lk_result`, `lk_production_time_date`, `ft_rawdata`, ...)
   - lo script dichiara esplicitamente il prerequisito di eseguire prima il punto 1

3. `10_etl_procedures*.sql`
   - contiene le procedure ETL di sincronizzazione e caricamento

---

## 9) Campi Aggiuntivi Rilevanti

- `lk_machine.is_start_step`, `lk_machine.is_end_step` <- da DWH `Step`
- `lk_component.ideal_cycle_time_ms` <- da DWH `MachineVsStep.IdealCycleTimeMs`
- `lk_production_time_date.source_id` <- da DWH `ProductionTimeDate.Id`

---

## 10) Riepilogo Decisioni

| Tema | Decisione |
|---|---|
| Conflitto ID sorgente | gestito con `source_id` + contesto applicativo |
| PK target | restano sequence native |
| M:N DWH | appiattita in gerarchia step -> component |
| `is_primary_source` | supporto logico ETL, non vincolo hard DB |
| Join senza Step | path operativo su fixture/component contestuale |
