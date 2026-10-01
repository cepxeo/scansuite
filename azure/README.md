# ScanSuite Teams on Microsoft Azure

This folder deploys ScanSuite Teams into your own Azure subscription with
Terraform. It uses **Azure Container Apps** and managed services, so there is
no virtual machine to patch. One command builds everything and one command
removes it:

```bash
./deploy.sh     # build or update the installation
./destroy.sh    # delete it, database included
```

To install ScanSuite on your own Linux server instead, use `../README.md`.

**What runs where**

```
 Your browser --HTTPS--> Container Apps ingress (your IP ranges only, managed TLS)
                                   |
   Container Apps environment (inside its own virtual network)
     web            the user interface and API
     worker-admin   housekeeping, schedules, recovery of interrupted scans
     celery-beat    the scheduler
     worker-poc     sandbox for AI proof-of-concept checks (starts on demand)
     redis          the task queue
     scan job       one container per scan, 4 vCPU / 8 GiB, gone when the scan ends
     migrate job    database schema updates, run by deploy.sh
                                   |
   PostgreSQL 16 (private)   Blob Storage (artifacts)   Key Vault (secrets)
   Container Registry (your copy of the images)   Log Analytics (logs, alerts)
```

All of it lives in **one resource group** that the deployment creates. Secrets
are generated on first deploy and kept in Key Vault. The database can be
reached only from inside the virtual network, and the artifact storage only
from the Container Apps subnet, with no storage keys.

**Scope: static analysis.** Container Apps has no Docker daemon, so the scanners
that run as separate containers do not run here. That covers dynamic web
scanning (DAST) and infrastructure scanning. Code (SAST), dependency (SCA),
Infrastructure-as-Code, secrets and AI code analysis all work. For dynamic
scans, install on a Linux server (`../README.md`).

---

## 1. Before you start

**An Azure subscription, and your role on it.** You need **Owner**, or
**Contributor** together with **Role Based Access Control Administrator**. The
deployment creates managed identities, a custom role and role assignments, so
Contributor alone is not enough.

**The tools**, on Linux, macOS, or Windows with WSL or Git Bash:

| Tool | Version | Install |
|---|---|---|
| Azure CLI (`az`) | 2.60 or newer | https://learn.microsoft.com/cli/azure/install-azure-cli |
| Terraform | 1.6 or newer | https://developer.hashicorp.com/terraform/install |
| git, bash | any recent | usually installed already |

**From your ScanSuite delivery:**

- the **licence file**, named `<name>_<code>.lic`. The `<code>` part is your
  licence code, and the images you deploy are tagged with it.
- the **registry user name and access token**, used to copy the ScanSuite
  images into your subscription.

**Your public IPv4 address or ranges**, the ones allowed to open the web UI.
The web UI is reached over IPv4, so ask for the IPv4 address explicitly; many
connections would otherwise report an IPv6 one:

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
cd scansuite/azure
```

**Sign in to Azure** and pick the subscription:

```bash
az login
```

```bash
az account list -o table
```

**Write your settings.** Copy the example file and edit the copy:

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Setting | What to put |
|---|---|
| `subscription_id` | The subscription ID from `az account list`. |
| `location` | The Azure region, such as `germanywestcentral`, `swedencentral` or `northeurope`. |
| `resource_group_name` | A new resource group name. The deployment creates it, so it must not already exist. |
| `web_allowed_cidrs` | Your address or ranges, such as `["203.0.113.10/32", "198.51.100.0/24"]`. |
| `image_tag` | Your licence code, the `<code>` in `<name>_<code>.lic`. |
| `alert_email` | Optional. An address for alerts on errors, failed scans and database load. |

All other settings have working defaults. Each one is described in
`terraform.tfvars.example` and `variables.tf`.

**Give the image credentials to this shell.** They are used only to copy the
images and are never saved:

```bash
export DOCKERHUB_USERNAME='<registry user name>'
```

```bash
export DOCKERHUB_TOKEN='<registry access token>'
```

If Docker on this machine already holds the images for your licence code (for
example from a server installation), `deploy.sh` pushes those local copies
instead of copying from the registry. Remove them first if they may be out of
date.

**Run the deployment:**

```bash
./deploy.sh
```

A first run takes **30 to 40 minutes**. Most of that is Azure building the
Container Apps environment. The script:

1. Checks your tools, your sign-in, the licence, and whether the region lets
   your subscription create PostgreSQL. It stops here, before creating
   anything, if something is missing.
2. Builds the platform: network, database, Key Vault, storage, registry, the
   Container Apps environment and Redis.
3. Copies the ScanSuite images into your registry. Your installation never
   pulls from the public internet at run time.
4. Starts the web UI and the workers, then runs the database migration.
5. Prints the outputs. `url` is the address of your installation.

When it ends with `Done`, the installation is running. Print the outputs again
at any time with:

```bash
terraform output
```

---

## 3. First sign-in

1. **Open the `url` output right away.** A new installation shows the
   **setup page**. There you create the first account and name your team. That
   account administers both the team and the whole installation. Whoever opens
   the page first gets this account, which is why `web_allowed_cidrs` should
   be set before you deploy.
2. **Sign in** with that account. The setup page is gone for good once the
   first account exists.
3. **Configure an AI provider**, which the AI code analysis needs:
   - For every team: the **System AI** card under **System Settings →
     Shared services**.
   - For one team only: **Teams → AI → AI provider**.

   For **Azure OpenAI**, choose the OpenAI provider and set the API endpoint to
   your resource's v1 address, `https://<resource>.openai.azure.com/openai/v1`,
   with its API key. Use a deployment name as the model name.
