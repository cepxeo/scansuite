#!/usr/bin/env bash
# Upgrade a single-host ScanSuite installation to teams, in one run.
#
#   cd ~/apps/scansuite && scripts/scansuite-upgrade-to-teams.sh
#
# Run it from the application folder (the one with docker-compose.yml and .env),
# after the new release's images have been installed there, with this scripts/
# folder next to docker-compose.yml. No parameters: every value is taken from
# .env or chosen as described below.
#
# What it does (docs/team-authorization-rollout.md, section 4):
#   1. checks the installation and the new release, and adds the migration job
#      to the installation's own docker-compose.yml (the file is kept, with its
#      images, customisations and comments; the original is saved next to it);
#   2. saves .env as env.before-cutover (the rollback configuration) and adds the
#      new settings, generating what is missing (wrapping keys, SECRET_KEY);
#      the keys are also written to a backup file;
#   3. stops ScanSuite (the database, Redis, object store and nginx keep running);
#   4. dumps the current database (scripts/scansuite-dump.sh), which is never modified;
#   5. converts the dump into a new database (scripts/scansuite-migrate.sh) and
#      checks the AI configuration;
#   6. backs up the converted database (the new baseline);
#   7. points ScanSuite at the new database and starts it;
#   8. waits for the web application and runs the health check.
#
# Best guesses (change them in .env before running if they do not fit):
#   old database   PS_DATABASE_NAME from .env (default scansuite)
#   new database   scansuite_teams
#   team           LEGACY_TEAM_SLUG from .env, else "appsec" (name "AppSec");
#                  former administrators become its team admins, other users operators
#   database      the account in .env; one account owns the schema and runs the
#                  application, with row-level security forced on it
#   keys           SCANSUITE_/PLATFORM_WRAPPING_KEYS from .env, else generated (k1, p1)
#   SSO            SSO_ENABLED=false; team creation stays closed
#
# Rollback (until the new database has taken real work): stop ScanSuite, restore
# .env and docker-compose.yml from the copies this script saves, and start the
# previous release's images. The old database is exactly as it was.
set -Eeuo pipefail

TARGET_DB=${SCANSUITE_TARGET_DB:-scansuite_teams}  # override only for testing
DEFAULT_SLUG=appsec
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="upgrade-to-teams-$STAMP.log"

exec > >(tee -a "$LOG") 2>&1

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
die() {
  printf '\n\033[1;31mFAILED:\033[0m %s\n' "$*"
  rollback_hint
  exit 1
}

PHASE=preflight
rollback_hint() {
  case $PHASE in
    preflight)
      echo "Nothing was changed." ;;
    prepared|stopped|dumped|converted)
      echo "The old database ($OLD_DB) was not modified, and ScanSuite may be stopped."
      echo "To go back: cp env.before-cutover .env, restore docker-compose.yml.before-upgrade-$STAMP,"
      echo "then start the PREVIOUS release's images."
      echo "To retry: fix the problem above, drop $TARGET_DB if it was created, and run this script again." ;;
    switched)
      echo "ScanSuite now points at $TARGET_DB. The old database ($OLD_DB) was not modified."
      echo "To go back: stop ScanSuite, cp env.before-cutover .env, restore docker-compose.yml.before-upgrade-$STAMP,"
      echo "and start the PREVIOUS release's images." ;;
  esac
  echo "Full log: $LOG"
}
trap 'die "unexpected error on line $LINENO (see the log above)"' ERR

