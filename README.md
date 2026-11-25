## ScanSuite AI

ScanSuite AI runs AI-driven security scans: AI SAST of source code, secret
detection, dependency checks with AI reachability analysis and an SBOM, AI
Pentest of web applications and networks, and PoC verification of findings.

### Installing

Copy the licence file you were sent (`<name>_<code>.lic`) next to `services/scansuite.sh`
and run it, or, in a checkout of this repository:

```bash
cp <name>_<code>.lic key/
./scansuite install <code>
```

### Deploying on Google Cloud instead

`gcp/` deploys ScanSuite AI into your own Google Cloud project on Cloud Run,
with Cloud SQL, Memorystore, Cloud Storage and Secret Manager and no server to
look after. See [gcp/README.md](gcp/README.md) for how to deploy it, use it and
tear it down.

### Managing the installation

```bash
./scansuite status              # what is running
./scansuite logs web            # recent log lines for one service
./scansuite doctor              # check the host and the installation
./scansuite version             # release, licence and running images
./scansuite start [workers]     # start, waiting until every service is healthy
./scansuite stop
./scansuite restart
./scansuite update              # fetch the current release and apply it
./scansuite reset db            # empty the database and start over
./scansuite recover <user>      # nobody can administer: make <user> an installation admin, with a one-use password link
./scansuite --backup-db         # the database into a zip (see Backing up and restoring)
./scansuite --backup-secrets    # .env and key/ into a password-protected zip
./scansuite uninstall           # stop and remove the boot service
```

### Sizing AI Pentest runners

Where AI Pentest is installed, each AI Pentest scan runs on runners of the
`worker_pentest` service, next to the workers that `start [workers]` sets; every
runner is a fresh process in a run folder of its own. A large scope (more than
four web applications or 64 addresses) is split into shards, and one scan uses
up to `AI_PENTEST_RUNNERS_PER_SCAN` runners (default 4).
`AI_PENTEST_MAX_RUNNERS` (default 2) is the number of `worker_pentest`
replicas, so it caps the runners of the whole host; scans beyond it wait in the
queue for a free one.

A runner spends most of its time waiting for the AI model: on a lab host it used
0.3-0.4 GB of memory and under a fifth of a CPU core, with short peaks while
the browser or a scanner runs. Plan 1 CPU core and 2 GB of memory per runner,
on top of what ScanSuite itself uses (`docker stats`), and set
`AI_PENTEST_MAX_RUNNERS` to the smaller of the free cores and the free memory
divided by 2 GB. For example, a 16-core, 32 GB host running `start 6` uses about
9 GB, which leaves room for 8 runners. `AI_PENTEST_RUNNER_CPU` and
`AI_PENTEST_RUNNER_MEMORY` (4 and 16g) are limits for one runner, not
reservations. More runners than your AI provider's rate limit allows only make
them wait longer: when the scan log reports rate-limited requests, add no more.

### Upgrading

```bash
./scansuite update
```

That fetches this repository, pulls the images for your licence and restarts
only the services that changed. Your settings in `.env` and your files in
`key/` are kept; placeholder passwords left in `.env` are replaced with
generated ones, and the database is given the new one.

What you changed in the configuration the release ships — `docker-compose.yml`,
`compose.d/` and `services/nginx/` (the certificate too) — is
kept as well: the update merges your change into the new release's file, so
your lines and the release's new ones are both there, and says
`Kept this host's changes to: …`. Two cases it cannot merge, and says so:
the release changed the very lines you changed, or the services no longer load
with your change. The release's file is then put in place and yours is saved
in a `.replaced-<date>` directory next to it, with the change alone as
`<file>.patch`; apply it again by hand, or move it to
`docker-compose.local.yml`, which no release ever touches. Any other release
file that differs on the host (the `scansuite` command, the image lists) is
replaced, with a copy in the same directory.