4. **Invite your colleagues** from **Members** in the user menu (top right).
   To use single sign-on, connect your identity provider under
   **System Settings → Sign-in and access**.

---

## 4. Use

**Scan code.** Create a product, point it at a git repository, or upload an
archive, and start a scan. Each scan runs in its own container, so several
scans run side by side without slowing the UI. The user guide is at
https://scansuite.gitbook.io/.

**Scan from CI.** Create a token on the team's settings page, in the
**Automation and API tokens** card, and run the pipeline client `scansuite-ci`
(the `appsec4u/scansuite-ci:1` image, or `/ci/scansuite-ci.py` from your
installation). It starts SAST, DAST and infrastructure scans, waits for them and
fails the build on what they find. For GitLab, include the template your
installation publishes at `/ci/scansuite.gitlab-ci.yml`. The user guide's CI/CD
chapter has the details.

**Private git servers and AI endpoints.** Outbound traffic leaves from the
environment's address, which can change. If your git server or AI endpoint
allows only listed addresses, set `enable_nat_gateway = true` and re-run
`./deploy.sh`. The `egress_ip` output is then the fixed address to allow.

**Interrupted scans recover by themselves.** If Azure stops a scan's container
part-way through, the scan shows no progress for 90 minutes and is then started
again automatically, usually within two hours of the interruption. AI analysis
continues from its last saved stage, not from the beginning.

---

## 5. Day-to-day operation

**Change a setting.** Edit `terraform.tfvars` and re-run `./deploy.sh`.
Re-running is always safe: Terraform changes only what differs, and while the
images stay the same, scans that are running carry on.

**Update to a new release.** When you receive new images, and with them a new
licence:

1. Put the new `.lic` file in `../key/` and remove the old one.
2. Set `image_tag` to the new licence code.
3. Get the newest deployment files with `git pull` in the repository folder.
4. Run `./deploy.sh`.

The apps move to the new images and the database migration runs. Your data
stays, but the migration cancels any scan still running, so update when no
scan is in progress. If you are told that the images for your current code
were rebuilt, just re-run `./deploy.sh`: it always deploys the image it has
just copied, even under an unchanged tag, and treats it as a new release.

**Your address changed and the UI no longer opens.** Update
`web_allowed_cidrs` and re-run `./deploy.sh`.

**Logs.** In the Azure portal, open the Log Analytics workspace in the
resource group, choose **Logs**, and run:

```
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "scansuite-web"
| order by TimeGenerated desc
```

Use `scansuite-worker-admin` for background work, or
`ContainerJobName_s == "scansuite-sast"` for scans. Logs can take a few minutes
to arrive.

**Save money when nobody uses it.** Set `web_min_replicas = 0` and re-run
`./deploy.sh`. The first visit after a quiet period then waits about a minute.
You can also stop the database; Azure starts it again by itself after seven
days:

```bash
az postgres flexible-server stop -g <resource group> -n <postgres server>
```

```bash
az postgres flexible-server start -g <resource group> -n <postgres server>
```

The server name is the first part of the `postgres_fqdn` output.

**Backups.** PostgreSQL keeps automatic backups for seven days, and you can
restore to any point in that window from the Azure portal. Stored artifacts
keep previous versions for `artifact_retention_days`, 30 by default.

**Costs.** These are rough figures for the default `dev` settings, in USD per
month. Check your region in the Azure pricing calculator.

| Item | Approximate cost |
|---|---|
| Always-on containers (web, workers, scheduler, Redis: 2 vCPU, 4 GiB) | 120–160 |
| PostgreSQL `B_Standard_B1ms` with 32 GB | 20 |
| Log Analytics, capped at 1 GB a day | 0–70 |
| Registry, Key Vault, storage | about 10 |
| Scans, 4 vCPU and 8 GiB each | about 0.45 per scan-hour |
| NAT gateway, only if enabled | 35 plus traffic |

