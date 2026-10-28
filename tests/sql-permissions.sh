#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077
if [[ -d /dev/shm && -w /dev/shm ]]; then
  tmp_dir="$(mktemp -d /dev/shm/database-infra-sql-test.XXXXXX)"
else
  tmp_dir="$(mktemp -d)"
fi
container_name="database-infra-sql-test-$$"
use_service=false
postgres_user="${POSTGRES_USER:-postgres}"
postgres_password="${POSTGRES_PASSWORD:-local-test-only}"
postgres_port="${PGPORT:-5432}"
container_started=false

if [[ -n "${PGHOST:-}" ]]; then
  use_service=true
else
  export DOCKER_CONFIG="$tmp_dir/docker-config"
  mkdir -p "$DOCKER_CONFIG"
fi

cleanup() {
  if [[ "$container_started" == true ]]; then
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

if [[ "$use_service" == true ]]; then
  command -v psql >/dev/null 2>&1 || { printf 'FAIL: psql is required when PGHOST is set\n' >&2; exit 1; }
  command -v pg_isready >/dev/null 2>&1 || { printf 'FAIL: pg_isready is required when PGHOST is set\n' >&2; exit 1; }
else
  command -v docker >/dev/null 2>&1 || { printf 'SKIP: docker is unavailable\n'; exit 0; }
  docker info >/dev/null 2>&1 || { printf 'SKIP: Docker daemon is unavailable\n'; exit 0; }
  docker run --detach --rm --name "$container_name" --env POSTGRES_PASSWORD="$postgres_password" postgres:16-alpine >/dev/null
  container_started=true
fi

ready=false
for _ in $(seq 1 60); do
  if [[ "$use_service" == true ]]; then
    if pg_isready -h "$PGHOST" -p "$postgres_port" -U "$postgres_user" >/dev/null 2>&1; then
      ready=true
      break
    fi
  elif docker exec "$container_name" pg_isready -U "$postgres_user" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { printf 'FAIL: local PostgreSQL did not become ready\n' >&2; exit 1; }

admin_psql() {
  if [[ "$use_service" == true ]]; then
    PGPASSWORD="$postgres_password" psql -X -q -v ON_ERROR_STOP=1 \
      -h "$PGHOST" -p "$postgres_port" -U "$postgres_user" "$@"
  else
    docker exec -i "$container_name" psql -X -q -v ON_ERROR_STOP=1 -U "$postgres_user" "$@"
  fi
}

role_psql() {
  local role="$1"
  local password="$2"
  local database="$3"
  local query="$4"

  if [[ "$use_service" == true ]]; then
    PGPASSWORD="$password" psql -X -q -tA -v ON_ERROR_STOP=1 \
      -h "$PGHOST" -p "$postgres_port" -U "$role" -d "$database" -c "$query"
  else
    docker exec --env PGPASSWORD="$password" "$container_name" \
      psql -X -q -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$role" -d "$database" -c "$query"
  fi
}

role_file_psql() {
  local role="$1"
  local password="$2"
  local input_file="$3"

  if [[ "$use_service" == true ]]; then
    PGPASSWORD="$password" psql -X -q -v ON_ERROR_STOP=1 \
      -h "$PGHOST" -p "$postgres_port" -U "$role" -d postgres -f "$input_file"
  else
    docker exec --env PGPASSWORD="$password" -i "$container_name" \
      psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$role" -d postgres -f /dev/stdin < "$input_file"
  fi
}

# shellcheck disable=SC2016
scram_verifier() {
  printf '%s' "$1" | python3 -c '
import base64
import hashlib
import hmac
import os
import sys

password = sys.stdin.buffer.read()
salt = os.urandom(16)
iterations = 4096
salted_password = hashlib.pbkdf2_hmac("sha256", password, salt, iterations)
client_key = hmac.new(salted_password, b"Client Key", hashlib.sha256).digest()
stored_key = hashlib.sha256(client_key).digest()
server_key = hmac.new(salted_password, b"Server Key", hashlib.sha256).digest()
b64 = lambda value: base64.b64encode(value).decode("ascii")
print(f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}")
'
}

admin_psql -d postgres \
  -c 'CREATE ROLE autoshop_owner LOGIN CREATEDB CREATEROLE;'

run_bootstrap() {
  local environment="$1"
  local db_name="autoshop_${environment}"
  local app_role="app_runtime_${environment}"
  local lambda_role="lambda_auth_${environment}"
  local migration_role="autoshop_migrations_${environment}"
  local app_password="local-${environment}-runtime-only"
  local lambda_password="local-${environment}-lambda-only"
  local migration_password="local-${environment}-migrations-only"


  local input_file="$tmp_dir/bootstrap-${environment}.sql"
  {
    printf '%s\n' "\\set dbname $db_name"
    printf '%s\n' "\\set owner_role autoshop_owner"
    printf '%s\n' "\\set app_role $app_role"
    printf '%s\n' "\\set lambda_role $lambda_role"
    printf '%s\n' "\\set migration_role $migration_role"
    printf '%s\n' "\\set app_password_hash $(scram_verifier "$app_password")"
    printf '%s\n' "\\set lambda_password_hash $(scram_verifier "$lambda_password")"
    printf '%s\n' "\\set migration_password_hash $(scram_verifier "$migration_password")"
    cat "$repo_root/sql/00-bootstrap.sql"
  } > "$input_file"
  chmod 600 "$input_file"
  admin_psql -d postgres -f /dev/stdin < "$input_file"

  local defaults_file="$tmp_dir/migration-defaults-${environment}.sql"
  {
    printf '%s\n' "\\set dbname $db_name"
    printf '%s\n' "\\set app_role $app_role"
    printf '%s\n' "\\set migration_role $migration_role"
    cat "$repo_root/sql/05-migration-default-privileges.sql"
  } > "$defaults_file"
  chmod 600 "$defaults_file"
  role_file_psql "$migration_role" "$migration_password" "$defaults_file"
}

run_grants() {
  local environment="$1"
  local db_name="autoshop_${environment}"
  local app_role="app_runtime_${environment}"
  local lambda_role="lambda_auth_${environment}"
  local migration_role="autoshop_migrations_${environment}"
  local migration_password="local-${environment}-migrations-only"
  local input_file="$tmp_dir/grants-${environment}.sql"
  {
    printf '%s\n' "\\set dbname $db_name"
    printf '%s\n' "\\set app_role $app_role"
    printf '%s\n' "\\set lambda_role $lambda_role"
    printf '%s\n' "\\set migration_role $migration_role"
    cat "$repo_root/sql/10-lambda-grants.sql"
  } > "$input_file"
  chmod 600 "$input_file"
  role_file_psql "$migration_role" "$migration_password" "$input_file"
}

for environment in hml prd; do
  run_bootstrap "$environment"
done

# A retry uses the already-published passwords resolved from Secrets Manager.
for environment in hml prd; do
  run_bootstrap "$environment" retry
done

for environment in hml prd; do
  db_name="autoshop_${environment}"
  admin_psql -d "$db_name" \
    -c "SET ROLE autoshop_migrations_${environment}; CREATE TABLE public.customers (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, status text NOT NULL, email text NOT NULL); CREATE TABLE public.customer_documents (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, customer_id integer NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE, document varchar(14) NOT NULL UNIQUE, created_at timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP); INSERT INTO public.customers (status, email) VALUES ('active', '${environment}@example.invalid'); INSERT INTO public.customer_documents (customer_id, document) VALUES (1, 'doc-${environment}'); CREATE TABLE public.future_records (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, payload text NOT NULL); RESET ROLE;"
  run_grants "$environment"
  run_grants "$environment"
done

expect_query() {
  local role="$1"
  local password="$2"
  local db_name="$3"
  local query="$4"
  local expected="$5"
  local actual
  actual="$(role_psql "$role" "$password" "$db_name" "$query")"
  [[ "$actual" == "$expected" ]] || { printf 'FAIL: query result mismatch for %s\n' "$role" >&2; exit 1; }
}

expect_sql_failure() {
  local role="$1"
  local password="$2"
  local db_name="$3"
  local query="$4"
  if role_psql "$role" "$password" "$db_name" "$query" >/dev/null 2>&1; then
    printf 'FAIL: unauthorized SQL unexpectedly succeeded for %s\n' "$role" >&2
    exit 1
  fi
}

for environment in hml prd; do
  db_name="autoshop_${environment}"
  runtime_role="app_runtime_${environment}"
  lambda_role="lambda_auth_${environment}"
  migration_role="autoshop_migrations_${environment}"
  runtime_password="local-${environment}-runtime-only"
  lambda_password="local-${environment}-lambda-only"
  migration_password="local-${environment}-migrations-only"

  expect_query "$runtime_role" "$runtime_password" "$db_name" \
    "INSERT INTO public.future_records (payload) VALUES ('runtime-${environment}'); SELECT count(*) FROM public.future_records;" "1"
  expect_query "$runtime_role" "$runtime_password" "$db_name" \
    "INSERT INTO public.customers (status, email) VALUES ('new', 'new-${environment}@example.invalid'); UPDATE public.customers SET status = 'verified' WHERE email = 'new-${environment}@example.invalid'; SELECT status FROM public.customers WHERE email = 'new-${environment}@example.invalid';" "verified"
  expect_query "$runtime_role" "$runtime_password" "$db_name" \
    "DELETE FROM public.future_records WHERE payload = 'runtime-${environment}'; SELECT count(*) FROM public.future_records;" "0"
  expect_query "$lambda_role" "$lambda_password" "$db_name" \
    "SELECT id || ':' || status FROM public.customers WHERE id = 1;" "1:active"
  expect_query "$lambda_role" "$lambda_password" "$db_name" \
    "SELECT customer_id || ':' || document FROM public.customer_documents WHERE customer_id = 1;" "1:doc-${environment}"
  expect_sql_failure "$lambda_role" "$lambda_password" "$db_name" 'SELECT created_at FROM public.customer_documents;'
  expect_sql_failure "$lambda_role" "$lambda_password" "$db_name" 'SELECT id FROM public.customer_documents;'

  expect_sql_failure "$runtime_role" "$runtime_password" "$db_name" 'CREATE TABLE public.runtime_ddl_denied (id integer);'
  expect_sql_failure "$runtime_role" "$runtime_password" "$db_name" 'CREATE TEMP TABLE runtime_temp_denied (id integer);'
  expect_sql_failure "$runtime_role" "$runtime_password" "$db_name" 'CREATE DATABASE runtime_database_denied;'
  expect_sql_failure "$lambda_role" "$lambda_password" "$db_name" 'SELECT email FROM public.customers;'
  expect_sql_failure "$lambda_role" "$lambda_password" "$db_name" "INSERT INTO public.customers (status, email) VALUES ('denied', 'denied@example.invalid');"
  expect_sql_failure "$lambda_role" "$lambda_password" "$db_name" "UPDATE public.customers SET status = 'denied' WHERE id = 1;"
  expect_sql_failure "$lambda_role" "$lambda_password" "$db_name" 'SELECT * FROM public.customers;'
  expect_sql_failure "$migration_role" "$migration_password" "$db_name" 'CREATE DATABASE migration_database_denied;'
done

expect_sql_failure app_runtime_hml local-hml-runtime-only autoshop_prd 'SELECT 1;'
expect_sql_failure app_runtime_prd local-prd-runtime-only autoshop_hml 'SELECT 1;'
expect_sql_failure autoshop_migrations_hml local-hml-migrations-only autoshop_prd 'SELECT 1;'
expect_sql_failure autoshop_migrations_prd local-prd-migrations-only autoshop_hml 'SELECT 1;'

for role in app_runtime_hml lambda_auth_hml autoshop_migrations_hml app_runtime_prd lambda_auth_prd autoshop_migrations_prd; do
  is_restricted="$(admin_psql -tA -d postgres \
    -c "SELECT (NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit)::text FROM pg_roles WHERE rolname = '${role}';")"
  [[ "$is_restricted" == true ]] || { printf 'FAIL: role flags are too broad for %s\n' "$role" >&2; exit 1; }
  memberships="$(admin_psql -tA -d postgres \
    -c "SELECT count(*) FROM pg_auth_members WHERE member = '${role}'::regrole OR roleid = '${role}'::regrole;")"
  [[ "$memberships" == 0 ]] || { printf 'FAIL: unexpected role membership for %s\n' "$role" >&2; exit 1; }
done

printf 'PASS: idempotent bootstrap, environment isolation, runtime DML, and restricted Lambda grants verified\n'
