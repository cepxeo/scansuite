# ScanSuite Teams on Google Cloud

This folder deploys ScanSuite Teams into your own Google Cloud project with
Terraform. It uses **Cloud Run** and managed services, so there is no virtual
machine to patch. One command builds everything and one command removes it:

```bash
./deploy.sh     # build or update the installation
./destroy.sh    # delete it, database included
```

To install ScanSuite on your own Linux server instead, use `../README.md`.

**What runs where**

```
 Your browser --HTTPS--> external load balancer + Cloud Armor (your IP ranges only)
                                   |
   Cloud Run, attached to its own VPC
     web            the user interface and API
     worker-admin   housekeeping, schedules, recovery of interrupted scans
     celery-beat    the scheduler
     worker-poc     sandbox for AI proof-of-concept checks
     scan job       one execution per scan, 4 vCPU / 16 GiB, gone when the scan ends
     migrate job    database schema updates, run by deploy.sh
                                   |
   Cloud SQL PostgreSQL 16 (private IP)   Memorystore Redis (TLS)   Cloud Storage
   Secret Manager   Artifact Registry   Cloud NAT (fixed outbound addresses)
```

Everything the deployment creates lives in one project. Passwords are
generated on first deploy and kept in Secret Manager. The database and Redis
have private addresses only. Images are read through your project's Artifact
Registry, pinned to exact digests.

**Scope: static analysis.** Cloud Run has no Docker daemon, so the scanners
that run as separate containers do not run here. That covers dynamic web
scanning (DAST) and infrastructure scanning. Code (SAST), dependency (SCA),
Infrastructure-as-Code, secrets and AI code analysis all work. For dynamic
scans, install on a Linux server (`../README.md`).

---

## 1. Before you start

**A Google Cloud project with billing**, where your account is **Owner** (or
Editor plus Project IAM Admin): the deployment creates service accounts and
grants them roles. A project of its own for ScanSuite is simplest.

**The tools**, on Linux, macOS, or Windows with WSL or Git Bash:

| Tool | Version | Install |
|---|---|---|
| Google Cloud CLI (`gcloud`) | recent | https://cloud.google.com/sdk/docs/install |
| Terraform | 1.6 or newer | https://developer.hashicorp.com/terraform/install |
| git, bash, curl | any recent | usually installed already |

**From your ScanSuite delivery:**

- the **licence file**, named `<name>_<code>.lic`. The `<code>` part is your
  licence code, and the images you deploy are tagged with it.
- the **registry user name and access token**. The images are private; your
  project's Artifact Registry uses these to read them.

**Your public IPv4 address or ranges**, the ones allowed to open the web UI:

```bash
curl -4 -s https://ifconfig.me
```

---

## 2. Deploy

**Get the files and add your licence.**

```bash
git clone https://github.com/cepxeo/scansuite.git
```

```bash
cp /path/to/<name>_<code>.lic scansuite/key/
```

```bash
cd scansuite/gcp
```

**Sign in to Google Cloud.** Terraform uses the second login (Application
Default Credentials):

```bash
gcloud auth login
```

```bash
gcloud auth application-default login
```

**Write your settings.** Copy the example file and edit the copy:

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Setting | What to put |
|---|---|
| `project_id` | Your project's ID (`gcloud projects list`). |
| `region` | The region, such as `europe-west3` (Frankfurt, the default) or `europe-west4`. With another region, also set `zones` and `primary_zone` to that region's zones, as in example D of section 3. |
| `image_tag` | Your licence code, the `<code>` in `<name>_<code>.lic`. |
| `dockerhub_username` | The registry user name sent with your licence. |
| `web_allowed_cidrs` | Your address or ranges, such as `["203.0.113.10/32"]`. Up to 10. |
| `timezone` | Your time zone, for scheduled scans, such as `Europe/Berlin`. |
| `alert_email` | Optional. An address for alerts. |

The defaults are sized for production, with a standby database and Redis. For
a trial, use the smaller sizes of example A in section 3: they roughly halve
the cost. Every other setting has a working default and is described in
`terraform.tfvars.example` and `variables.tf`.

**Give the registry token to this shell.** It is used to set up the registry
connection and kept in Secret Manager, readable only by Artifact Registry:

```bash
export TF_VAR_dockerhub_token='<registry access token>'
```

**Run the deployment:**

```bash
./deploy.sh
```

A first run takes **20 to 30 minutes**, most of it Cloud SQL. The script:

1. Checks your sign-in, the project and its billing, and the licence, before
   creating anything.
2. Creates the project's Artifact Registry and finds the exact images for your
   licence code.