### Keep the Terraform state safe

`terraform.tfstate`, in this folder, is how Terraform knows what it built. It
also contains the generated passwords and your licence. Without it, `deploy.sh`
and `destroy.sh` cannot manage the installation.

- Keep it private, and back it up after every deploy.
- Never commit it to git. `.gitignore` already excludes it, along with
  `terraform.tfvars`.
- If more than one person will run the deployment, or a pipeline will, move the
  state to Azure Storage first. The steps are in `backend.tf.example`.

---

## 6. Tear down

```bash
./destroy.sh
```

The script asks you to type the resource group name, then deletes everything
this deployment created: the web UI, workers, database with **all scan data**,
storage, Key Vault, registry, logs and network. Azure also removes the
environment's helper group, `<resource group>-aca-managed`. It takes about
15 minutes.

For scripts, `./destroy.sh -y` skips the question.

**Check that it is all gone.** This should report that the resource group was
not found:

```bash
az group show -n <resource group>
```

If `destroy.sh` stops with `polling support for the Content-Type "" was not
implemented`, Azure has already deleted the app, job or environment the message
names, and Terraform tripped over the last status check. Run `./destroy.sh`
again to remove the rest; it can take two or three runs.

**What stays behind:**

- Your local `terraform.tfstate` and `terraform.tfvars`. Delete them if you will
  not deploy again, since the state holds secrets.
- With `environment = "prod"`, the Key Vault is kept soft-deleted for 7 days
  and cannot be purged early (purge protection). A new deployment uses new
  names, so this does not block a redeploy.

---

## 7. Production

For production use, set in `terraform.tfvars`:

```hcl
environment        = "prod"
postgres_sku       = "GP_Standard_D2ds_v5"
enable_nat_gateway = true
log_daily_quota_gb = -1
alert_email        = "secops@example.com"
```

`prod` adds:

- a zone-redundant database with a standby
- zone-redundant storage
- a Premium registry
- Key Vault purge protection
- a dedicated compute profile for the scans, whose disk is not shared with
  other tenants

Expect several hundred USD a month more than `dev`.

---

## 8. Troubleshooting

**`PostgreSQL Flexible Server 16 is not available to this subscription in
<region>`.** Some subscription types, Visual Studio subscriptions among them,
are barred from PostgreSQL in some regions. Pick another `location`, such as
`swedencentral`, `northeurope` or `francecentral`, and run again.

**`ManagedEnvironmentCapacityHeavyUsageError` / `AKS is experiencing heavy
usage in region <region>`.** Azure has no room for a new Container Apps
environment in that region at the moment. Azure keeps the half-made
environment in a `Failed` state, and Terraform does not know about it, so delete
it before trying again:

```bash
az containerapp env delete -g <resource group> -n scansuite-env --yes
```

Then run `./deploy.sh` again later. If the region stays full, run
`./destroy.sh`, set another `location` and deploy again.

**`no licence for image tag <code>`.** Put your `.lic` file in `../key/` and
make sure `image_tag` matches its code. If the folder holds several licences,
set `pyarmor_license_file` to the one you want.

**`could not import docker.io/appsec4u/...`.** The registry credentials are
missing or wrong. Export `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in the same
shell and run `./deploy.sh` again. Also check that `image_tag` is your licence
code.

**The deployment finished, but the page does not load or shows an error.**

- Check that your current address is in `web_allowed_cidrs`.
- Check the `scansuite-web` log (section 5). A licence error there means the
  licence and `image_tag` do not belong together.
- On the very first deploy, wait two minutes: the apps start after the
  migration.

**The URL opens the sign-in page, not the setup page.** Someone has already
created the first account. If that was not you, run `./destroy.sh` and deploy
again with a tighter `web_allowed_cidrs`.

**`migration ... ended Failed`.** The message names the execution. Its log is
in Log Analytics:

```
ContainerAppConsoleLogs_CL | where ContainerGroupName_s startswith "<execution>"
```

Fix the cause and run `./deploy.sh` again. The migration is safe to repeat.

**`Provider produced inconsistent result after apply`**, after deleting a
deployment and re-creating one with the **same** resource group name. Azure
still returns old answers about the deleted resources for a while. Either use
a new `resource_group_name`, or wait 15 minutes and run `./deploy.sh` again.

**`terraform init` fails with a connection error.** `deploy.sh` retries three
times. If it still fails, a proxy or firewall is blocking
`registry.terraform.io` or `management.azure.com`.

**Anything else.** Run `./deploy.sh` again first: every step is safe to
repeat. If the error remains, send us the full output together with
`terraform version` and `az version`.
