#!/usr/bin/env bash
#
# scansuite-dump.sh - take a verified dump of an existing ScanSuite database.
#
# The dump is the input of scripts/scansuite-migrate.sh, which restores it into
# a NEW database and converts it there. The source database is only read, so it
# stays untouched as the rollback.
#
# Stop every ScanSuite writer first (web, workers, beat), e.g.
#   docker compose stop web worker worker_admin worker_poc celery_beat
# The script refuses to run while other sessions are connected, and it checks
# that no row changed while the dump was taken.
#
# Output directory:
#   scansuite.dump   pg_dump custom-format archive (restore with pg_restore)
#   schema.sql       schema only, for review
#   row-counts.tsv   exact row count of every table ("table<TAB>rows"); 0 for vulns,
#                    the CVE feed, whose rows are not dumped (reloaded at startup)
#   toc.txt          archive table of contents (proves the archive is readable)
#   dump-info.txt    source, server version, schema revision, time
#   SHA256SUMS       checksums of all of the above
#
# Examples
#   # docker-compose installation: run the client tools inside the postgres container
#   scripts/scansuite-dump.sh --env-file .env --pg-container scansuite-teams-postgres-1
#   # PostgreSQL client tools installed locally
#   PGPASSWORD=... scripts/scansuite-dump.sh --host db.internal --user scansuite --dbname scansuite

set -euo pipefail
export MSYS_NO_PATHCONV=1

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scansuite-dump.sh [options]

Connection (defaults: the schema owner PS_MIGRATION_USER/PASSWORD, else PS_DATABASE_*, from --env-file or the
environment; password from PGPASSWORD otherwise)
  --env-file FILE          read PS_DATABASE_HOST/PORT/USER/PASSWORD/NAME from a ScanSuite .env file
  --host HOST  --port PORT  --user USER  --dbname NAME
  --pg-container NAME      run pg_dump/psql/pg_restore via "docker exec" in this container
                           (for example the installation's postgres container)
Output
  --output DIR             new directory for the dump (default: ./scansuite-dump-<timestamp>)
  --include-vulndb         also dump the rows of the CVE feed table (vulns); by default only its
                           structure is dumped, because the application reloads it at startup
Safety
  --allow-active-connections   dump even if other sessions are connected (NOT for a cutover)
  -h, --help
EOF
}

env_value() {  # env_value FILE NAME: the last NAME=value in a .env file, unquoted
  local line
  line=$(grep -E "^[[:space:]]*$2=" "$1" | tail -n 1 || true)
  line=${line#*=}; line=${line%$'\r'}
  line=${line#\"}; line=${line%\"}; line=${line#\'}; line=${line%\'}
  printf '%s' "$line"
}

ENV_FILE="" HOST="" PORT="" DB_USER="" DBNAME="" OUTPUT="" PG_CONTAINER="" ALLOW_ACTIVE=0
# Tables dumped without their rows. vulns is the public CVE feed: the web
# process reloads it at startup (worker.tasks.load_vulndb), and an empty table
# always triggers a full reload.
EXCLUDED_DATA=(vulns)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-vulndb) EXCLUDED_DATA=(); shift ;;
    --env-file) ENV_FILE=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --user) DB_USER=$2; shift 2 ;;
    --dbname) DBNAME=$2; shift 2 ;;
    --pg-container) PG_CONTAINER=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --allow-active-connections) ALLOW_ACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

if [[ -n $ENV_FILE ]]; then
  [[ -f $ENV_FILE ]] || die "env file not found: $ENV_FILE"
  : "${PS_DATABASE_HOST:=$(env_value "$ENV_FILE" PS_DATABASE_HOST)}"
  : "${PS_DATABASE_PORT:=$(env_value "$ENV_FILE" PS_DATABASE_PORT)}"
  : "${PS_DATABASE_USER:=$(env_value "$ENV_FILE" PS_DATABASE_USER)}"
  : "${PS_DATABASE_NAME:=$(env_value "$ENV_FILE" PS_DATABASE_NAME)}"
  : "${PS_DATABASE_PASSWORD:=$(env_value "$ENV_FILE" PS_DATABASE_PASSWORD)}"
  : "${PS_MIGRATION_USER:=$(env_value "$ENV_FILE" PS_MIGRATION_USER)}"
  : "${PS_MIGRATION_PASSWORD:=$(env_value "$ENV_FILE" PS_MIGRATION_PASSWORD)}"
fi
# The schema owner (PS_MIGRATION_*) reads and restores everything; the runtime
# role (PS_DATABASE_*) is restricted by row-level security and would see nothing.
if [[ -n ${PS_MIGRATION_USER:-} ]]; then
  PS_DATABASE_USER=$PS_MIGRATION_USER
  PS_DATABASE_PASSWORD=${PS_MIGRATION_PASSWORD:-}
fi
export PGHOST=${HOST:-${PS_DATABASE_HOST:-${PGHOST:-localhost}}}
export PGPORT=${PORT:-${PS_DATABASE_PORT:-${PGPORT:-5432}}}
export PGUSER=${DB_USER:-${PS_DATABASE_USER:-${PGUSER:-scansuite}}}
export PGDATABASE=${DBNAME:-${PS_DATABASE_NAME:-${PGDATABASE:-scansuite}}}
export PGPASSWORD=${PGPASSWORD:-${PS_DATABASE_PASSWORD:-}}
export PGCONNECT_TIMEOUT=10 PGOPTIONS='-c client_min_messages=warning'

