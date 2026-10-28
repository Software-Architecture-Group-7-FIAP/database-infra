\set ON_ERROR_STOP on

SELECT
  :'dbname' ~ '^autoshop_(hml|prd)$'
  AND :'owner_role' = 'autoshop_owner'
  AND :'app_role' = 'app_runtime_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND :'lambda_role' = 'lambda_auth_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND :'migration_role' = 'autoshop_migrations_' || substring(:'dbname' from '^autoshop_(.*)$')
  AND :'app_password_hash' ~ '^SCRAM-SHA-256[$]4096:[A-Za-z0-9+/]{22}==[$][A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$'
  AND :'lambda_password_hash' ~ '^SCRAM-SHA-256[$]4096:[A-Za-z0-9+/]{22}==[$][A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$'
  AND :'migration_password_hash' ~ '^SCRAM-SHA-256[$]4096:[A-Za-z0-9+/]{22}==[$][A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$' AS inputs_valid
\gset

\if :inputs_valid
\else
\echo ERROR: bootstrap role and database names do not match the approved contract
DO $bootstrap_input_contract$
BEGIN
  RAISE EXCEPTION 'bootstrap role and database names do not match the approved contract';
END
$bootstrap_input_contract$;
\endif

SELECT format('CREATE DATABASE %I OWNER %I', :'dbname', :'owner_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname')
\gexec

-- Only SCRAM-SHA-256 verifiers enter SQL. Cleartext passwords remain in the
-- private runtime work volume and are not exposed in SQL statements or logs.
-- The current Secrets Manager versions are the credential source of truth.
-- Reapply their verifiers on every bootstrap retry to recover partial publication.
SELECT format(
  'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L',
  :'app_role',
  :'app_password_hash'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_role')
\gexec

SELECT format(
  'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L',
  :'lambda_role',
  :'lambda_password_hash'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'lambda_role')
\gexec

SELECT format(
  'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L',
  :'migration_role',
  :'migration_password_hash'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'migration_role')
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L', :'app_role', :'app_password_hash')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L', :'lambda_role', :'lambda_password_hash')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L', :'migration_role', :'migration_password_hash')
\gexec

SELECT format('REVOKE %I FROM %I', granted_role.rolname, member_role.rolname)
FROM pg_auth_members AS membership
JOIN pg_roles AS granted_role ON granted_role.oid = membership.roleid
JOIN pg_roles AS member_role ON member_role.oid = membership.member
WHERE member_role.rolname IN (:'app_role', :'lambda_role', :'migration_role')
\gexec

\connect :dbname

REVOKE ALL PRIVILEGES ON DATABASE :"dbname" FROM PUBLIC;
REVOKE TEMPORARY ON DATABASE :"dbname" FROM PUBLIC;
REVOKE TEMPORARY ON DATABASE :"dbname" FROM :"app_role", :"lambda_role", :"migration_role";
GRANT CONNECT ON DATABASE :"dbname" TO :"app_role", :"lambda_role", :"migration_role";

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM :"app_role", :"lambda_role", :"migration_role";
GRANT USAGE ON SCHEMA public TO :"app_role", :"lambda_role";
GRANT USAGE, CREATE ON SCHEMA public TO :"migration_role";

-- Alembic objects belong to the dedicated migration role. That role sets its
-- own defaults during bootstrap and reconciles grants after migrations run.
