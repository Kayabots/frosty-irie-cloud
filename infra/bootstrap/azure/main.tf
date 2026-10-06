terraform {
  required_version = ">= 1.10.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Local state on first run; migrate into the storage account it creates.
  backend "azurerm" {}
}

provider "azurerm" {
  storage_use_azuread = true
  features {}
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "owner_email" {
  type = string
}

variable "github_repository" {
  description = "owner/repo trusted through GitHub OIDC."
  type        = string
}

variable "assign_regulatory_initiatives" {
  description = "Also assign the built-in ISO 27001 and NIST SP 800-53 Rev.5 initiatives (audit only, free)."
  type        = bool
  default     = true
}

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  tags = {
    Project            = "frostyirie"
    Environment        = "shared"
    ManagedBy          = "terraform"
    Layer              = "bootstrap-governance"
    DataClassification = "internal"
    VantaOwner         = var.owner_email
  }
}

# Terraform state -------------------------------------------------------------
resource "azurerm_resource_group" "state" {
  name     = "rg-frostyirie-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  name                              = "fitfstate${random_string.suffix.result}"
  resource_group_name               = azurerm_resource_group.state.name
  location                          = azurerm_resource_group.state.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  infrastructure_encryption_enabled = true
  default_to_oauth_authentication   = true

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
  tags = merge(local.tags, { VantaDescription = "Terraform state for Frosty Irie" })
}

resource "azurerm_role_assignment" "me_state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "state" {
  #checkov:skip=CKV2_AZURE_21:State reads are covered by Entra ID sign-in and Activity Logs (EXC-008)
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
  depends_on            = [azurerm_role_assignment.me_state]
}

output "state_storage_account" {
  value = azurerm_storage_account.state.name
}
