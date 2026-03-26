package snippet;

import it.decisyon.ext.program.*;
import it.decisyon.ext.program.context.IExtProgramExecutionContext;
import it.decisyon.ext.sdk.impl.logger.ExtLoggerSDK;
import it.decisyon.ext.sdk.impl.restapi.ExtRestApiExecutionResult;
import static it.decisyon.ext.sdk.impl.restapi.ExtRestApiDefinerSDK.givenRestApi;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.math.BigDecimal;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Collections;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Inventory end-to-end flow:
 * <ol>
 *   <li>Read SharePoint workbook sheets through Microsoft Graph.</li>
 *   <li>Load staging + ingestion run status (LOADING -> READY_FOR_SYNC).</li>
 *   <li>Execute {@code CALL etl_run_inventory_full} (change 12 + change 13).</li>
 *   <li>COMMIT after successful full run.</li>
 * </ol>
 * Configure PLANT/USER and Graph credentials through environment variables.
 * RUN_ID is generated in Java for each plant execution.
 * Multi-tenant loop follows the same JDBC pattern as {@code ETL_PROCEDURES_QUALITY_PRODUCTIVITY.java}.
 */
public class Snippet implements ExtIDecisyonProgram {

    /**
     * If > 0 run only that plant; if <= 0 auto-loop active plants from lk_plant.
     */
    private static final long PLANT_ID = 0L;
    private static final long USER_ID = 1L;
    private static final String USER_FULLNAME = "ETL_INVENTORY_DAILY";

    private static final String PROC_FULL =
            "CALL application_staging.etl_run_inventory_full(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
    private static final String MON_PROC = "application_staging.etl_run_inventory_full";
    private static final String FDW_SCHEMA = "inventory_remote";
    private static final int MIN_EXPECTED_SHEETS = 4;
    private static final String LOG_PREFIX = "[INV-DB-CORR]";

    private static final String ENV_GRAPH_TENANT_ID = "MSGRAPH_TENANT_ID";
    private static final String ENV_GRAPH_CLIENT_ID = "MSGRAPH_CLIENT_ID";
    private static final String ENV_GRAPH_CLIENT_SECRET = "MSGRAPH_CLIENT_SECRET";
    private static final String ENV_GRAPH_SITE_ID = "MSGRAPH_SITE_ID";
    private static final String ENV_GRAPH_DRIVE_ID = "MSGRAPH_DRIVE_ID";
    private static final String ENV_GRAPH_ITEM_ID = "MSGRAPH_ITEM_ID";

    private ExtRestApiExecutionResult allTenantsResponse = new ExtRestApiExecutionResult();
    private ExtRestApiExecutionResult tenantDbResponse = new ExtRestApiExecutionResult();

    @Override
    public void execute(IExtProgramExecutionContext context) throws Exception {
        if (USER_ID <= 0 || USER_FULLNAME == null || USER_FULLNAME.trim().isEmpty()) {
            throw new IllegalStateException(
                    "Configure Snippet.USER_ID and Snippet.USER_FULLNAME before deploy."
            );
        }

        JSONObject report = new JSONObject();
        givenRestApi().withAlias("GetAllTenant")
                .then().execute().and().saveResponseTo(allTenantsResponse);

        if (!"200".equals(allTenantsResponse.getStatus())) {
            throw new Exception("Unable to retrieve tenant list. Status: " + allTenantsResponse.getStatus());
        }

        JSONObject allTenantsJson = new JSONObject(allTenantsResponse.getBody());
        JSONArray tenantsArray = allTenantsJson.getJSONObject("_embedded").getJSONArray("tenants");

        JSONArray details = new JSONArray();
        int successCount = 0;
        int errorCount = 0;

        for (int i = 0; i < tenantsArray.length(); i++) {
            String tenantName = tenantsArray.getJSONObject(i).optString("name", "").trim();
            if (tenantName.isEmpty()) {
                errorCount++;
                continue;
            }

            JSONObject tenantStatus = new JSONObject();
            tenantStatus.put("tenant", tenantName);

            try {
                givenRestApi().withAlias("GetTenantConnections")
                        .withParam("tenant_name").mappedToValue(tenantName)
                        .then().execute().and().saveResponseTo(tenantDbResponse);

                if ("200".equals(tenantDbResponse.getStatus())) {
                    logInfo("tenant", "start tenant=" + tenantName + " plant_scope=" + PLANT_ID);
                    runInventoryOnConnection(tenantDbResponse.getBody(), tenantName);
                    tenantStatus.put("status", "SUCCESS");
                    successCount++;
                    logInfo("tenant", "completed tenant=" + tenantName + " plant_scope=" + PLANT_ID);
                } else {
                    tenantStatus.put("status", "ERROR");
                    tenantStatus.put("message", "Connections API status: " + tenantDbResponse.getStatus());
                    errorCount++;
                }
            } catch (Exception e) {
                ExtLoggerSDK.error("Inventory sync tenant " + tenantName + ": " + e.getMessage());
                tenantStatus.put("status", "ERROR");
                tenantStatus.put("message", e.getMessage());
                errorCount++;
            }
            details.put(tenantStatus);
        }

        report.put("total_processed", tenantsArray.length());
        report.put("success_count", successCount);
        report.put("error_count", errorCount);
        report.put("details", details);

        context.setResultAttribute("PROGRAM_RESULT", report.toString());
        context.setAttribute("?snippet_output?", "Inventory sharepoint+sync tenants OK=" + successCount + " ERR=" + errorCount);
    }