3. Builds the network, database, Redis, storage and secrets, and runs the
   database migration.
4. Starts the Cloud Run services and the scan job, the load balancer and
   monitoring.
5. Prints the outputs. `url` is the address of your installation.

When it ends with `Done`, the installation is running. Print the outputs again
at any time with:

```bash
terraform output
```

---

## 3. Installation examples

`terraform.tfvars` for common installations. A, B and C are complete files:
copy the one that fits, put in your own values, and run `./deploy.sh` as in
section 2. D to G are the lines to add to one of them. The registry token always
comes from the shell, never from the file:

```bash
export TF_VAR_dockerhub_token='<registry access token>'
```

**A. A trial installation.** One project, small sizes, the UI open to one
address. About half the cost of the defaults (see the cost table in section 6),
and the setup a first evaluation needs:

```hcl
project_id  = "acme-scansuite-trial"
region      = "europe-west3"
environment = "dev"

image_tag          = "a1b2c3"
dockerhub_username = "<registry user name>"

web_allowed_cidrs = ["203.0.113.10/32"]
timezone          = "Europe/Berlin"

# Smaller than the production defaults, without standby copies.
cloudsql_ha      = false
cloudsql_tier    = "db-custom-1-3840"   # 1 vCPU, 3.75 GB
cloudsql_disk_gb = 20
redis_ha         = false
redis_memory_gb  = 1
poc_replicas     = 1
```

When the trial is over, remove everything, the stored scan artifacts included:

```bash
./destroy.sh --delete-artifacts
```

**B. A production installation.** The default sizes (a standby database and
Redis), your own domain with a Google-managed certificate, alerts, and
protection against accidental deletion:

```hcl
project_id  = "acme-scansuite"
region      = "europe-west3"
environment = "prod"

image_tag          = "a1b2c3"
dockerhub_username = "<registry user name>"

domain_name       = "scansuite.acme.example"
web_allowed_cidrs = ["198.51.100.0/24", "203.0.113.10/32"]   # office and VPN
timezone          = "Europe/Berlin"
alert_email       = "secops@acme.example"

deletion_protection = true
```

After the first deploy, point the domain's DNS `A` record at the
`load_balancer_ip` output. The certificate is issued once the name resolves,
which can take up to an hour; until then the browser reports a certificate
error. To have the deployment create the DNS zone too, add
`manage_dns = true` and delegate the zone at your registrar.

Before anyone else runs the deployment, move the Terraform state to a Cloud
Storage bucket (`backend.tf.example`).

**C. No access from the internet.** For a corporate network that reaches the
project's VPC over VPN or Interconnect. There is no load balancer, and the UI is
served on its Cloud Run address to callers inside the network only:

```hcl
project_id  = "acme-scansuite"
region      = "europe-west3"

image_tag          = "a1b2c3"
dockerhub_username = "<registry user name>"

internal_only = true
timezone      = "Europe/Berlin"
alert_email   = "secops@acme.example"
```

`web_allowed_cidrs` and `domain_name` are not used here. The `url` output is
the `https://...run.app` address. Your network has to resolve and route it
through Private Google Access; your network team sets that up once. The uptime
alert is left out, because Google's probers cannot reach an internal address.

**D. Another region.** Set the region and its zones together; the zones place
Redis and the database's standby:

```hcl
region       = "europe-west4"
zones        = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]
primary_zone = "europe-west4-b"
```

**E. A second installation in the same project**, such as a test installation
next to production. Give it its own prefix, so every resource gets its own
name, and deploy it from **its own copy** of this folder, so it has its own
Terraform state:

```bash
cp -r scansuite/gcp scansuite/gcp-test
```

```hcl
name_prefix = "scansuite-test"
```

Keep the prefix short: the artifact bucket is named
`<name_prefix>-artifacts-<project_id>`, at most 63 characters.

**F. Images from your own registry.** Where the installation must not read
Docker Hub at all. Copy the three images into a registry of your project once
per release, with the script in this folder (it needs Docker, signed in with the
registry user):

```bash
./scripts/mirror-images.sh acme-scansuite a1b2c3 europe-west3
```

It prints the three lines to add to `terraform.tfvars`:

```hcl
image_web        = "europe-west3-docker.pkg.dev/acme-scansuite/scansuite/teams-web:a1b2c3"
image_worker     = "europe-west3-docker.pkg.dev/acme-scansuite/scansuite/teams-worker:a1b2c3"
image_worker_poc = "europe-west3-docker.pkg.dev/acme-scansuite/scansuite/teams-worker-poc:a1b2c3"
```

