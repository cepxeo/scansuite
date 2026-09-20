#!/usr/bin/env bash
#
# scansuite-migrate.sh - convert a dump of a pre-team ScanSuite installation
# into a NEW database whose data belongs to one team.
#
# Input is a directory written by scripts/scansuite-dump.sh. The source database
# is never touched: the dump is restored into an empty target database and
# converted there (database.cutover prepare):
#
#   1. verify the dump's checksums and restore it into the empty target;
#   2. check that every table has exactly the dumped number of rows;
#   3. bring the old schema to the cutover baseline, apply the Alembic
#      migrations, create the team and assign it every product, scan, finding,
#      credential, asset, rule and schedule; every user becomes a member
#      (Admin -> team_admin, User -> operator) and schedules run as the team's
#      "scheduler" service account; rows that old code left dangling are
#      archived in ownership_quarantine, never dropped;
#   4. make ownership mandatory (team_id NOT NULL) and force row-level security;
#   5. optionally promote named users to team_admin;
#   6. verify: schema revision, ownership, memberships and row counts
#      (before = after + archived) - and optionally compare the schema with a
#      freshly built database.
#
# Then point the services at the target database (PS_DATABASE_NAME, and
# LEGACY_TEAM_SLUG = the team slug) and start them. To roll back, point them at
# the old database again.
#
# Examples
#   # docker-compose installation, target database on the same server
#   scripts/scansuite-migrate.sh --dump ./scansuite-dump-20260919-101500 --env-file .env \
#       --pg-container scansuite-teams-postgres-1 --target-dbname scansuite_teams --create-database \
#       --team-slug acme --team-name "ACME Security" --team-admin admin --schema-check

set -euo pipefail
export MSYS_NO_PATHCONV=1

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scansuite-migrate.sh --dump DIR [options]

Input
  --dump DIR                 directory written by scansuite-dump.sh (required)
Target database (defaults: PS_DATABASE_* from --env-file or the environment; PS_MIGRATION_USER/PASSWORD still
override them for an installation that kept a separate owner; password from PGPASSWORD otherwise).
  --env-file FILE            the NEW instance's .env file
  --target-host HOST  --target-port PORT  --target-user USER  --target-dbname NAME
  --create-database          create the target database (it must not exist yet)
  --pg-container NAME        run psql/pg_restore via "docker exec" in this container
Team
  --team-slug SLUG           team that receives all existing data (default: legacy)
  --team-name NAME           its display name (default: Legacy)
  --team-admin USERNAME      make this user a team_admin (repeatable)
Conversion runner (runs "python -m database.cutover" with the ScanSuite server code)
  --runner compose|local     compose (default): "docker compose run" of the migrate service;
                             local: python in services/server on this machine
  --compose-file FILE        compose file for --runner compose, relative to the repository
                             (default: docker-compose.yml)
  --compose-service NAME     service to run (default: migrate)
Checks
  --schema-check             also build a throwaway empty database, prepare it from scratch and
                             compare its structure with the converted one (needs CREATEDB)
  --check-ai                 send one prompt through the imported system AI default and every team
                             override with the configured keys; fails if any does not answer
  --yes                      do not ask for confirmation
  -h, --help
EOF
}

env_value() {
  local line
  line=$(grep -E "^[[:space:]]*$2=" "$1" | tail -n 1 || true)
  line=${line#*=}; line=${line%$'\r'}
  line=${line#\"}; line=${line%\"}; line=${line#\'}; line=${line%\'}
  printf '%s' "$line"
}

urlencode() {
  local value=$1 out="" char i
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    case $char in
      [a-zA-Z0-9.~_-]) out+=$char ;;
      *) printf -v char '%%%02X' "'$char"; out+=$char ;;
    esac
  done
  printf '%s' "$out"
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DUMP="" ENV_FILE="" HOST="" PORT="" DB_USER="" DBNAME="" CREATE_DB=0 PG_CONTAINER=""
TEAM_SLUG=legacy TEAM_NAME=Legacy TEAM_ADMINS=() RUNNER=compose COMPOSE_FILE=""
SERVICE=migrate RUNTIME_ROLES="" SCHEMA_CHECK=0 CHECK_AI=0 ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump) DUMP=$2; shift 2 ;;
    --env-file) ENV_FILE=$2; shift 2 ;;
    --target-host) HOST=$2; shift 2 ;;
    --target-port) PORT=$2; shift 2 ;;
    --target-user) DB_USER=$2; shift 2 ;;
    --target-dbname) DBNAME=$2; shift 2 ;;
    --create-database) CREATE_DB=1; shift ;;
    --pg-container) PG_CONTAINER=$2; shift 2 ;;
    --team-slug) TEAM_SLUG=$2; shift 2 ;;
    --team-name) TEAM_NAME=$2; shift 2 ;;
    --team-admin) TEAM_ADMINS+=("$2"); shift 2 ;;
    --runner) RUNNER=$2; shift 2 ;;
    --compose-file) COMPOSE_FILE=$2; shift 2 ;;
    --compose-service) SERVICE=$2; shift 2 ;;
    --schema-check) SCHEMA_CHECK=1; shift ;;
    --check-ai) CHECK_AI=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[[ -n $DUMP ]] || { usage >&2; die "--dump is required"; }