    private void runInventoryOnConnection(String connectionJsonBody, String tenantName) throws Exception {
        JSONObject json = new JSONObject(connectionJsonBody);
        JSONArray connections = json.getJSONArray("connections");
        JSONObject params = null;

        for (int i = 0; i < connections.length(); i++) {
            JSONObject connObj = connections.getJSONObject(i);
            if ("APPLICATION_DATA".equals(connObj.optString("alias"))) {
                params = connObj.getJSONObject("connection").getJSONObject("connectionParams");
                break;
            }
        }

        if (params == null) {
            throw new Exception("Alias APPLICATION_DATA not found in connections JSON");
        }

        String url = "jdbc:postgresql://"
                + params.getString("host") + ":" + params.getString("port") + "/"
                + params.getString("database") + "?currentSchema=" + params.getString("schema");
        String user = params.getString("username");
        String pass = params.getString("password");

        Connection conn = null;
        try {
            Class.forName("org.postgresql.Driver");
            conn = DriverManager.getConnection(url, user, pass);
            conn.setAutoCommit(false);
            logInfo("db", "connected tenant=" + tenantName);

            List<Long> plantIds = resolvePlantIds(conn);
            if (plantIds.isEmpty()) {
                logInfo("tenant", "no active plant found; skip tenant=" + tenantName);
                return;
            }

            for (Long plantId : plantIds) {
                UUID runId = UUID.randomUUID();
                logInfo("plant", "start tenant=" + tenantName + " plant_id=" + plantId + " run_id=" + runId);

                logInfo("graph", "start ingest tenant=" + tenantName + " plant_id=" + plantId + " run_id=" + runId);
                ingestWorkbookFromGraphToStaging(conn, runId, plantId);
                conn.commit();
                logInfo("graph", "ingest committed tenant=" + tenantName + " plant_id=" + plantId + " run_id=" + runId);

                logInfo("sql", "start call " + MON_PROC + " tenant=" + tenantName + " plant_id=" + plantId + " run_id=" + runId);
                try (CallableStatement cs = conn.prepareCall(PROC_FULL)) {
                    cs.setObject(1, runId);
                    cs.setLong(2, plantId);
                    cs.setLong(3, USER_ID);
                    cs.setString(4, USER_FULLNAME);
                    cs.setNull(5, Types.NUMERIC);     // p_day_id
                    cs.setString(6, FDW_SCHEMA);       // p_fdw_schema
                    cs.setBoolean(7, true);            // p_take_snapshot
                    cs.setBoolean(8, true);            // p_run_purge
                    cs.setBoolean(9, false);           // p_purge_blocking
                    cs.setInt(10, 5000);               // p_purge_batch_size
                    cs.execute();
                }
                conn.commit();
                logInfo("sql", "call committed " + MON_PROC + " tenant=" + tenantName + " plant_id=" + plantId + " run_id=" + runId);

                pollMonitoringAndRequireSuccess(conn, MON_PROC, plantId);
                logInfo("monitoring", "success tenant=" + tenantName + " plant_id=" + plantId + " run_id=" + runId + " procedure=" + MON_PROC);
            }
        } catch (Exception e) {
            if (conn != null) {
                try {
                    conn.rollback();
                } catch (SQLException se) {
                    ExtLoggerSDK.warn("rollback failed: " + se.getMessage());
                }
            }
            throw e;
        } finally {
            if (conn != null) {
                try {
                    conn.close();
                } catch (SQLException ignored) {
                }
            }
        }
    }

