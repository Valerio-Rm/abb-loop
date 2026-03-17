package snippet;

import it.decisyon.ext.program.*;
import it.decisyon.ext.program.context.IExtProgramExecutionContext;
import it.decisyon.ext.sdk.impl.logger.ExtLoggerSDK;
import it.decisyon.ext.sdk.impl.restapi.ExtRestApiExecutionResult;
import static it.decisyon.ext.sdk.impl.restapi.ExtRestApiDefinerSDK.givenRestApi;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.CallableStatement;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import org.json.JSONObject;
import org.json.JSONArray;

public class Snippet implements ExtIDecisyonProgram {

    private ExtRestApiExecutionResult allTenantsResponse = new ExtRestApiExecutionResult();
    private ExtRestApiExecutionResult tenantDbResponse = new ExtRestApiExecutionResult();

    public void execute(IExtProgramExecutionContext context) throws Exception {
        ExtLoggerSDK.info("Starting Mass Tenant Update - Procedure: etl_run_all_lookups");
        
        // JSON for the final report
        JSONObject finalReport = new JSONObject();
        JSONArray details = new JSONArray();
        int successCount = 0;
        int errorCount = 0;

        try {
            // 1. Retrieve the list of all tenants
            givenRestApi().withAlias("GetAllTenant")
                .then().execute().and().saveResponseTo(allTenantsResponse);

            if (!allTenantsResponse.getStatus().equals("200")) {
                throw new Exception("Unable to retrieve tenant list. Status: " + allTenantsResponse.getStatus());
            }

            JSONObject allTenantsJson = new JSONObject(allTenantsResponse.getBody());
            JSONArray tenantsArray = allTenantsJson.getJSONObject("_embedded").getJSONArray("tenants");

            // 2. Loop through each tenant
            for (int i = 0; i < tenantsArray.length(); i++) {
                // Use optString to safely handle missing or null values
                String tenantName = tenantsArray.getJSONObject(i).optString("name", "");
                
                // Protection: if name is empty, skip and log it in the report
                if (tenantName.trim().isEmpty()) {
                    ExtLoggerSDK.warn("Tenant skipped: tenant name at index " + i + " is empty or missing.");
                    JSONObject skipStatus = new JSONObject();
                    skipStatus.put("index", i);
                    skipStatus.put("status", "SKIPPED");
                    skipStatus.put("message", "Empty tenant name in master database");
                    details.put(skipStatus);
                    errorCount++;
                    continue;
                }

                JSONObject tenantStatus = new JSONObject();
                tenantStatus.put("tenant", tenantName);

                try {
                    // 3. Call for current tenant connections (tenantName is a String)
                    ExtLoggerSDK.debug("Requesting connections for tenant: " + tenantName);
                    
                    givenRestApi().withAlias("GetTenantConnections")
                        .withParam("tenant_name").mappedToValue(tenantName)
                        .then().execute().and().saveResponseTo(tenantDbResponse);

                    if (tenantDbResponse.getStatus().equals("200")) {
                        // 4. Execute procedure on the specific DB
                        processTenantDatabase(tenantDbResponse.getBody(), tenantName);
                        
                        tenantStatus.put("status", "SUCCESS");
                        tenantStatus.put("message", "Procedure etl_run_all_lookups executed successfully");
                        successCount++;
                    } else {
                        tenantStatus.put("status", "ERROR");
                        tenantStatus.put("message", "Connections API failed for " + tenantName + " with status: " + tenantDbResponse.getStatus());
                        errorCount++;
                    }
                } catch (Exception e) {
                    ExtLoggerSDK.error("Error processing tenant " + tenantName + ": " + e.getMessage());
                    tenantStatus.put("status", "ERROR");
                    tenantStatus.put("message", e.getMessage());
                    errorCount++;
                }
                details.put(tenantStatus);
            }

            finalReport.put("total_processed", tenantsArray.length());
            finalReport.put("success_count", successCount);
            finalReport.put("error_count", errorCount);
            finalReport.put("details", details);

            context.setResultAttribute("PROGRAM_RESULT", finalReport.toString());
            context.setAttribute("?snippet_output?", "Process completed. Success: " + successCount + " Errors: " + errorCount);

        } catch (Exception e) {
            ExtLoggerSDK.error("Critical error in snippet: " + e.getMessage());
            finalReport.put("critical_error", e.getMessage());
            context.setResultAttribute("PROGRAM_RESULT", finalReport.toString());
            throw e;
        }
    }