[[ $TEAM_SLUG =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "team slug must be lowercase letters, digits and dashes"
[[ $RUNNER == compose || $RUNNER == local ]] || die "--runner must be compose or local"

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
# One account owns the schema and runs the application: the policies are
# forced on it, so there is no second role to create or grant. RUNTIME_ROLES
# stays for an installation that keeps a reporting login of its own.
RUNTIME_USER=${RUNTIME_ROLES:-}
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
TARGET_DB=$PGDATABASE

pg() {
  if [[ -n $PG_CONTAINER ]]; then
    docker exec -i -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGCONNECT_TIMEOUT -e PGOPTIONS "$PG_CONTAINER" "$@"
  else
    "$@"
  fi
}
q() { pg psql -X -q -A -t -v ON_ERROR_STOP=1 "$@" | tr -d '\r'; }
q_on() { local database=$1; shift; PGDATABASE=$database q "$@"; }

row_counts() {
  pg psql -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 -c "
    SELECT table_name,
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                                                false, true, '')))[1]::text::bigint
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    ORDER BY table_name" | tr -d '\r'
}

database_uri() {  # the SQLAlchemy URL of database $1, as the runner reaches it
  printf 'postgresql+psycopg://%s:%s@%s:%s/%s' "$(urlencode "$PGUSER")" "$(urlencode "$PGPASSWORD")" \
    "$PGHOST" "$PGPORT" "$1"
}

compose() {  # docker compose, run from the repository so paths work on every platform
  (cd "$REPO_DIR" && docker compose ${COMPOSE_FILE:+-f "$COMPOSE_FILE"} "$@")
}

cutover() {  # cutover ARGS...: python -m database.cutover against the target
  export MIGRATION_DATABASE_URI LEGACY_TEAM_SLUG=$TEAM_SLUG AUTHORIZATION_RUNTIME_ROLES=$RUNTIME_USER
  if [[ $RUNNER == compose ]]; then
    compose run --rm -T --no-deps -e MIGRATION_DATABASE_URI -e LEGACY_TEAM_SLUG \
      -e AUTHORIZATION_RUNTIME_ROLES "$SERVICE" python -m database.cutover "$@"
  else
    (cd "$REPO_DIR/services/server" && python -m database.cutover "$@")
  fi
}

sha256_check() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c --quiet SHA256SUMS; else shasum -a 256 -c --quiet SHA256SUMS; fi; }

# --- 1. Check the dump -------------------------------------------------------
log "Checking the dump in $DUMP"
for file in scansuite.dump row-counts.tsv dump-info.txt SHA256SUMS; do
  [[ -f $DUMP/$file ]] || die "missing $DUMP/$file (was it written by scansuite-dump.sh?)"
done
(cd "$DUMP" && sha256_check) || die "checksum mismatch: the dump was modified or damaged"
SOURCE_DB=$(env_value "$DUMP/dump-info.txt" source_database)
SOURCE_HOST=$(env_value "$DUMP/dump-info.txt" source_host)
ROWS=$(env_value "$DUMP/dump-info.txt" rows)
echo "Dump of $SOURCE_DB on $SOURCE_HOST: $(env_value "$DUMP/dump-info.txt" tables) tables, $ROWS rows," \
     "revision $(env_value "$DUMP/dump-info.txt" schema_revision), taken $(env_value "$DUMP/dump-info.txt" dumped_at)"

if [[ -n $PG_CONTAINER ]]; then
  docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || die "container not found: $PG_CONTAINER"
else
  for tool in psql pg_restore; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed (or use --pg-container)"; done
fi
if [[ $RUNNER == compose ]]; then
  compose config --services | tr -d '\r' | grep -qx "$SERVICE" || die "compose service not found: $SERVICE"
fi

# --- 2. Check the target -----------------------------------------------------
log "Checking the target database $PGUSER@$PGHOST:$PGPORT/$TARGET_DB"
if [[ $TARGET_DB == "$SOURCE_DB" && $PGHOST == "$SOURCE_HOST" ]]; then
  die "the target is the source database. Restore into a NEW database (--target-dbname NAME --create-database)."
fi
EXISTS=$(q_on postgres -v name="$TARGET_DB" <<<"SELECT count(*) FROM pg_database WHERE datname = :'name'")
if [[ $CREATE_DB -eq 1 ]]; then
  [[ $EXISTS -eq 0 ]] || die "database $TARGET_DB already exists; drop --create-database to use it if it is empty"