    private List<Long> resolvePlantIds(Connection conn) throws SQLException {
        if (PLANT_ID > 0) {
            return Collections.singletonList(PLANT_ID);
        }
        List<Long> plants = new ArrayList<>();
        String sql = "SELECT plant_id FROM application_data.lk_plant WHERE is_active = true AND is_deleted = false ORDER BY plant_id";
        try (PreparedStatement ps = conn.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                plants.add(rs.getLong("plant_id"));
            }
        }
        return plants;
    }

    private void ingestWorkbookFromGraphToStaging(Connection conn, UUID runId, long plantId) throws Exception {
        String tenantId = getRequiredEnv(ENV_GRAPH_TENANT_ID);
        String clientId = getRequiredEnv(ENV_GRAPH_CLIENT_ID);
        String clientSecret = getRequiredEnv(ENV_GRAPH_CLIENT_SECRET);
        String siteId = getRequiredEnv(ENV_GRAPH_SITE_ID);
        String driveId = getRequiredEnv(ENV_GRAPH_DRIVE_ID);
        String itemId = getRequiredEnv(ENV_GRAPH_ITEM_ID);

        upsertIngestionRun(conn, runId, plantId, "LOADING", "Graph workbook ingest in progress");
        clearStagingForRun(conn, runId, plantId);

        String accessToken = acquireGraphAccessToken(tenantId, clientId, clientSecret);
        logInfo("graph", "access token acquired for run_id=" + runId + " plant_id=" + plantId);
        List<String> sheets = listWorksheetNames(accessToken, siteId, driveId, itemId);
        logInfo("graph", "worksheets discovered=" + sheets.size() + " run_id=" + runId + " plant_id=" + plantId);
        if (sheets.size() < MIN_EXPECTED_SHEETS) {
            markIngestionFailed(conn, runId, plantId, "Workbook has less than " + MIN_EXPECTED_SHEETS + " sheets");
            throw new IllegalStateException("Workbook has less than " + MIN_EXPECTED_SHEETS + " sheets");
        }

        int loadedSheets = 0;
        for (String sheetName : sheets) {
            upsertSheetStatus(conn, runId, sheetName, "RUNNING", 0, null);
            try {
                logInfo("graph", "sheet read start sheet=" + sheetName + " run_id=" + runId + " plant_id=" + plantId);
                JSONArray values = readSheetUsedRange(accessToken, siteId, driveId, itemId, sheetName);
                int inserted = stageSheetValues(conn, runId, plantId, sheetName, values);
                upsertSheetStatus(conn, runId, sheetName, "SUCCESS", inserted, null);
                logInfo("graph", "sheet read success sheet=" + sheetName + " inserted_rows=" + inserted + " run_id=" + runId + " plant_id=" + plantId);
                loadedSheets++;
            } catch (Exception sheetError) {
                upsertSheetStatus(conn, runId, sheetName, "FAILED", 0, truncate(sheetError.getMessage(), 3900));
                markIngestionFailed(conn, runId, plantId, "Sheet failed: " + sheetName + " -> " + sheetError.getMessage());
                throw sheetError;
            }
        }

        if (loadedSheets < MIN_EXPECTED_SHEETS) {
            markIngestionFailed(conn, runId, plantId, "Loaded sheets " + loadedSheets + " < expected " + MIN_EXPECTED_SHEETS);
            throw new IllegalStateException("Loaded sheets " + loadedSheets + " < expected " + MIN_EXPECTED_SHEETS);
        }

        upsertIngestionRun(conn, runId, plantId, "READY_FOR_SYNC", "Graph ingest completed. Sheets loaded=" + loadedSheets);
        logInfo("staging", "run READY_FOR_SYNC loaded_sheets=" + loadedSheets + " run_id=" + runId + " plant_id=" + plantId);
    }

    private String getRequiredEnv(String key) {
        String v = System.getenv(key);
        if (v == null || v.trim().isEmpty()) {
            throw new IllegalStateException("Missing required env var: " + key);
        }
        return v.trim();
    }

    private void upsertIngestionRun(Connection conn, UUID runId, long plantId, String status, String notes) throws SQLException {
        String sql =
                "INSERT INTO application_staging.inventory_ingestion_run "
                        + "(run_id, plant_id, overall_status, source_file_hint, notes) "
                        + "VALUES (?, ?, ?, ?, ?) "
                        + "ON CONFLICT (run_id) DO UPDATE SET "
                        + "overall_status = EXCLUDED.overall_status, "
                        + "source_file_hint = EXCLUDED.source_file_hint, "
                        + "notes = EXCLUDED.notes, "
                        + "updated_ts_utc = timezone('UTC', clock_timestamp())";
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setObject(1, runId);
            ps.setLong(2, plantId);
            ps.setString(3, status);
            ps.setString(4, "Graph:" + getRequiredEnv(ENV_GRAPH_ITEM_ID));
            ps.setString(5, notes);
            ps.executeUpdate();
        }
        logInfo("staging", "inventory_ingestion_run status=" + status + " run_id=" + runId + " plant_id=" + plantId);
    }

    private void markIngestionFailed(Connection conn, UUID runId, long plantId, String notes) throws SQLException {
        upsertIngestionRun(conn, runId, plantId, "FAILED", notes);
    }

    private void clearStagingForRun(Connection conn, UUID runId, long plantId) throws SQLException {
        try (PreparedStatement ps1 = conn.prepareStatement(
                "DELETE FROM application_staging.inventory_ingestion_run_sheet WHERE run_id = ?")) {
            ps1.setObject(1, runId);
            ps1.executeUpdate();
        }
        try (PreparedStatement ps2 = conn.prepareStatement(
                "DELETE FROM application_staging.db_corrispondenze_inventory WHERE run_id = ? AND plant_id = ?")) {
            ps2.setObject(1, runId);
            ps2.setLong(2, plantId);
            ps2.executeUpdate();
        }
        logInfo("staging", "cleared previous staging rows for run_id=" + runId + " plant_id=" + plantId);
    }

    private void upsertSheetStatus(Connection conn, UUID runId, String sheetName, String status, int rowCount, String lastError) throws SQLException {
        String sql =
                "INSERT INTO application_staging.inventory_ingestion_run_sheet "
                        + "(run_id, sheet_name, sheet_status, row_count, last_error) "
                        + "VALUES (?, ?, ?, ?, ?) "
                        + "ON CONFLICT (run_id, sheet_name) DO UPDATE SET "
                        + "sheet_status = EXCLUDED.sheet_status, "
                        + "row_count = EXCLUDED.row_count, "
                        + "last_error = EXCLUDED.last_error, "
                        + "updated_ts_utc = timezone('UTC', clock_timestamp())";
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setObject(1, runId);
            ps.setString(2, sheetName);
            ps.setString(3, status);
            ps.setInt(4, rowCount);
            if (lastError == null) {
                ps.setNull(5, Types.VARCHAR);
            } else {
                ps.setString(5, lastError);
            }
            ps.executeUpdate();
        }
        logInfo("staging", "sheet status sheet=" + sheetName + " status=" + status + " row_count=" + rowCount + " run_id=" + runId);
    }

    private String acquireGraphAccessToken(String tenantId, String clientId, String clientSecret) throws Exception {
        String url = "https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token";
        String body =
                "client_id=" + enc(clientId)
                        + "&client_secret=" + enc(clientSecret)
                        + "&scope=" + enc("https://graph.microsoft.com/.default")
                        + "&grant_type=client_credentials";
        JSONObject tokenResp = httpPostForm(url, body);
        String accessToken = tokenResp.optString("access_token", "");
        if (accessToken.isEmpty()) {
            throw new IllegalStateException("Graph token response missing access_token");
        }
        return accessToken;
    }

    private List<String> listWorksheetNames(String token, String siteId, String driveId, String itemId) throws Exception {
        String url =
                "https://graph.microsoft.com/v1.0/sites/" + siteId
                        + "/drives/" + driveId
                        + "/items/" + itemId
                        + "/workbook/worksheets?$select=name";
        JSONObject resp = httpGetJson(url, token);
        JSONArray value = resp.optJSONArray("value");
        List<String> names = new ArrayList<>();
        if (value == null) {
            return names;
        }
        for (int i = 0; i < value.length(); i++) {
            String name = value.getJSONObject(i).optString("name", "").trim();
            if (!name.isEmpty()) {
                names.add(name);
            }
        }
        return names;
    }

    private JSONArray readSheetUsedRange(String token, String siteId, String driveId, String itemId, String sheetName) throws Exception {
        String sheetPath = enc("'" + sheetName + "'");
        String url =
                "https://graph.microsoft.com/v1.0/sites/" + siteId
                        + "/drives/" + driveId
                        + "/items/" + itemId
                        + "/workbook/worksheets(" + sheetPath + ")/usedRange(valuesOnly=true)?$select=values";
        JSONObject resp = httpGetJson(url, token);
        JSONArray values = resp.optJSONArray("values");
        if (values == null) {
            return new JSONArray();
        }
        return values;
    }

    private int stageSheetValues(Connection conn, UUID runId, long plantId, String sheetName, JSONArray values) throws SQLException {
        if (values.length() < 2) {
            return 0;
        }
        JSONArray headerRow = values.getJSONArray(0);
        Map<String, Integer> headerMap = buildHeaderMap(headerRow);

        String sql =
                "INSERT INTO application_staging.db_corrispondenze_inventory "
                        + "(run_id, plant_id, sheet, distinta, descrizione, premontato, descrizione1, linea, ripetizioni, magazzino, valid_from_day_id, valid_to_day_id) "
                        + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        int inserted = 0;
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (int r = 1; r < values.length(); r++) {
                JSONArray row = values.optJSONArray(r);
                if (row == null) {
                    continue;
                }
                String distinta = getCellString(row, headerMap, "distinta");
                if (distinta == null || distinta.trim().isEmpty()) {
                    continue;
                }
                ps.setObject(1, runId);
                ps.setLong(2, plantId);
                ps.setString(3, sheetName);
                ps.setString(4, truncate(distinta.trim(), 500));
                ps.setString(5, truncate(getCellString(row, headerMap, "descrizione"), 10000));
                ps.setString(6, truncate(getCellString(row, headerMap, "premontato"), 500));
                ps.setString(7, truncate(getCellString(row, headerMap, "descrizione1"), 10000));
                ps.setString(8, truncate(getCellString(row, headerMap, "linea"), 500));
                ps.setString(9, truncate(getCellString(row, headerMap, "ripetizioni"), 100));
                ps.setString(10, truncate(getCellString(row, headerMap, "magazzino"), 255));

                BigDecimal fromDay = parseDayId(getCellString(row, headerMap, "valid_from_day_id"));
                BigDecimal toDay = parseDayId(getCellString(row, headerMap, "valid_to_day_id"));
                if (fromDay == null) {
                    ps.setNull(11, Types.NUMERIC);
                } else {
                    ps.setBigDecimal(11, fromDay);
                }
                if (toDay == null) {
                    ps.setNull(12, Types.NUMERIC);
                } else {
                    ps.setBigDecimal(12, toDay);
                }
                ps.addBatch();
                inserted++;
            }
            ps.executeBatch();
        }
        return inserted;
    }

    private Map<String, Integer> buildHeaderMap(JSONArray headerRow) {
        Map<String, Integer> idx = new HashMap<>();
        for (int i = 0; i < headerRow.length(); i++) {
            String raw = String.valueOf(headerRow.opt(i));
            idx.put(normalizeHeader(raw), i);
        }
        return idx;
    }

    private String getCellString(JSONArray row, Map<String, Integer> headerMap, String logicalColumn) {
        List<String> aliases = headerAliases(logicalColumn);
        for (String a : aliases) {
            Integer pos = headerMap.get(normalizeHeader(a));
            if (pos != null && pos >= 0 && pos < row.length()) {
                Object val = row.opt(pos);
                if (val == null || JSONObject.NULL.equals(val)) {
                    return null;
                }
                return String.valueOf(val).trim();
            }
        }
        return null;
    }

    private List<String> headerAliases(String logicalColumn) {
        switch (logicalColumn) {
            case "distinta":
                return Arrays.asList("distinta", "distinte", "cpf", "matnr");
            case "descrizione":
                return Arrays.asList("descrizione", "descrizione distinta", "description");
            case "premontato":
                return Arrays.asList("premontato", "pre_montato", "premontati");
            case "descrizione1":
                return Arrays.asList("descrizione1", "descrizione 1", "descrizione premontato");
            case "linea":
                return Arrays.asList("linea", "zzlinea", "line");
            case "ripetizioni":
                return Arrays.asList("ripetizioni", "repeat", "repetition");
            case "magazzino":
                return Arrays.asList("magazzino", "lgort", "warehouse");
            case "valid_from_day_id":
                return Arrays.asList("valid_from_day_id", "valid_from", "valid from", "data inizio", "day_from");
            case "valid_to_day_id":
                return Arrays.asList("valid_to_day_id", "valid_to", "valid to", "data fine", "day_to");
            default:
                return Arrays.asList(logicalColumn);
        }
    }

    private String normalizeHeader(String raw) {
        return raw == null
                ? ""
                : raw.toLowerCase(Locale.ROOT)
                .replace(" ", "")
                .replace("_", "")
                .replace("-", "")
                .replace(".", "")
                .trim();
    }

    private BigDecimal parseDayId(String value) {
        if (value == null || value.trim().isEmpty()) {
            return null;
        }
        String onlyDigits = value.replaceAll("[^0-9]", "");
        if (onlyDigits.length() == 8) {
            return new BigDecimal(onlyDigits);
        }
        return null;
    }

    private JSONObject httpPostForm(String endpoint, String formBody) throws Exception {
        HttpURLConnection con = (HttpURLConnection) new URL(endpoint).openConnection();
        con.setRequestMethod("POST");
        con.setDoOutput(true);
        con.setConnectTimeout(30000);
        con.setReadTimeout(30000);
        con.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");

        byte[] payload = formBody.getBytes(StandardCharsets.UTF_8);
        try (OutputStream os = con.getOutputStream()) {
            os.write(payload);
        }
        String body = readResponseBody(con);
        int code = con.getResponseCode();
        if (code < 200 || code >= 300) {
            throw new IllegalStateException("HTTP " + code + " from token endpoint: " + body);
        }
        return new JSONObject(body);
    }

    private JSONObject httpGetJson(String endpoint, String bearerToken) throws Exception {
        HttpURLConnection con = (HttpURLConnection) new URL(endpoint).openConnection();
        con.setRequestMethod("GET");
        con.setConnectTimeout(30000);
        con.setReadTimeout(30000);
        con.setRequestProperty("Authorization", "Bearer " + bearerToken);
        con.setRequestProperty("Accept", "application/json");

        String body = readResponseBody(con);
        int code = con.getResponseCode();
        if (code < 200 || code >= 300) {
            throw new IllegalStateException("HTTP " + code + " from Graph endpoint: " + body);
        }
        return new JSONObject(body);
    }

    private String readResponseBody(HttpURLConnection con) throws IOException {
        InputStream stream = con.getResponseCode() >= 400 ? con.getErrorStream() : con.getInputStream();
        if (stream == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        try (BufferedReader br = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line);
            }
        }
        return sb.toString();
    }

    private String enc(String raw) throws Exception {
        return URLEncoder.encode(raw, StandardCharsets.UTF_8.name());
    }

    private String truncate(String value, int maxLen) {
        if (value == null) {
            return null;
        }
        return value.length() <= maxLen ? value : value.substring(0, maxLen);
    }

    private void pollMonitoringAndRequireSuccess(Connection conn, String procedureName, long plantId) throws SQLException {
        String sql =
                "SELECT id, state, error_msg FROM application_staging.etl_monitoring "
                        + "WHERE procedure_name = ? AND plant_id = ? ORDER BY id DESC LIMIT 1";
        long start = System.currentTimeMillis();
        long maxWait = 10 * 60 * 1000L;
        long interval = 30_000L;

        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, procedureName);
            ps.setLong(2, plantId);
            while (true) {
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        String state = rs.getString("state");
                        if (state != null && !"running".equalsIgnoreCase(state)) {
                            ExtLoggerSDK.info(
                                    LOG_PREFIX + " [monitoring] etl_monitoring " + procedureName + " -> id="
                                            + rs.getLong("id") + ", state=" + state
                            );
                            if (!"success".equalsIgnoreCase(state)) {
                                throw new SQLException(
                                        "etl_monitoring state is not success for " + procedureName
                                                + " (plant=" + plantId + "): state=" + state
                                                + ", error=" + rs.getString("error_msg")
                                );
                            }
                            return;
                        }
                    }
                }
                if (System.currentTimeMillis() - start > maxWait) {
                    throw new SQLException("etl_monitoring poll timeout for " + procedureName + " plant=" + plantId);
                }
                try {
                    Thread.sleep(interval);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }

    private void logInfo(String stage, String message) {
        ExtLoggerSDK.info(LOG_PREFIX + " [" + stage + "] " + message);
    }
}
