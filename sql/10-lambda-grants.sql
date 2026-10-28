\set ON_ERROR_STOP on

SELECT
  :'dbname' ~ '^autoshop_(hml|prd)$'
  AND :'app_role' = 'app_runtime_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND :'lambda_role' = 'lambda_auth_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND :'migration_role' = 'autoshop_migrations_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND current_user = :'migration_role' AS inputs_valid
\gset

\if :inputs_valid
\else
\echo ERROR: grant role and database names do not match the approved contract
DO $grants_input_contract$
BEGIN
  RAISE EXCEPTION 'grant role and database names do not match the approved contract';
END
$grants_input_contract$;
\endif

\connect :dbname

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM :"app_role";
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM :"app_role";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_role";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_role";

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM :"lambda_role";
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM :"lambda_role";

SELECT format(
  'REVOKE %s (%I) ON TABLE %I.%I FROM %I',
  privilege_type,
  column_name,
  table_schema,
  table_name,
  grantee
)
FROM information_schema.column_privileges
WHERE table_schema = 'public'
  AND grantee = :'lambda_role'
  AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
\gexec

GRANT SELECT (id, status) ON TABLE public.customers TO :"lambda_role";
GRANT SELECT (customer_id, document) ON TABLE public.customer_documents TO :"lambda_role";

SELECT set_config('autoshop.lambda_role', :'lambda_role', false) AS lambda_role_setting
\gset
SELECT set_config('autoshop.app_role', :'app_role', false) AS app_role_setting
\gset

DO $verify_database_privileges$
BEGIN
  IF has_table_privilege(current_setting('autoshop.lambda_role'), 'public.customers', 'INSERT')
    OR has_table_privilege(current_setting('autoshop.lambda_role'), 'public.customers', 'UPDATE')
    OR has_table_privilege(current_setting('autoshop.lambda_role'), 'public.customer_documents', 'INSERT')
    OR has_table_privilege(current_setting('autoshop.lambda_role'), 'public.customer_documents', 'UPDATE')
    OR has_column_privilege(current_setting('autoshop.lambda_role'), 'public.customers', 'email', 'SELECT')
    OR has_column_privilege(current_setting('autoshop.lambda_role'), 'public.customers', 'email', 'UPDATE')
    OR has_column_privilege(current_setting('autoshop.lambda_role'), 'public.customer_documents', 'created_at', 'SELECT')
    OR has_column_privilege(current_setting('autoshop.lambda_role'), 'public.customer_documents', 'id', 'SELECT')
    OR has_schema_privilege(current_setting('autoshop.app_role'), 'public', 'CREATE')
    OR EXISTS (
      SELECT 1
      FROM pg_auth_members AS membership
      JOIN pg_roles AS member_role ON member_role.oid = membership.member
      WHERE member_role.rolname IN (current_setting('autoshop.lambda_role'), current_setting('autoshop.app_role'))
    ) THEN
    RAISE EXCEPTION 'database role privilege invariant failed';
  END IF;
END
$verify_database_privileges$;
