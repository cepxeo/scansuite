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

`install`, `start-scansuite`, `services/reset-scansuite`, `defectdojo/reset-dojo`
and `defectdojo/dojo-password` still work: they call the commands above.

### Upgrading

```bash
./scansuite update
```

That fetches this repository, pulls the images for your licence and restarts
only the services that changed. Your `.env` and `key/` are never touched.

### What is on this host

| Path | |
|---|---|
| `.env` | settings and secrets, generated on the first install — keep it |
| `key/` | your licence file |
| `docker-compose.yml` | the services. Never edited by hand: the release is `SCANSUITE_TAG` in `.env` |
| `services/nginx/certs/` | the TLS certificate nginx serves — replace with your own |
| `scanners.d/` | the scanner images this release pulls |
| `RELEASE` | which release this is, and what it was built from |