env_value() {  # env_value KEY: the value of KEY in .env, unquoted
  local line
  line=$(grep -E "^[[:space:]]*$1=" .env | tail -n 1 || true)
  line=${line#*=}; line=${line%$'\r'}
  line=${line#\"}; line=${line%\"}; line=${line#\'}; line=${line%\'}
  printf '%s' "$line"
}

set_env() {  # set_env KEY VALUE: replace or append KEY in .env (values are never printed)
  local tmp
  tmp=$(mktemp)
  KEY=$1 VALUE=$2 awk 'BEGIN { key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]; done = 0 }
    index($0, key "=") == 1 { print key "=" value; done = 1; next }
    { print }
    END { if (!done) print key "=" value }' .env > "$tmp"
  cat "$tmp" > .env
  rm -f "$tmp"
}

random_password() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
random_key() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

compose() { docker compose "$@"; }

# ------------------------------------------------------------------ 1. checks
step "Checking the installation"
[[ -f docker-compose.yml && -f .env ]] || die "run this from the application folder (docker-compose.yml and .env not found in $(pwd))"
for script in scripts/scansuite-dump.sh scripts/scansuite-migrate.sh; do
  [[ -f $script ]] || die "$script is missing: copy the scripts/ folder of the new release next to docker-compose.yml"
done
command -v docker >/dev/null || die "docker is not installed"
if grep -qE '^[[:space:]]*image: appsec4u/[a-z-]+:TAG[[:space:]]*$' docker-compose.yml; then
  # The release docker-compose.yml, copied without the installer: its release code
  # is the end of the licence file name, key/<name>_<code>.lic.
  LICENCES=(key/*_??????.lic)
  [[ ${#LICENCES[@]} == 1 && -f ${LICENCES[0]} ]] \
    || die "docker-compose.yml still says TAG and key/ does not hold exactly one licence file (<name>_<code>.lic): run sed -i 's/:TAG\$/:<code>/' docker-compose.yml"
  RELEASE=${LICENCES[0]%.lic}; RELEASE=${RELEASE##*_}
  sed -i "s/^\([[:space:]]*image: appsec4u\/[a-z-]*\):TAG[[:space:]]*$/\1:$RELEASE/" docker-compose.yml
  info "release code $RELEASE (from ${LICENCES[0]}) written into docker-compose.yml"
fi
docker compose version >/dev/null 2>&1 || die "docker compose (v2) is not available"
docker compose config --quiet || die "docker-compose.yml is not valid for docker compose (see above)"
grep -qx postgres <<<"$(compose config --services)" || die "docker-compose.yml has no 'postgres' service; this script is for single-host installations"

# ------------------------------------------- 1a. the migration job in compose
# The installation's own docker-compose.yml is kept, with its images, its
# customisations and its comments: only the lines the team release needs are
# added (the 'migrate' service, the wait for it, and the owner account for the
# database healthcheck). A file that already has them is left alone.
step "Adding the migration job to docker-compose.yml"
if grep -qx migrate <<<"$(compose config --services)"; then
  info "docker-compose.yml already has the 'migrate' service"
else
  PATCHER=.scansuite-compose-patch.py
  cat > "$PATCHER" <<'PYTHON'
"""Add the migration job to an existing docker-compose.yml, line by line.

Reads the file, writes the result to stdout and a summary to stderr. The file
is edited as text, never re-serialised, so comments, anchors, quoting and
formatting stay exactly as they are. Exits 3 when nothing needs changing.
"""
import os
import re
import sys

APP_SERVICES = ("web", "worker", "worker_admin", "worker_poc", "celery_beat", "scan_job")

path = sys.argv[1]
with open(path) as handle:
    lines = handle.read().split("\n")
changes = []


def indent_of(line):
    return len(line) - len(line.lstrip())


def block_end(start, indent):
    """The line after the block that starts at `start` and is indented deeper."""
    end = start + 1
    last = end
    while end < len(lines):
        if lines[end].strip() and indent_of(lines[end]) <= indent:
            break
        if lines[end].strip():
            last = end
        end += 1
    return last + 1


services_at = None
for number, line in enumerate(lines):
    if re.match(r"^services:\s*$", line):
        services_at = number
        break
if services_at is None:
    sys.exit("docker-compose.yml has no 'services:' section")
services_end = block_end(services_at, 0)

services = {}       # name -> (first line, line after the block)
service_indent = None
number = services_at + 1
while number < services_end:
    match = re.match(r"^(\s+)([A-Za-z0-9_.-]+):\s*$", lines[number])
    if match and (service_indent is None or len(match.group(1)) == service_indent):
        service_indent = len(match.group(1))
        end = block_end(number, service_indent)
        services[match.group(2)] = (number, end)
        number = end
        continue
    number += 1
if not services:
    sys.exit("no services found in docker-compose.yml")
child_indent = service_indent * 2


def service_lines(name):
    start, end = services[name]
    return range(start + 1, end)


def find_key(name, key):
    """The line of `key:` directly under service `name`, or None."""
    for number in service_lines(name):
        if re.match(r"^\s{%d}%s:" % (child_indent, re.escape(key)), lines[number]):
            return number
    return None


def shift(at, count):
    """Keep the recorded service ranges right after inserting `count` lines."""
    for name, (start, end) in services.items():
        services[name] = (start + count if start >= at else start,
                          end + count if end >= at else end)


def wait_for_migrate(name):
    """Make service `name` start only after the migration job has succeeded."""
    entry = ["%smigrate:" % (" " * (child_indent + service_indent)),
             "%scondition: service_completed_successfully" % (" " * (child_indent + 2 * service_indent))]
    at = find_key(name, "depends_on")
    if at is None:
        start, end = services[name]
        lines[end:end] = ["%sdepends_on:" % (" " * child_indent)] + entry
        shift(end, len(entry) + 1)
        changes.append("%s: waits for migrate" % name)
        return
    end = block_end(at, indent_of(lines[at]))
    body = [lines[number] for number in range(at + 1, end)]
    if any(re.match(r"^\s*migrate:", line) or re.match(r"^\s*-\s*migrate\s*$", line) for line in body):
        return
    if any(re.match(r"^\s*-\s", line) for line in body):
        # The short list form cannot carry a condition: write the same
        # dependencies in the mapping form, then add the job.
        converted = []
        for line in body:
            item = re.match(r"^\s*-\s*(\S+)\s*$", line)
            if not item:
                sys.exit("%s: cannot read the depends_on list (%r)" % (name, line))
            converted.append("%s%s:" % (" " * (child_indent + service_indent), item.group(1)))
            converted.append("%scondition: service_started" % (" " * (child_indent + 2 * service_indent)))
        lines[at + 1:end] = converted + entry
        shift(end, len(converted) + len(entry) - len(body))
        changes.append("%s: waits for migrate (depends_on written as conditions)" % name)
        return
    lines[end:end] = entry
    shift(end, len(entry))
    changes.append("%s: waits for migrate" % name)


# --- the database answers before the job runs ---------------------------------
# The job waits for a healthy database, so postgres needs a healthcheck:
# compose refuses to start a service that waits for one without it.
if "postgres" in services and find_key("postgres", "healthcheck") is None:
    inner = " " * (child_indent + service_indent)
    check = ["%shealthcheck:" % (" " * child_indent),
             '%stest: ["CMD-SHELL", "pg_isready -U \\"$${POSTGRES_USER}\\" -d \\"$${POSTGRES_DB}\\""]' % (inner,),
             "%sinterval: 5s" % (inner,),
             "%stimeout: 5s" % (inner,),
             "%sretries: 30" % (inner,)]
    at = services["postgres"][1]
    lines[at:at] = check
    shift(at, len(check))
    changes.append("postgres: healthcheck added (pg_isready)")

# --- this product's images ---------------------------------------------------
# A classic installation names the images of the product without teams. They
# are different images here, so the file is pointed at them; the release code
# (the part after the colon) is unchanged, because it comes from the licence.
CLASSIC_IMAGES = (("appsec4u/worker-poc", "appsec4u/teams-worker-poc"),
                  ("appsec4u/worker", "appsec4u/teams-worker"),
                  ("appsec4u/web", "appsec4u/teams-web"))
IMAGE_LINE = re.compile(r"^(\s+image:\s*)(appsec4u/[A-Za-z0-9_.-]+)(:\S+)?\s*$")
for number, line in enumerate(lines):
    match = IMAGE_LINE.match(line)
    if not match:
        continue
    for classic, teams in CLASSIC_IMAGES:
        if match.group(2) == classic:
            lines[number] = "%s%s%s" % (match.group(1), teams, match.group(3) or "")
            changes.append("%s: image %s" % (classic.split("/")[1], teams))
            break

# --- the migration job itself -------------------------------------------------
# It runs the release's own worker image, the way the workers run it. A file
# that already has the job keeps it: only the waits below are added.
source = next((name for name in ("worker", "worker_admin", "celery_beat", "web") if name in services), None)
if source is None:
    sys.exit("docker-compose.yml has no worker or web service to copy the release image from")
def image_of(name):
    for number in service_lines(name):
        match = re.match(r"^\s+image:\s*(\S+)\s*$", lines[number])
        if match:
            return match.group(1)
    return None


image = image_of("migrate") if "migrate" in services else None
if "migrate" not in services:
    image = (image_of(source) or "").replace("appsec4u/teams-web", "appsec4u/teams-worker", 1)
    if not image:
        sys.exit("%s has no image line to copy the release image from" % source)
    command = '["python", "migrate.py"]'
    volumes = []
    env_file = None
    for number in service_lines(source):
        line = lines[number]
        if re.match(r"^\s+command:.*key_bootstrap", line):
            command = '["/bin/sh", "-lc", *key_bootstrap, "python", "migrate.py"]'
        if re.match(r"^\s+-\s*\./key:/key\s*$", line):
            volumes.append("- ./key:/key")
        if re.match(r"^\s+-\s*\./services/server:/app\s*$", line):
            volumes.append("- ./services/server:/app")
        if re.match(r"^\s+-\s*\.env\s*$", line):
            env_file = ".env"

    pad = " " * service_indent
    job = ["%s# Deploy-time schema job: creates the database with its team, or applies" % (pad,),
           "%s# pending migrations. Web and workers start only after it succeeds." % (pad,),
           "%smigrate:" % (pad,),
           "%simage: %s" % (" " * child_indent, image),
           "%scommand: %s" % (" " * child_indent, command)]
    if volumes:
        job.append("%svolumes:" % (" " * child_indent))
        job += ["%s%s" % (" " * (child_indent + service_indent), volume) for volume in volumes]
    if env_file:
        job += ["%senv_file:" % (" " * child_indent), "%s- %s" % (" " * (child_indent + service_indent), env_file)]
    if "postgres" in services:
        job += ["%sdepends_on:" % (" " * child_indent),
                "%spostgres:" % (" " * (child_indent + service_indent)),
                "%scondition: service_healthy" % (" " * (child_indent + 2 * service_indent))]
    at = services[source][0]
    lines[at:at] = job + [""]
    shift(at, len(job) + 1)
    services["migrate"] = (at + 2, at + len(job))  # after the two comment lines
    changes.append("migrate: added, running %s" % image)

for name in APP_SERVICES:
    if name in services:
        wait_for_migrate(name)

# --- the database healthcheck runs as the owner account -----------------------
if "postgres" in services:
    for number in service_lines("postgres"):
        for key in ("USER", "PASSWORD"):
            pattern = r"^(\s+POSTGRES_%s:\s*)\$\{PS_DATABASE_%s\}\s*$" % (key, key)
            match = re.match(pattern, lines[number])
            if match:
                lines[number] = "%s${PS_MIGRATION_%s:-${PS_DATABASE_%s}}" % (match.group(1), key, key)
                changes.append("postgres: POSTGRES_%s follows PS_MIGRATION_%s" % (key, key))

# --- the PoC worker runs the release image too --------------------------------
if "worker_poc" in services:
    release = image.split(":")[1] if ":" in image else None
    start, end = services["worker_poc"]
    number = start + 1
    while number < end:
        match = re.match(r"^(\s+image:\s*)appsec4u/teams-worker-poc(:\S+)?\s*$", lines[number])
        if match and release:
            wanted = "%sappsec4u/teams-worker-poc:%s" % (match.group(1), release)
            if lines[number] != wanted:
                lines[number] = wanted
                changes.append("worker_poc: image appsec4u/teams-worker-poc:%s" % release)
                # The release image is protected code: it needs the licence.
                # Read-only, because the container cannot write anything.
                if not any(re.match(r"^\s+-\s*\./key:/key", lines[inner]) for inner in range(start + 1, end)):
                    mount = "%s- ./key:/key:ro" % (" " * (child_indent + service_indent))
                    at_volumes = find_key("worker_poc", "volumes")
                    if at_volumes is None:
                        lines[number + 1:number + 1] = ["%svolumes:" % (" " * child_indent), mount]
                    else:
                        lines[at_volumes + 1:at_volumes + 1] = [mount]
                    shift(number, 2 if at_volumes is None else 1)
                    end += 2 if at_volumes is None else 1
                    changes.append("worker_poc: licence mounted at /key (read-only)")
        build = re.match(r"^(\s+)build:\s*$", lines[number])
        if build:
            build_end = block_end(number, len(build.group(1)))
            context = None
            for inner in range(number + 1, build_end):
                found = re.match(r"^\s+context:\s*(\S+)\s*$", lines[inner])
                if found:
                    context = found.group(1)
            # A production host has no source to build from; keep a build that works.
            if context and not os.path.isdir(context):
                del lines[number:build_end]
                shift(number, -(build_end - number))
                changes.append("worker_poc: build removed (%s is not on this host)" % context)
                end -= build_end - number
                continue
        number += 1

if not changes:
    sys.exit(3)
sys.stderr.write("\n".join(changes) + "\n")
sys.stdout.write("\n".join(lines))
PYTHON
  cp docker-compose.yml "docker-compose.yml.before-upgrade-$STAMP"
  PATCHED=$(mktemp)
  WORKER_IMAGE=$(grep -m1 -oE 'appsec4u/teams-worker:[A-Za-z0-9._-]+' docker-compose.yml || true)
  # A python3 that only prints an installation hint (Windows, some minimal
  # images) is no python3: check that it actually runs.
  if python3 -c 'import re, sys' >/dev/null 2>&1; then
    RUN_PATCHER=(python3 "$PATCHER" docker-compose.yml)
  elif [[ -n $WORKER_IMAGE ]]; then  # no python on the host: use the release image
    RUN_PATCHER=(docker run --rm -v "$PWD:/w" -w /w "$WORKER_IMAGE" python "/w/$PATCHER" /w/docker-compose.yml)
  else
    die "neither python3 nor an appsec4u/teams-worker image is available to update docker-compose.yml"
  fi
  set +e
  "${RUN_PATCHER[@]}" > "$PATCHED"
  PATCH_STATUS=$?
  set -e
  rm -f "$PATCHER"
  case $PATCH_STATUS in
    0)
      cat "$PATCHED" > docker-compose.yml
      rm -f "$PATCHED"
      if ! compose config --quiet; then
        cat "docker-compose.yml.before-upgrade-$STAMP" > docker-compose.yml
        die "the updated docker-compose.yml is not valid (restored the original; see the errors above)"
      fi
      grep -qx migrate <<<"$(compose config --services)" \
        || { cat "docker-compose.yml.before-upgrade-$STAMP" > docker-compose.yml
             die "the 'migrate' service was not added (restored the original)"; }
      info "updated; the original is docker-compose.yml.before-upgrade-$STAMP"
      ;;
    3)
      rm -f "$PATCHED" "docker-compose.yml.before-upgrade-$STAMP"
      die "docker-compose.yml has no 'migrate' service and nothing could be added: install the new release's docker-compose.yml"
      ;;
    *)
      rm -f "$PATCHED" "docker-compose.yml.before-upgrade-$STAMP"
      die "docker-compose.yml could not be updated (see the message above)"
      ;;
  esac
fi
SERVICES=$(compose config --services)

OLD_DB=$(env_value PS_DATABASE_NAME); OLD_DB=${OLD_DB:-scansuite}

step "Making sure the database is running"
compose up -d postgres >/dev/null
PG=$(compose ps -q postgres)
[[ -n $PG ]] || die "the postgres container is not running"
for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -q && break
  sleep 2
done
docker exec "$PG" pg_isready -q || die "PostgreSQL does not answer"

PG_SUPERUSER=$(docker exec "$PG" sh -c 'printf %s "$POSTGRES_USER"')
psql_admin() { docker exec -i "$PG" psql -U "$PG_SUPERUSER" -d postgres -qAt "$@"; }
db_exists() { [[ $(psql_admin -c "SELECT 1 FROM pg_database WHERE datname='$1'") == 1 ]]; }
db_exists "$OLD_DB" || die "database $OLD_DB does not exist"
# Converted means at or past the contract revision, the rule migrate.py uses
# (revision ids sort by name). Two queries: one would fail without the table.
psql_old() { docker exec -i "$PG" psql -U "$PG_SUPERUSER" -d "$OLD_DB" -qAt "$@"; }
OLD_REVISION=none
if [[ -n $(psql_old -c "SELECT to_regclass('public.alembic_version')") ]]; then
  OLD_REVISION=$(psql_old -c "SELECT version_num FROM alembic_version")
fi
if [[ $OLD_REVISION != none && ! $OLD_REVISION < 20260919_11 ]]; then
  echo "ScanSuite already runs on a converted database ($OLD_DB is at revision $OLD_REVISION): the upgrade has been done. Nothing to do."
  trap - ERR; exit 0
fi

# The new database is always a new name: never the old database, never one that
# exists (an earlier attempt, or anything else). An existing one is left alone.
if db_exists "$TARGET_DB"; then
  BASE_DB=$TARGET_DB
  for n in $(seq 2 99); do
    db_exists "${BASE_DB}_$n" || { TARGET_DB=${BASE_DB}_$n; break; }
  done
  [[ $TARGET_DB != "$BASE_DB" ]] || die "databases $BASE_DB to ${BASE_DB}_99 all exist: drop the ones you do not need"
  warn "database $BASE_DB already exists (an earlier attempt?) and is left untouched; converting into $TARGET_DB instead. Drop $BASE_DB later if you do not need it."
fi
[[ $TARGET_DB != "$OLD_DB" ]] || die "internal error: the new database name equals the old one"
info "old database: $OLD_DB (read-only), new database: $TARGET_DB"

step "Checking the new release"
compose run --rm --no-deps -T migrate python -c "import alembic, authlib, joserfc" \
  || die "the installed images are not the new release (alembic/authlib/joserfc missing): install the release first"
info "the images contain the new release"

step "Checking disk space"
DB_BYTES=$(psql_admin -c "SELECT pg_database_size('$OLD_DB')")
FREE_KB=$(docker exec "$PG" df -Pk /var/lib/postgresql/data | awk 'NR==2 {print $4}')
FREE_BYTES=$((FREE_KB * 1024))
info "database size: $((DB_BYTES / 1024 / 1024)) MB, free on the database volume: $((FREE_BYTES / 1024 / 1024)) MB"
(( FREE_BYTES > 3 * DB_BYTES )) || die "not enough free space: the conversion needs room for a second copy of the database plus dumps (3x its size)"

# ----------------------------------------------------------- 2. configuration
step "Preparing the configuration"
[[ -f env.before-cutover ]] || cp .env env.before-cutover
cp .env "env.before-upgrade-$STAMP"
info "rollback configuration: env.before-cutover (and env.before-upgrade-$STAMP)"
PHASE=prepared

# One account owns the schema and runs the application: row-level security is
# forced on it, so nothing here creates or configures a second one. An
# installation that already has a separate owner (PS_MIGRATION_USER) keeps it.
OWNER=$(env_value PS_MIGRATION_USER)
if [[ -n $OWNER ]]; then
  info "database account: $(env_value PS_DATABASE_USER), schema owner $OWNER (kept)"
else
  info "database account: $(env_value PS_DATABASE_USER)"
fi

KEYS_CREATED=0
if [[ -z $(env_value SCANSUITE_WRAPPING_KEYS) ]]; then
  set_env SCANSUITE_WRAPPING_KEYS "{\"k1\":\"$(random_key)\"}"
  set_env SCANSUITE_ACTIVE_WRAPPING_KEY k1
  KEYS_CREATED=1
fi
if [[ -z $(env_value PLATFORM_WRAPPING_KEYS) ]]; then
  set_env PLATFORM_WRAPPING_KEYS "{\"p1\":\"$(random_key)\"}"
  set_env PLATFORM_ACTIVE_WRAPPING_KEY p1
  KEYS_CREATED=1
fi
KEY_BACKUP="scansuite-wrapping-keys-$STAMP.txt"
( umask 077
  {
    echo "# ScanSuite wrapping keys ($STAMP). Without them, stored passwords and keys cannot be read."
    echo "# Move this file off the server into your secret store, then delete it here."
    grep -E '^(SCANSUITE|PLATFORM)_(ACTIVE_)?WRAPPING_KEYS?=' .env
  } > "$KEY_BACKUP" )
info "wrapping keys: $([[ $KEYS_CREATED == 1 ]] && echo generated || echo kept); backup written to $KEY_BACKUP"

[[ -n $(env_value SECRET_KEY) ]] || { set_env SECRET_KEY "$(random_password)$(random_password)"; info "SECRET_KEY generated"; }
TEAM_SLUG=$(env_value LEGACY_TEAM_SLUG); TEAM_SLUG=${TEAM_SLUG:-$DEFAULT_SLUG}
if [[ $TEAM_SLUG == appsec ]]; then TEAM_NAME=AppSec; else TEAM_NAME=$TEAM_SLUG; fi
set_env LEGACY_TEAM_SLUG "$TEAM_SLUG"
set_env SSO_ENABLED false
info "team: $TEAM_SLUG ($TEAM_NAME); single sign-on off"

# --------------------------------------------------------------------- 3. stop
step "Stopping ScanSuite"
WORKERS=$(compose ps -q worker 2>/dev/null | wc -l | tr -d ' ')
(( WORKERS > 0 )) || WORKERS=2
STOP=()
for service in web worker worker_admin worker_poc celery_beat ai_docs; do
  grep -qx "$service" <<<"$SERVICES" && STOP+=("$service")
done
compose stop "${STOP[@]}"
PHASE=stopped

# --------------------------------------------------------------------- 4. dump
step "Dumping $OLD_DB (read-only)"
DUMP="cutover-dump-$STAMP"
scripts/scansuite-dump.sh --env-file env.before-cutover --pg-container "$PG" --output "$DUMP"
PHASE=dumped

# ------------------------------------------------------------------ 5. convert
step "Converting into $TARGET_DB"
set +e
scripts/scansuite-migrate.sh --dump "$DUMP" --env-file .env --pg-container "$PG" --target-dbname "$TARGET_DB" \
  --create-database --team-slug "$TEAM_SLUG" --team-name "$TEAM_NAME" --check-ai --yes 2>&1 | tee "convert-$STAMP.log"
CONVERT_STATUS=${PIPESTATUS[0]}
set -e
grep -q 'VERIFY: OK' "convert-$STAMP.log" || die "the conversion did not verify (see convert-$STAMP.log)"
if (( CONVERT_STATUS != 0 )); then
  grep -q 'AI-CHECK:' "convert-$STAMP.log" \
    || die "the conversion failed (see convert-$STAMP.log)"
  warn "an AI profile did not answer. ScanSuite will work, but AI stays unavailable to the team until the AI key is fixed (Teams -> Team settings -> AI provider, or the platform console)."
fi
PHASE=converted

# ------------------------------------------------------------------- 6. backup
step "Backing up $TARGET_DB (the new baseline)"
scripts/scansuite-dump.sh --env-file .env --pg-container "$PG" --dbname "$TARGET_DB" --output "baseline-$TARGET_DB-$STAMP"

# ------------------------------------------------------------------- 7. start
step "Pointing ScanSuite at $TARGET_DB and starting it"
set_env PS_DATABASE_NAME "$TARGET_DB"
PHASE=switched
if [[ -x ./start-scansuite ]]; then
  ./start-scansuite "$WORKERS"  # the installed start script (asks for a first admin only if none exists)
else
  compose up -d --scale worker="$WORKERS"
fi
# nginx keeps the address it resolved for web at start; refresh it.
grep -qx nginx <<<"$SERVICES" && compose restart nginx >/dev/null

# ------------------------------------------------------------------ 8. checks
step "Waiting for the web application"
READY=0
for _ in $(seq 1 60); do
  if compose exec -T web python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/log_in', timeout=5)" >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 5
done
(( READY )) || die "the web application did not come up within 5 minutes: docker compose logs web migrate"
info "the web application answers"

step "Health check"
compose run --rm -T migrate python -m database.cutover monitor || warn "the health check reported alerts (see above)"

trap - ERR
step "Done"
cat <<EOF
ScanSuite now runs on $TARGET_DB, in team "$TEAM_SLUG".

Next:
  1. Sign in as a former administrator (now a team admin) and check products, history,
     findings, assets and credentials; open Team integrations and Teams -> Team settings.
     Row counts before the upgrade: $DUMP/row-counts.tsv
  2. Move $KEY_BACKUP off this server into your secret store, then delete it here.
  3. Keep $OLD_DB, $DUMP and env.before-cutover for the rollback period; the new
     baseline backup is baseline-$TARGET_DB-$STAMP.
  4. Add people on the Members page. Enable single sign-on only after one real sign-in works.

Rollback, before the new database has taken real work: stop ScanSuite, restore
the configuration (cp env.before-cutover .env) and docker-compose.yml.before-upgrade-$STAMP,
then start the previous release's images.
Log: $LOG
EOF