    private void processTenantDatabase(String connectionJsonBody, String tenantName) throws Exception {
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
            throw new Exception("Alias APPLICATION_DATA not found for tenant " + tenantName);
        }

        // Build dynamic JDBC URL
        String url = "jdbc:postgresql://" + params.getString("host") + ":" + params.getString("port") + 
                     "/" + params.getString("database") + "?currentSchema=" + params.getString("schema");
        String user = params.getString("username");
        String pass = params.getString("password");

        Connection conn = null;
        CallableStatement cs = null;
        PreparedStatement ps = null;
        ResultSet rs = null;
        try {
            Class.forName("org.postgresql.Driver");
            conn = DriverManager.getConnection(url, user, pass);
            
            // Call procedure application_staging.etl_run_all_lookups
            String sql = "CALL application_staging.etl_run_all_lookups(?, ?, ?, ?, ?, ?, ?, ?, ?)";
            cs = conn.prepareCall(sql);
            
            // Parameters: 'ETL_DAILY', false, true, null, null, null, null, 'PROD', true
            cs.setString(1, "ETL_DAILY");                    // p_caller (VARCHAR)
            cs.setBoolean(2, false);                         // p_dry_run (BOOLEAN)
            cs.setBoolean(3, true);                          // p_run_ft_rawdata (BOOLEAN)
            cs.setNull(4, java.sql.Types.DATE);              // p_ft_rawdata_date_min (DATE)
            cs.setNull(5, java.sql.Types.DATE);              // p_ft_rawdata_date_max (DATE)
            cs.setNull(6, java.sql.Types.VARCHAR);           // p_foreign_schema (TEXT)
            cs.setNull(7, java.sql.Types.ARRAY);             // p_foreign_schemas (TEXT[])
            cs.setString(8, "PROD");                         // p_schema_group (TEXT)
            cs.setBoolean(9, true);                          // p_continue_on_error (BOOLEAN)

            cs.execute();
            
            // Read latest etl_monitoring row for this procedure and wait until state != 'running'
            String monitoringSql =
                "SELECT id, state, error_msg " +
                "FROM application_staging.etl_monitoring " +
                "WHERE procedure_name = ? " +
                "ORDER BY id DESC " +
                "LIMIT 1";

            ps = conn.prepareStatement(monitoringSql);
            ps.setString(1, "application_staging.etl_run_all_lookups");

            long startWait = System.currentTimeMillis();
            long maxWaitMs = 10 * 60 * 1000L;   // max 10 minutes
            long pollIntervalMs = 30_000L;      // 30 seconds between checks

            Long monitoringId = null;
            String state = null;
            String errorMsg = null;

            while (true) {
                if (rs != null) {
                    rs.close();
                    rs = null;
                }

                rs = ps.executeQuery();
                if (rs.next()) {
                    monitoringId = rs.getLong("id");
                    state = rs.getString("state");
                    errorMsg = rs.getString("error_msg");

                    if (state != null && !"running".equalsIgnoreCase(state)) {
                        break;
                    }
                }

                if (System.currentTimeMillis() - startWait > maxWaitMs) {
                    ExtLoggerSDK.warn(
                        "ETL_MONITORING TIMEOUT: state still 'running' beyond wait limit (" +
                        (maxWaitMs / 1000) + "s) for procedure_name='application_staging.etl_run_all_lookups'" +
                        (monitoringId != null ? ", last_row_id=" + monitoringId + ", last_state=" + state : "") +
                        ". Snippet will continue without failing; please manually check table application_staging.etl_monitoring."
                    );
                    break;
                }

                try {
                    Thread.sleep(pollIntervalMs);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    ExtLoggerSDK.warn("Interrupted while waiting for etl_monitoring state update - proceeding without failing snippet");
                    break;
                }
            }

            ExtLoggerSDK.info(
                "etl_run_all_lookups monitoring row for tenant " + tenantName +
                " -> id=" + monitoringId + ", state=" + state
            );

            // Qualunque stato diverso da 'running' (success, failed, skipped, ...) viene solo loggato,
            // senza generare eccezione lato snippet.

            ExtLoggerSDK.info("Procedure etl_run_all_lookups successfully completed for tenant: " + tenantName);
        } finally {
            if (rs != null) rs.close();
            if (ps != null) ps.close();
            if (cs != null) cs.close();
            if (conn != null) conn.close();
        }
    }
}
