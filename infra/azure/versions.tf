terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial config from backend.hcl, created by infra/bootstrap/azure.
  backend "azurerm" {}
}

provider "azurerm" {
  # Subscription comes from ARM_SUBSCRIPTION_ID (OIDC in CI, `az login` locally).
  storage_use_azuread = true # data-plane via Entra ID; storage account keys stay unused

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}
