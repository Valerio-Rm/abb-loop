--metadata_schema

-- Required variables (pass via: psql ... -v tenant_user=...)
\if :{?tenant_user}
\else
  \echo 'ERROR: missing required psql variable tenant_user (use: -v tenant_user=...)'
  \quit 2
\endif

CREATE SCHEMA IF NOT EXISTS appcomposer_auth AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_collab AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_dumbella AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_md AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_repo AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_timeturner AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_temp AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_howler AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS appcomposer_tracer AUTHORIZATION :"tenant_user";

--data schema

CREATE SCHEMA IF NOT EXISTS application_data AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS application_audit AUTHORIZATION :"tenant_user";

CREATE SCHEMA IF NOT EXISTS application_staging AUTHORIZATION :"tenant_user";

