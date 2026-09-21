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