Your own TLS certificate in `services/nginx/certs/` is kept together with its
key: when you changed either file, the update puts both back as they were.
The user who runs the update must be able to read them; a key copied there
with `sudo cp` belongs to root, and the update stops and says to run
`sudo chown $USER: services/nginx/certs/*.pem`. If `key.pem` is not the key
of `cert.pem`, nginx cannot start, so the update creates a self-signed pair
for this host and keeps yours in a `.replaced-<date>` directory.

The release ships no certificate or key. Without one of yours, `install`
creates a self-signed pair for this host with `openssl` (install it first, or
put your own certificate there). An installation still on the pair older
releases shipped gets its own at its next update, so browsers ask once more
to accept the certificate.

### Backing up and restoring

```bash
./scansuite --backup-db                 # the ScanSuite AI database
./scansuite --backup-secrets            # .env and key/, behind a password
./scansuite --restore-db <zip>
./scansuite --restore-secrets <zip>
```

Each backup is one zip, written to `backups/` in the installation directory
unless you name a file or a directory after the command. Copy it off the host:
a backup that exists only on the disk it protects is not one.

**The database.** `--backup-db` dumps the database while everything keeps
running. `--with-files` adds what the database points to — scan artifacts and
reports — and stops the artifact store while they are copied; without it a
restore brings back every finding, but not the stored reports. `--encrypt` puts
the zip behind a generated password.

`--restore-db <zip>` replaces the database with the one in the zip. It asks
first, saves the database as it is to `backups/before-restore-<date>.zip`,
stops the application for the few minutes it takes, and brings a backup made by
an earlier release up to the current schema. A backup made by a newer release
is refused: update first.

**The secrets.** `--backup-secrets` saves `.env` and everything in `key/`: the
licence and `scansuite-secrets.env`, the keys that decrypt the credentials
stored in the database. The zip opens only with a password that is generated
for it, shown once and stored nowhere, so note it and keep it apart from the
file. `--restore-secrets <zip>` asks for that password, puts the files back
with their owners and permissions, keeps what was there in `.replaced-<date>/`
and restarts the services.

A database backup is whole only together with a secrets backup of the same
installation. Restored under other keys, the credentials stored in it
(repository tokens and AI provider keys) cannot be read, and
`--restore-db` says so. To move to a new host: install there with your licence,
then `--restore-secrets`, then `--restore-db`.

The password protection is the standard one of zip, which every zip program
opens. It stops the file from being read in passing, not a determined attack,
so store a protected zip as carefully as any other secret. Where nobody is
there to type the password, a restore reads it from `SCANSUITE_BACKUP_PASSWORD`.

The generated password is printed only to a terminal. For a scheduled backup,
whose output goes to a log, give `--password-file <file>`: the password is
written there (mode 600) instead of printed, and a later run finds the file and
uses the same password again. `--password-file` on a database backup implies
`--encrypt`, and a restore takes it as well:

```bash
./scansuite --backup-db --password-file /root/scansuite-backup.pass
./scansuite --restore-db backups/<zip> --password-file /root/scansuite-backup.pass
```

Keep the password file off the backup disk.

### What is on this host

| Path | |
|---|---|
| `.env` | settings and secrets, generated on the first install — keep it |
| `key/` | your licence file, and `scansuite-secrets.env` (owned by root): the keys that decrypt the credentials stored in the database. It is made on the first start; back it up with the database (`./scansuite --backup-secrets`), which is unreadable in part without it |
| `backups/` | where `./scansuite --backup-db` and `--backup-secrets` write when given no other place. Updates never touch it |
| `docker-compose.yml` | the services. The release is `SCANSUITE_TAG` in `.env`, not a line here. A change you make is merged into each new release (see Upgrading) |
| `docker-compose.local.yml` | optional, yours: what this host changes, e.g. `web: ports: ["127.0.0.1:5000:5000"]` behind its own reverse proxy. Updates never touch it and every start includes it — the surest place for a change that must survive any release |
| `services/nginx/certs/` | the TLS certificate nginx serves and its key — a self-signed pair created at install; replace both with your own; updates keep the pair |
| `images.d/` | the platform images (nginx, Redis, PostgreSQL, SeaweedFS) this release pulls besides its own |
| `RELEASE` | which release this is, and what it was built from |
