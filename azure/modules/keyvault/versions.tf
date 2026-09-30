terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