`image_tag` and `dockerhub_username` are then not needed. The `scansuite`
repository is created by the first `./deploy.sh`; for a first installation, run
the script after that, then deploy again.

**G. Deploying again soon after a teardown.** Cloud SQL keeps a deleted
instance's name for about a week. To deploy again in that time, give the
database another name:

```hcl
cloudsql_name = "scansuite-pg-2"
```

---

## 4. First sign-in

1. **Open the `url` output right away.** Without a domain name the address is
   the load balancer's IP with a self-signed certificate, so your browser warns
   once; set `domain_name` and re-run `./deploy.sh` for a Google-managed
   certificate. A new installation shows the **setup page**, where you create
   the first account and name your team. That account administers both the team
   and the whole installation, and whoever opens the page first gets it - which
   is why `web_allowed_cidrs` should be set before you deploy.
2. **Sign in** with that account. The setup page is gone for good once the
   first account exists.
3. **Configure an AI provider**, which the AI code analysis needs:
   - For every team: **System Settings → System AI**.
   - For one team only: **Teams** in the sidebar opens the team's settings;
     use the **AI provider** card there.

   - **Vertex AI** needs no key: the installation's own service account
     (`scansuite-app`) already has the Vertex AI User role. Choose Vertex AI,
     enter your project ID, a region where the model is offered (such as
     `europe-west1`, or `global`) and the Claude model ID, and leave the
     credentials empty. Enable the Claude model for your project in **Vertex
     AI → Model Garden** first.
   - **Any OpenAI-compatible endpoint** works too, Azure OpenAI included:
     choose the OpenAI provider, set the endpoint and its API key. Scans reach
     the endpoint from the `scan_egress_ips` addresses.
4. **Invite your colleagues** from **Members** in the user menu (top right).
   To use single sign-on, connect your identity provider under
   **System Settings → Sign-in and access**.

---

## 5. Use

**Scan code.** Create a product, point it at a git repository, or upload an
archive, and start a scan. Each scan runs as its own Cloud Run job execution,
so several scans run side by side without slowing the UI. The user guide is at
https://scansuite.gitbook.io/.

Uploads through the browser are limited to **32 MiB** on Cloud Run. Scan larger
code from its git repository instead.

**Scan from CI.** Create a token on the team's settings page, in the
**Automation and API tokens** card. `../services/gitlab-examples/` has
ready-made GitLab CI jobs.

**Private git servers and AI endpoints.** Scans leave from fixed addresses, the
`scan_egress_ips` output. Allow those where your git server or AI endpoint
filters by address.

**Interrupted scans recover by themselves.** If a scan's execution stops
part-way, the scan shows no progress for 90 minutes and is then started again
automatically. AI analysis continues from its last saved stage.

---

## 6. Day-to-day operation

**Change a setting.** Edit `terraform.tfvars` and re-run `./deploy.sh`.
Re-running is always safe: Terraform changes only what differs, and while the
images stay the same, scans that are running carry on.

**Update to a new release.** When you receive new images, and with them a new
licence:

1. Put the new `.lic` file in `../key/` and remove the old one.
2. Set `image_tag` to the new licence code.
3. Get the newest deployment files with `git pull` in the repository folder.
4. Run `./deploy.sh`.

The services move to the new images and the database migration runs. Your data
stays, but the migration cancels any scan still running, so update when no
scan is in progress. If you are told the images for your current code were
rebuilt, just re-run `./deploy.sh`: it always deploys the newest image for your
code.

**Your address changed and the UI no longer opens.** Update
`web_allowed_cidrs` and re-run `./deploy.sh`.

