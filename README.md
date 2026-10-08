## Static and Dynamic Security Analysis with ScanSuite

ScanSuite is the vulnerability scanning orchestrator for the code (SAST), Infrastructure as Code (IACS), Dependency (SCA / OSS), Dynamic Analysis (DAST) as well as Infrastructure assessment security tools.

Follow to https://scansuite.gitbook.io/ for installation and usage details.

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

By default the application and DefectDojo are installed, without external
scanner containers. `install` and `update` take these options, and remember
them in `.env`, so a later `update` or `start` keeps to the same choice until
you give another:

```bash
./scansuite install <code> --all-scanners   # every external scanner
./scansuite install <code> --static-only    # only the static (code) scanners
./scansuite install <code> --dynamic-only   # only the dynamic and infrastructure scanners
./scansuite install <code> --no-dojo        # without DefectDojo
./scansuite update --no-scanners --with-dojo  # back to the default
```

The options combine, e.g. `--static-only --no-dojo`. `--scanners=all|static|dynamic|none`
is the same choice in one word. Turning DefectDojo off stops it and keeps its data.

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

An installation made before 21 September 2026 runs `./scansuite update` twice:
its first run fetches the new `scansuite` command, the second applies the
release with it (the last line then names the licence code alone, not
`4.5-<code>`).

The first start of a release that encrypts stored credentials creates
`key/scansuite-secrets.env`. Copy it to where your database backups go:

```bash
sudo cp key/scansuite-secrets.env <backup location>
```

### What is on this host

| Path | |
|---|---|
| `.env` | settings and secrets, generated on the first install — keep it |
| `key/` | your licence file, and `scansuite-secrets.env` (owned by root): the keys that decrypt the credentials stored in the database. It is made on the first start; back it up with the database, which is unreadable in part without it |
| `docker-compose.yml` | the services. The release is `SCANSUITE_TAG` in `.env`, not a line here. A change you make is merged into each new release (see Upgrading) |
| `docker-compose.local.yml` | optional, yours: what this host changes, e.g. `web: ports: ["127.0.0.1:5000:5000"]` behind its own reverse proxy. Updates never touch it and every start includes it — the surest place for a change that must survive any release |
| `services/nginx/certs/` | the TLS certificate nginx serves — replace with your own; updates keep it |
| `scanners.d/` | the scanner images this release pulls |
| `RELEASE` | which release this is, and what it was built from |
