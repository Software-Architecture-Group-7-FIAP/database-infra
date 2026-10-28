\set ON_ERROR_STOP on

SELECT
  :'dbname' ~ '^autoshop_(hml|prd)$'
  AND :'app_role' = 'app_runtime_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND :'migration_role' = 'autoshop_migrations_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND current_user = :'migration_role' AS inputs_valid
\gset

\if :inputs_valid
\else
\echo ERROR: migration default privilege role and database names do not match the approved contract
DO $migration_defaults_input_contract$
BEGIN
  RAISE EXCEPTION 'migration default privilege role and database names do not match the approved contract';
END
$migration_defaults_input_contract$;
\endif

\connect :dbname

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_role";
