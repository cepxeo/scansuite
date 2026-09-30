###############################################################################
# Where
###############################################################################

variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region. Germany West Central (Frankfurt) is the counterpart of europe-west3."
  type        = string
  default     = "germanywestcentral"
}

variable "name_prefix" {
  description = "Prefix for every resource name. Keep it short: storage account and Key Vault names are length-limited and global."
  type        = string
  default     = "scansuite"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.name_prefix))
    error_message = "3-12 lower-case letters and digits, starting with a letter (it becomes part of global names)."
  }
}

variable "environment" {
  description = "dev or prod. prod turns on HA PostgreSQL, deletion protection and purge protection."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "resource_group_name" {
  description = "Resource group for everything. Created by this configuration."
  type        = string
  default     = "rg-scansuite-dev"
}

###############################################################################
# Network
###############################################################################

variable "vnet_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "aca_subnet_cidr" {
  description = "Container Apps infrastructure subnet. /23 leaves room to scale; workload-profile environments accept /27 and up."
  type        = string
  default     = "10.40.0.0/23"
}

variable "postgres_subnet_cidr" {
  type    = string
  default = "10.40.2.0/28"
}

variable "enable_nat_gateway" {
  description = "Static egress IP for the workloads (what git hosts and model endpoints allowlist). Off in dev to save cost; the environment then egresses through its own address."
  type        = bool
  default     = false
}

variable "web_allowed_cidrs" {
  description = "Addresses allowed to reach the web UI through Container Apps ingress. Empty means open to the internet. Put your office or VPN ranges here."
  type        = list(string)
  default     = []
}

###############################################################################
# Workloads
###############################################################################

variable "deploy_workloads" {
  description = "Create the Container Apps (web, workers, jobs). Off builds the platform only - network, data, identity, registry, environment - which needs neither the licence nor the image."
  type        = bool
  default     = true
}

variable "image_registry" {
  description = "Where the ScanSuite images come from. deploy.sh imports them into the deployment's ACR, so the apps never pull from Docker Hub."
  type        = string
  default     = "docker.io/appsec4u"
}

variable "image_tag" {
  description = "Tag of teams-web, teams-worker and teams-worker-poc. Your licence code, the <code> of key/<name>_<code>.lic: the licence opens only the images of its own code."
  type        = string
}

variable "image_digests" {
  description = "teams-web / teams-worker / teams-worker-poc -> sha256 digest in the registry. deploy.sh writes these (images.auto.tfvars.json) after pushing, so a rebuild under the same tag still rolls every app to the new image; without a digest the tag is used."
  type        = map(string)
  default     = {}
}

variable "key_dir" {
  description = "Directory holding the PyArmor outer licence (*.lic). Defaults to ../key."
  type        = string
  default     = ""
}

variable "pyarmor_license_file" {
  description = "Licence file name inside key_dir, when it holds more than one."
  type        = string
  default     = ""
}

variable "worker_poc_installation_secrets" {
  description = "Give worker-poc SECRET_KEY and the wrapping keys. Only for images whose work_poc.py still calls ensure_secrets() (built before that call was removed), which do not start without them. Off withholds from the model-code sandbox the keys that decrypt team credentials."
  type        = bool
  default     = false
}

variable "timezone" {
  description = "TZ for the containers; celery-beat builds its schedule in it."
  type        = string
  default     = "Europe/Berlin"
}

variable "enable_static_scans" {
  type    = string
  default = "True"
}

variable "enable_dynamic_scans" {
  description = "Off: Container Apps has no Docker daemon, so the dynamic and infrastructure scanners, which run as containers of their own, cannot run."
  type        = string
  default     = "False"
}

variable "scan_cpu" {
  description = "vCPU per scan execution. Consumption allows at most 4."
  type        = number
  default     = 4
}

variable "scan_memory" {
  description = "Memory per scan execution. Consumption allows 2 GiB per vCPU, so 8Gi at 4 vCPU."
  type        = string
  default     = "8Gi"
}

variable "scan_timeout_seconds" {
  description = "replicaTimeout of the scan job. Matches the Celery task_time_limit of 48 h."
  type        = number
  default     = 172800
}

variable "web_min_replicas" {
  description = "1 keeps the UI warm. 0 between test sessions saves money; the first request then waits for a cold start."
  type        = number
  default     = 1
}

variable "web_max_replicas" {
  type    = number
  default = 2
}

###############################################################################
# Data
###############################################################################

variable "postgres_sku" {
  description = "B_Standard_B1ms allows about 50 connections, enough for a dev load; B_Standard_B2s about 430."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  type    = number
  default = 32768
}

variable "artifact_retention_days" {
  description = "How long overwritten or deleted artifact versions are kept."
  type        = number
  default     = 30
}

###############################################################################
# Observability
###############################################################################

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap. Keeps a noisy scan from eating a capped subscription; -1 removes the cap."
  type        = number
  default     = 1
}

variable "alert_email" {
  description = "Where alerts go. Empty creates no action group and no alerts."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
