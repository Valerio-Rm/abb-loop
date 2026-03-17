-- ==============================================================
-- Verifica se l'utente corrente può usare dblink
-- Eseguire come utente dell'app (es. abb_prj_user)
-- ==============================================================

\echo '--- 1. Estensione dblink installata? ---'
SELECT extname, extversion
  FROM pg_extension
 WHERE extname = 'dblink';

\echo ''
\echo '--- 2. Permessi sullo schema pubblico (dove risiedono le funzioni dblink) ---'
SELECT nspname, has_schema_privilege(current_user, nspname, 'USAGE') AS usage_ok
  FROM pg_namespace
 WHERE nspname = 'public';

\echo ''
\echo '--- 3. Utente corrente e database ---'
SELECT current_user AS usr, current_database() AS db;

\echo ''
\echo '--- 4. Test connessione dblink (stesso DB, stesso user, senza password) ---'
DO $$
DECLARE
  cname TEXT := 'check_dblink_test_' || pg_backend_pid();
  conn   TEXT;
  res    TEXT;
BEGIN
  conn := 'dbname=' || current_database() || ' user=' || current_user;
  PERFORM dblink_connect(cname, conn);
  SELECT * INTO res FROM dblink(cname, 'SELECT ''OK''') AS t(x text);
  PERFORM dblink_disconnect(cname);
  RAISE NOTICE 'dblink test: %', res;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    PERFORM dblink_disconnect(cname);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RAISE NOTICE 'dblink test FALLITO: %', SQLERRM;
END;
$$;

\echo ''
\echo '--- Fine verifica ---'
