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

### Choosing what is installed

By default every external scanner container and DefectDojo are downloaded.
`install` and `update` take these options, and remember them in `.env`, so a
later `update` or `start` keeps to the same choice until you give another:

```bash
./scansuite install <code> --no-scanners    # no external scanner containers
./scansuite install <code> --static-only    # only the static (code) scanners
./scansuite install <code> --dynamic-only   # only the dynamic and infrastructure scanners
./scansuite install <code> --no-dojo        # without DefectDojo
./scansuite update --all-scanners --with-dojo  # everything again
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
| `docker-compose.yml` | the services. Never edited by hand: the release is `SCANSUITE_TAG` in `.env` |
| `docker-compose.local.yml` | optional, yours: what this host changes, e.g. `web: ports: ["127.0.0.1:5000:5000"]` behind its own reverse proxy. Updates never touch it and every start includes it |
| `services/nginx/certs/` | the TLS certificate nginx serves — replace with your own |
| `scanners.d/` | the scanner images this release pulls |
| `RELEASE` | which release this is, and what it was built from |