**Logs.** The web application:

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="scansuite-web"' --limit 50 --format='value(textPayload)'
```

Scans:

```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="scansuite-sast"' --limit 100 --format='value(textPayload)'
```

Or open **Logging → Logs Explorer** in the Google Cloud console.

**Save money when nobody uses it.** Set `web_min_instances = 0` and re-run
`./deploy.sh`. The first visit after a quiet period then waits for a cold
start.

**Backups.** Cloud SQL takes a backup every night (14 are kept) and supports point-in-time
recovery over the last 7 days; restore from the console under **SQL → Backups**. Stored artifacts
keep previous versions for `artifact_retention_days`, 30 by default.

**Costs.** Rough figures, in USD per month. Check your region in the Google
Cloud pricing calculator.

| Item | Defaults | Trial (example A) |
|---|---|---|
| Cloud SQL | 200–250 (2 vCPU, 8 GB, high availability, 100 GB) | 50–70 |
| Memorystore | 150–200 (4 GB, high availability) | 35–45 |
| Cloud Run services (web always warm, admin, scheduler, two PoC workers) | 300–400 | 200–250 |
| Load balancer, Cloud Armor, Cloud NAT | 50–80 | 50–80 |
| Storage, Secret Manager, Artifact Registry, logs | 10–30 | 10–30 |
| Scans, 4 vCPU and 16 GiB each | about 0.5 per scan-hour | the same |

### Keep the Terraform state safe

`terraform.tfstate`, in this folder, is how Terraform knows what it built. It
also contains the generated passwords and your licence. Without it, `deploy.sh`
and `destroy.sh` cannot manage the installation.

- Keep it private, and back it up after every deploy.
- Never commit it to git. `.gitignore` already excludes it, along with
  `terraform.tfvars`.
- If more than one person will run the deployment, or a pipeline will, move the
  state to a Cloud Storage bucket first. The steps are in `backend.tf.example`.

---

## 7. Tear down

```bash
./destroy.sh
```

The script asks you to type the project ID, then deletes everything this
deployment created: the services, the database with **all scan data**, Redis,
secrets, the network and the load balancer. It takes about 15 minutes. For
scripts, `./destroy.sh -y` skips the question.

**The scan artifacts are kept** in their Cloud Storage bucket unless you pass
`--delete-artifacts`:

```bash
./destroy.sh --delete-artifacts
```

If a run stops part-way, run `./destroy.sh` again: it carries on with what is
left. One stop is normal: Cloud Run keeps a few addresses in the network for up
to two hours after its services are deleted, and only Google can release them,
so the network itself may have to wait. The script says so when that happens;
nothing left at that point is billed. Run it again later to finish.

**What stays behind**, which the script lists at the end:

- The artifact bucket, unless deleted as above. Before deploying again in the
  same project, either delete it or bring it back under Terraform with the
  `terraform import` command the script prints.
- Cloud SQL keeps the instance name reserved for about a week. To deploy again
  sooner, set `cloudsql_name` to another name.
- Your local `terraform.tfstate` and `terraform.tfvars`. Delete them if you will
  not deploy again, since the state holds secrets.

---

## 8. Production

For production use, keep the defaults (high-availability Cloud SQL and Redis)
and set in `terraform.tfvars`:

```hcl
environment         = "prod"
deletion_protection = true
domain_name         = "scansuite.example.com"
alert_email         = "secops@example.com"
```

With `deletion_protection = true`, Cloud SQL and the Cloud Run services refuse
to be deleted by anything but `./destroy.sh`, which releases them first.

To keep the UI off the internet entirely, set `internal_only = true`: there is
no load balancer, and the UI is reached over your VPC or corporate network
through the Cloud Run address.

---

## 9. Troubleshooting

**`billing is not enabled on <project>`.** Link a billing account to the
project in the console under **Billing**, or with `gcloud billing projects
link`, and run again.

**`no licence in ../key/`** or **`No licence to deploy with`.** Put your `.lic`
file in `../key/`. If the folder holds several licences, set
`pyarmor_license_file` to the one matching `image_tag`.

**`could not find teams-web:<code>`.** The registry could not read the image.
Check that `image_tag` is your licence code and that `dockerhub_username` and
`TF_VAR_dockerhub_token` are the ones sent with your licence, then run again.

**`The Cloud SQL instance already exists`**, deploying again after a teardown.
The deleted instance's name is reserved for about a week: set another
`cloudsql_name` (example G in section 3) and run again.

**A zone error for Redis or the database**, such as `location ... is not in
region`, after changing `region`. Set `zones` and `primary_zone` to the new
region's zones (example D in section 3).

**An API "has not been used in project ... or it is disabled".** The
deployment enables the APIs it needs, and a new API can take a few minutes to
become available. Run `./deploy.sh` again.

**The page does not load.** Check that your current address is in
`web_allowed_cidrs`. On a first deploy the load balancer can take 5 to 10
minutes to start answering, and a managed certificate (with `domain_name`)
stays in provisioning until the name resolves to the `load_balancer_ip` output.

**The URL opens the sign-in page, not the setup page.** Someone has already
created the first account. If that was not you, run `./destroy.sh` and deploy
again with a tighter `web_allowed_cidrs`.

**The migration fails.** Its log:

```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="scansuite-migrate"' --limit 50 --format='value(textPayload)'
```

Fix the cause and run `./deploy.sh` again; `MIGRATE=1 ./deploy.sh` runs the
migration even when the images have not changed.

**Anything else.** Run `./deploy.sh` again first: every step is safe to
repeat. If the error remains, send us the full output together with
`terraform version` and `gcloud version`.
