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

if [[ "$PHASE" == "bootstrap" ]]; then
  run_psql_file hml autoshop_owner /work/bootstrap-hml.sql
  run_psql_file prd autoshop_owner /work/bootstrap-prd.sql
elif [[ "$PHASE" == "grants" ]]; then
  run_psql_file hml autoshop_owner /work/grants-hml.sql
  run_psql_file prd autoshop_owner /work/grants-prd.sql
elif [[ "$PHASE" == "smoke" ]]; then
  check_true "$DB_NAME_HML" app_runtime_hml runtime-hml \
    "SELECT current_user = 'app_runtime_hml' AND has_database_privilege(current_user, current_database(), 'CONNECT') AND has_table_privilege(current_user, 'public.customers', 'SELECT') AND has_table_privilege(current_user, 'public.customers', 'INSERT') AND has_table_privilege(current_user, 'public.customers', 'UPDATE') AND has_table_privilege(current_user, 'public.customers', 'DELETE') AND NOT has_schema_privilege(current_user, 'public', 'CREATE') AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"
  check_true "$DB_NAME_PRD" app_runtime_prd runtime-prd \
    "SELECT current_user = 'app_runtime_prd' AND has_database_privilege(current_user, current_database(), 'CONNECT') AND has_table_privilege(current_user, 'public.customers', 'SELECT') AND has_table_privilege(current_user, 'public.customers', 'INSERT') AND has_table_privilege(current_user, 'public.customers', 'UPDATE') AND has_table_privilege(current_user, 'public.customers', 'DELETE') AND NOT has_schema_privilege(current_user, 'public', 'CREATE') AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"
  check_true "$DB_NAME_HML" lambda_auth_hml lambda-hml \
    "SELECT current_user = 'lambda_auth_hml' AND has_column_privilege(current_user, 'public.customers', 'id', 'SELECT') AND has_column_privilege(current_user, 'public.customers', 'status', 'SELECT') AND has_column_privilege(current_user, 'public.customer_documents', 'customer_id', 'SELECT') AND has_column_privilege(current_user, 'public.customer_documents', 'document', 'SELECT') AND NOT has_column_privilege(current_user, 'public.customers', 'email', 'SELECT') AND NOT has_table_privilege(current_user, 'public.customers', 'INSERT') AND NOT has_schema_privilege(current_user, 'public', 'CREATE') AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"
  check_true "$DB_NAME_PRD" lambda_auth_prd lambda-prd \
    "SELECT current_user = 'lambda_auth_prd' AND has_column_privilege(current_user, 'public.customers', 'id', 'SELECT') AND has_column_privilege(current_user, 'public.customers', 'status', 'SELECT') AND has_column_privilege(current_user, 'public.customer_documents', 'customer_id', 'SELECT') AND has_column_privilege(current_user, 'public.customer_documents', 'document', 'SELECT') AND NOT has_column_privilege(current_user, 'public.customers', 'email', 'SELECT') AND NOT has_table_privilege(current_user, 'public.customers', 'INSERT') AND NOT has_schema_privilege(current_user, 'public', 'CREATE') AND COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"

  for environment in hml prd; do
    if [[ "$environment" == hml ]]; then
      database="$DB_NAME_HML"
      other_database="$DB_NAME_PRD"
      app_role=app_runtime_hml
      lambda_role=lambda_auth_hml
      suffix=hml
    else
      database="$DB_NAME_PRD"
      other_database="$DB_NAME_HML"
      app_role=app_runtime_prd
      lambda_role=lambda_auth_prd
      suffix=prd
    fi
    if ! PGUSER="$lambda_role" PGDATABASE="$database" psql -X -w -qAt -v ON_ERROR_STOP=1 \
      -c 'SELECT id, status FROM public.customers LIMIT 0; SELECT customer_id, document FROM public.customer_documents LIMIT 0;' \
      >"/work/smoke-$suffix-lambda-allowed.stdout" 2>"/work/smoke-$suffix-lambda-allowed.stderr"; then
      fail
    fi
    expect_permission_denied "$database" "$lambda_role" "$suffix-lambda-email" \
      'SELECT email FROM public.customers LIMIT 0'
    expect_permission_denied "$database" "$lambda_role" "$suffix-lambda-insert" \
      'INSERT INTO public.customers DEFAULT VALUES'
    expect_permission_denied "$other_database" "$app_role" "$suffix-cross-database" \
      "SELECT current_user"
  done
else
  fail
fi

printf 'PASS: database TLS and least-privilege smoke completed\n'
