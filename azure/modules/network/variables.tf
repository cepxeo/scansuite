variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "vnet_cidr" { type = string }
variable "aca_subnet_cidr" { type = string }
variable "postgres_subnet_cidr" { type = string }

variable "enable_nat_gateway" { type = bool }