else
  [[ $EXISTS -eq 1 ]] || die "database $TARGET_DB does not exist (use --create-database)"
  TABLES=$(q -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
  [[ $TABLES -eq 0 ]] || die "the target database is not empty ($TABLES tables). Use a new, empty database."
fi

cat <<EOF

Plan
  source (read-only, keep for rollback): $SOURCE_DB on $SOURCE_HOST
  target (new):                          $TARGET_DB on $PGHOST $( [[ $CREATE_DB -eq 1 ]] && echo '(will be created)')
  team:                                  $TEAM_SLUG ("$TEAM_NAME")${TEAM_ADMINS[*]:+, team admins: ${TEAM_ADMINS[*]}}
EOF
if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Proceed? [y/N] " answer
  [[ $answer == y || $answer == Y ]] || die "aborted"
fi

if [[ $CREATE_DB -eq 1 ]]; then
  log "Creating database $TARGET_DB"
  # Fails if the database appeared since the check: the restore never goes into
  # a database this script did not create.
  q_on postgres -v name="$TARGET_DB" <<<'CREATE DATABASE :"name"' >/dev/null \
    || die "could not create $TARGET_DB (was it created meanwhile?); nothing was restored"
fi

# --- 3. Restore --------------------------------------------------------------
log "Restoring the dump (single transaction)"
pg pg_restore --no-owner --no-privileges --exit-on-error --single-transaction --dbname="$TARGET_DB" \
  < "$DUMP/scansuite.dump" || die "restore failed; the target database was left empty"

log "Comparing row counts with the dump"
if ! row_counts | diff "$DUMP/row-counts.tsv" -; then
  die "the restored database does not match the dump (see differences above)"
fi
echo "All $(wc -l < "$DUMP/row-counts.tsv" | tr -d ' ') tables match ($ROWS rows)"

# --- 4. Convert ----------------------------------------------------------------
MIGRATION_DATABASE_URI=$(database_uri "$TARGET_DB")
log "Converting: schema baseline, migrations, team '$TEAM_SLUG', ownership contract"
cutover prepare --team-slug "$TEAM_SLUG" --team-name "$TEAM_NAME" \
  || die "conversion failed. The source is untouched; fix the reported problem, drop $TARGET_DB and run again."

for admin in "${TEAM_ADMINS[@]}"; do
  log "Making $admin a team admin"
  CHANGED=$(q -v slug="$TEAM_SLUG" -v name="$admin" <<'SQL'
UPDATE team_memberships m SET role = 'team_admin', status = 'active', version = m.version + 1
FROM users u, teams t
WHERE m.user_id = u.id AND m.team_id = t.id AND t.slug = :'slug' AND u.username = :'name'
RETURNING m.id;
SQL
)
  [[ -n $CHANGED ]] || die "user $admin is not a member of $TEAM_SLUG (unknown username?)"
done

# --- 5. Verify -------------------------------------------------------------------
log "Verifying ownership, revision and row counts"
cutover verify --team-slug "$TEAM_SLUG" --manifest - < "$DUMP/row-counts.tsv" \
  || die "verification failed (see the report above). The source is untouched."

if [[ $SCHEMA_CHECK -eq 1 ]]; then
  REFERENCE_DB="${TARGET_DB}_schema_reference"
  log "Building $REFERENCE_DB from scratch and comparing schemas"
  # Never reuse or drop a database this script did not create.
  [[ $(q_on postgres -v name="$REFERENCE_DB" <<<"SELECT count(*) FROM pg_database WHERE datname = :'name'") -eq 0 ]] \
    || die "database $REFERENCE_DB already exists; drop it yourself if it is a leftover of an earlier run"
  q_on postgres -v name="$REFERENCE_DB" <<<'CREATE DATABASE :"name"' >/dev/null \
    || die "could not create $REFERENCE_DB"
  trap 'q_on postgres -v name="$REFERENCE_DB" <<<"DROP DATABASE IF EXISTS :\"name\"" >/dev/null || true' EXIT
  cutover schema-diff --reference "$(database_uri "$REFERENCE_DB")" || die "schema comparison failed"
  echo "Differences are schema drift the old installation accumulated; review them before going live."
fi

if [[ $CHECK_AI -eq 1 ]]; then
  log "Checking AI profiles with the configured keys"
  cutover check-ai || die "an AI profile did not answer (see the report above). Fix it in the platform console or team settings after the cutover, or rerun with working credentials."
fi

log "Done: $TARGET_DB is ready"
cat <<EOF
Next steps
  1. Point the services at the new database and team, e.g. in .env:
       PS_DATABASE_NAME=$TARGET_DB
       LEGACY_TEAM_SLUG=$TEAM_SLUG
  2. Start ScanSuite (docker compose up -d). The migrate job finds the database current; web and
     workers refuse to start if it is not. The CVE feed (vulns) is not in the dump; web reloads it
     on start, which takes a few minutes.
  3. Sign in and check products, scans and findings. Rollback: point PS_DATABASE_NAME back at
     $SOURCE_DB, which was not modified.
EOF
