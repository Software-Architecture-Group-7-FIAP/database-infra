#!/usr/bin/env bash
set -euo pipefail
umask 077
export HOME=/work/home
export TMPDIR=/work/tmp
export PSQL_HISTORY=/dev/null
export PGHOST="$DB_HOST"
export PGPORT="$DB_PORT"
export PGSSLMODE=verify-full
export PGSSLROOTCERT=/work/rds-ca-bundle.pem
export PGPASSFILE=/work/pgpass
export PGCONNECT_TIMEOUT=10

fail() {
  printf 'database TLS or permission operation failed; private diagnostics were discarded\n' >&2
  exit 1
}

run_psql_file() {
  local environment="$1" role="$2" sql_file="$3"
  if ! PGUSER="$role" psql -X -w -v ON_ERROR_STOP=1 -d postgres \
    -f "$sql_file" >"/work/psql-$environment.stdout" 2>"/work/psql-$environment.stderr"; then
    fail
  fi
}

check_true() {
  local database="$1" role="$2" label="$3" query="$4"
  local output="/work/smoke-$label.stdout"
  if ! PGUSER="$role" PGDATABASE="$database" psql -X -w -qAt -v ON_ERROR_STOP=1 \
    -c "$query" >"$output" 2>"/work/smoke-$label.stderr"; then
    fail
  fi
  [[ "$(<"$output")" == "t" ]] || fail
}

expect_permission_denied() {
  local database="$1" role="$2" label="$3" query="$4"
  local output="/work/smoke-$label.stdout"
  local error="/work/smoke-$label.stderr"
  if PGUSER="$role" PGDATABASE="$database" psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate \
    -c "$query" >"$output" 2>"$error"; then
    fail
  fi
  if ! grep -Fq '42501' "$error"; then
    fail
  fi
}

if [[ "$ENVIRONMENT" != hml && "$ENVIRONMENT" != prd ]] || [[ "$DB_NAME" != "autoshop_$ENVIRONMENT" ]]; then
  fail
fi

other_environment=prd
[[ "$ENVIRONMENT" != hml ]] || other_environment=hml

if [[ "$PHASE" == "bootstrap" ]]; then
  run_psql_file "$ENVIRONMENT" autoshop_owner "/work/bootstrap-$ENVIRONMENT.sql"
  run_psql_file "$ENVIRONMENT" "autoshop_migrations_$ENVIRONMENT" "/work/migration-defaults-$ENVIRONMENT.sql"
elif [[ "$PHASE" == "grants" ]]; then
  run_psql_file "$ENVIRONMENT" "autoshop_migrations_$ENVIRONMENT" "/work/grants-$ENVIRONMENT.sql"
elif [[ "$PHASE" == "smoke" ]]; then
  app_role="app_runtime_$ENVIRONMENT"
  lambda_role="lambda_auth_$ENVIRONMENT"
  migration_role="autoshop_migrations_$ENVIRONMENT"
  other_database="autoshop_$other_environment"
  check_true "$DB_NAME" "$app_role" runtime-"$ENVIRONMENT" \
    "SELECT current_user = '$app_role' AND has_database_privilege(current_user, current_database(), 'CONNECT') AND has_table_privilege(current_user, 'public.customers', 'SELECT') AND has_table_privilege(current_user, 'public.customers', 'INSERT') AND has_table_privilege(current_user, 'public.customers', 'UPDATE') AND has_table_privilege(current_user, 'public.customers', 'DELETE') AND NOT has_schema_privilege(current_user, 'public', 'CREATE') AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"
  check_true "$DB_NAME" "$migration_role" migrations-"$ENVIRONMENT" \
    "SELECT current_user = '$migration_role' AND has_database_privilege(current_user, current_database(), 'CONNECT') AND has_schema_privilege(current_user, 'public', 'CREATE') AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit)) AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"
  check_true "$DB_NAME" "$lambda_role" lambda-"$ENVIRONMENT" \
    "SELECT current_user = '$lambda_role' AND has_column_privilege(current_user, 'public.customers', 'id', 'SELECT') AND has_column_privilege(current_user, 'public.customers', 'status', 'SELECT') AND has_column_privilege(current_user, 'public.customer_documents', 'customer_id', 'SELECT') AND has_column_privilege(current_user, 'public.customer_documents', 'document', 'SELECT') AND NOT has_column_privilege(current_user, 'public.customers', 'email', 'SELECT') AND NOT has_table_privilege(current_user, 'public.customers', 'INSERT') AND NOT has_schema_privilege(current_user, 'public', 'CREATE') AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"

  if ! PGUSER="$lambda_role" PGDATABASE="$DB_NAME" psql -X -w -qAt -v ON_ERROR_STOP=1 \
    -c 'SELECT id, status FROM public.customers LIMIT 0; SELECT customer_id, document FROM public.customer_documents LIMIT 0;' \
    >"/work/smoke-$ENVIRONMENT-lambda-allowed.stdout" 2>"/work/smoke-$ENVIRONMENT-lambda-allowed.stderr"; then
    fail
  fi
  expect_permission_denied "$DB_NAME" "$lambda_role" "$ENVIRONMENT-lambda-email" \
    'SELECT email FROM public.customers LIMIT 0'
  expect_permission_denied "$DB_NAME" "$lambda_role" "$ENVIRONMENT-lambda-insert" \
    'INSERT INTO public.customers DEFAULT VALUES'
  expect_permission_denied "$other_database" "$app_role" "$ENVIRONMENT-cross-database" \
    "SELECT current_user"
  expect_permission_denied "$other_database" "$migration_role" "$ENVIRONMENT-migrations-cross-database" \
    "SELECT current_user"
else
  fail
fi

printf 'PASS: database TLS and least-privilege smoke completed\n'
