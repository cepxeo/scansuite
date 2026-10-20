## Static and Dynamic Security Analysis with ScanSuite

ScanSuite is the vulnerability scanning orchestrator for the code (SAST), Infrastructure as Code (IACS), Dependency (SCA / OSS), Dynamic Analysis (DAST) as well as Infrastructure assessment security tools.

See https://scansuite.eu/documentation for installation and usage details.

### Installing

Copy the licence file you were sent (`<name>_<code>.lic`) next to `services/scansuite.sh`
and run it, or, in a checkout of this repository:

```bash
cp <name>_<code>.lic key/
./scansuite install <code>
```

### Deploying on Microsoft Azure instead

`azure/` deploys ScanSuite Teams into your own Azure subscription on Azure
Container Apps, with managed PostgreSQL, storage and Key Vault and no server to
look after. It covers static analysis. See [azure/README.md](azure/README.md)
for how to deploy it, use it and tear it down.

### Deploying on Google Cloud instead

`gcp/` deploys ScanSuite Teams into your own Google Cloud project on Cloud Run,
with Cloud SQL, Memorystore, Cloud Storage and Secret Manager and no server to
look after. It covers static analysis. See [gcp/README.md](gcp/README.md) for
how to deploy it, use it and tear it down.

### Choosing what is installed

By default only the application is installed, without DefectDojo or external
scanner containers. `install` and `update` take these options, and remember
them in `.env`, so a later `update` or `start` keeps to the same choice until
you give another:

```bash
./scansuite install <code> --all-scanners   # every external scanner
./scansuite install <code> --static-only    # only the static (code) scanners
./scansuite install <code> --dynamic-only   # only the dynamic and infrastructure scanners
./scansuite install <code> --with-dojo      # with DefectDojo as well
./scansuite update --with-dojo              # add DefectDojo to a running installation
./scansuite update --no-scanners --no-dojo  # back to the default
```

The options combine, e.g. `--static-only --with-dojo`. `--scanners=all|static|dynamic|none`
is the same choice in one word. Turning DefectDojo off stops it and keeps its data.
An installation that already runs DefectDojo keeps it on `update`.

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
./scansuite dojo password       # read or change the DefectDojo password
./scansuite --backup-db         # both databases into a zip (see Backing up and restoring)
./scansuite --backup-secrets    # .env and key/ into a password-protected zip
./scansuite uninstall           # stop and remove the boot service
```

### Upgrading

```bash
./scansuite update
```

That fetches this repository, pulls the images for your licence and restarts
only the services that changed. Your settings in `.env` and your files in
`key/` are kept; placeholder passwords left in `.env` are replaced with
generated ones, and the database is given the new one.

What you changed in the configuration the release ships — `docker-compose.yml`,
`compose.d/`, `services/nginx/` (the certificate too) and `defectdojo/` — is
kept as well: the update merges your change into the new release's file, so
your lines and the release's new ones are both there, and says
`Kept this host's changes to: …`. Two cases it cannot merge, and says so:
the release changed the very lines you changed, or the services no longer load
with your change. The release's file is then put in place and yours is saved
in a `.replaced-<date>` directory next to it, with the change alone as
`<file>.patch`; apply it again by hand, or move it to
`docker-compose.local.yml`, which no release ever touches. Any other release
file that differs on the host (the `scansuite` command, the scanner lists) is
replaced, with a copy in the same directory.

Your own TLS certificate in `services/nginx/certs/` is kept together with its
key: when you changed either file, the update puts both back as they were.
The user who runs the update must be able to read them; a key copied there
with `sudo cp` belongs to root, and the update stops and says to run
`sudo chown $USER: services/nginx/certs/*.pem`. If `key.pem` is not the key
of `cert.pem`, nginx cannot start, so the update puts the release's
self-signed pair in place and keeps yours in a `.replaced-<date>` directory.

An installation made before 21 September 2026 runs `./scansuite update` twice:
its first run fetches the new `scansuite` command, the second applies the
release with it (the last line then names the licence code alone, not
`4.5-<code>`).

### Backing up and restoring

```bash
./scansuite --backup-db                 # the ScanSuite and DefectDojo databases
./scansuite --backup-secrets            # .env and key/, behind a password
./scansuite --restore-db <zip>
./scansuite --restore-secrets <zip>
```

Each backup is one zip, written to `backups/` in the installation directory
unless you name a file or a directory after the command. Copy it off the host:
a backup that exists only on the disk it protects is not one.

**The databases.** `--backup-db` dumps both databases while everything keeps
running. `--with-files` adds what the databases point to — scan artifacts and
reports, DefectDojo uploads — and stops the artifact store while they are
copied; without it a restore brings back every finding, but not the stored
reports. `--encrypt` puts the zip behind a generated password, and `--no-dojo`
leaves DefectDojo out.

`--restore-db <zip>` replaces the databases with the ones in the zip. It asks
first, saves the databases as they are to `backups/before-restore-<date>.zip`,
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
(repository tokens, scanner and AI provider keys) cannot be read, and
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
| `services/nginx/certs/` | the TLS certificate nginx serves and its key — replace both with your own; updates keep the pair |
| `scanners.d/` | the scanner images this release pulls |
| `RELEASE` | which release this is, and what it was built from |