pg() {  # pg TOOL ARGS...: a PostgreSQL client tool, locally or in --pg-container
  if [[ -n $PG_CONTAINER ]]; then
    docker exec -i -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGCONNECT_TIMEOUT -e PGOPTIONS "$PG_CONTAINER" "$@"
  else
    "$@"
  fi
}
q() { pg psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"; }

row_counts() {  # exact count of every table, sorted, "table<TAB>rows"
  pg psql -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 -c "
    SELECT table_name,
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                                                false, true, '')))[1]::text::bigint
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    ORDER BY table_name" | tr -d '\r'
}

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --- Preflight -------------------------------------------------------------
if [[ -n $PG_CONTAINER ]]; then
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || die "container not found: $PG_CONTAINER"
else
  for tool in psql pg_dump pg_restore; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed (or use --pg-container)"
  done
fi

OUTPUT=${OUTPUT:-./scansuite-dump-$(date +%Y%m%d-%H%M%S)}
if [[ -e $OUTPUT ]] && [[ -n $(ls -A "$OUTPUT" 2>/dev/null) ]]; then
  die "output directory is not empty: $OUTPUT"
fi
mkdir -p "$OUTPUT"

log "Connecting to $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
SERVER_VERSION=$(q "SHOW server_version" | tr -d '\r') || die "cannot connect to the source database"
# Two queries: PostgreSQL resolves a table name in a CASE branch that is never
# taken, so one query fails on a pre-team database without alembic_version.
REVISION=none
if [[ -n $(q "SELECT to_regclass('alembic_version')" | tr -d '\r') ]]; then
  REVISION=$(q "SELECT version_num FROM alembic_version" | tr -d '\r')
fi
TABLES=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'" | tr -d '\r')
[[ $TABLES -gt 0 ]] || die "the source database has no tables"
echo "PostgreSQL $SERVER_VERSION, $TABLES tables, schema revision: $REVISION"

log "Checking that ScanSuite is stopped"
OTHERS=$(q "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()" | tr -d '\r')
if [[ $OTHERS -gt 0 ]]; then
  q "SELECT '  ' || coalesce(nullif(application_name, ''), '?') || ' from ' || coalesce(client_addr::text, 'local')
            || ' (' || coalesce(state, '?') || ')'
     FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()"
  if [[ $ALLOW_ACTIVE -eq 0 ]]; then
    die "$OTHERS other session(s) are connected. Stop web, workers and beat first, or pass --allow-active-connections (not for a cutover)."
  fi
  echo "Continuing with active sessions (--allow-active-connections)."
fi

# --- Dump --------------------------------------------------------------------
log "Counting rows"
BEFORE=$(row_counts)
# The manifest is what the restore must hold: tables dumped without data count 0.
awk -F'\t' -v OFS='\t' -v skip=" ${EXCLUDED_DATA[*]:-} " \
  'index(skip, " " $1 " ") { $2 = 0 } { print }' <<<"$BEFORE" > "$OUTPUT/row-counts.tsv"
ROWS=$(awk -F'\t' '{s += $2} END {print s + 0}' "$OUTPUT/row-counts.tsv")
echo "$(wc -l < "$OUTPUT/row-counts.tsv" | tr -d ' ') tables, $ROWS rows to keep"
EXCLUDE_ARGS=()
for table in "${EXCLUDED_DATA[@]}"; do
  echo "Not dumping the rows of $table ($(awk -F'\t' -v t="$table" '$1 == t {print $2}' <<<"$BEFORE") rows): reloaded from the feed at startup"
  EXCLUDE_ARGS+=("--exclude-table-data=public.$table")
done

log "Dumping (custom format)"
pg pg_dump --format=custom --compress=6 --no-owner --no-privileges "${EXCLUDE_ARGS[@]}" > "$OUTPUT/scansuite.dump"
pg pg_dump --schema-only --no-owner --no-privileges > "$OUTPUT/schema.sql"

log "Checking that nothing changed during the dump"
if [[ $(row_counts) != "$BEFORE" ]]; then
  die "row counts changed while dumping: a writer is still running. The dump in $OUTPUT is not consistent; stop all writers and retry."
fi

log "Validating the archive"
pg pg_restore --list < "$OUTPUT/scansuite.dump" > "$OUTPUT/toc.txt" || die "the archive cannot be read back"
ENTRIES=$(grep -c ' TABLE DATA ' "$OUTPUT/toc.txt" || true)
echo "Archive readable; $ENTRIES table data entries"

cat > "$OUTPUT/dump-info.txt" <<EOF
source_host=$PGHOST
source_port=$PGPORT
source_database=$PGDATABASE
source_user=$PGUSER
server_version=$SERVER_VERSION
schema_revision=$REVISION
tables=$TABLES
rows=$ROWS
excluded_table_data=${EXCLUDED_DATA[*]:-}
dumped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
(cd "$OUTPUT" && sha256 scansuite.dump schema.sql row-counts.tsv toc.txt dump-info.txt > SHA256SUMS)

log "Done"
echo "Dump:      $OUTPUT/scansuite.dump ($(du -h "$OUTPUT/scansuite.dump" | cut -f1))"
echo "Manifest:  $OUTPUT/row-counts.tsv ($ROWS rows in $TABLES tables)"
echo "Next:      scripts/scansuite-migrate.sh --dump $OUTPUT --team-slug <slug> --team-name <name> ..."
echo "Object-store files (SeaweedFS volume or GCS bucket) are not in the dump: keep the new instance on the"
echo "same object store, or copy it, so stored reports and AI checkpoints stay readable."
