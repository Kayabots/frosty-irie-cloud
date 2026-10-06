resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name  = "${var.project}-${var.environment}"
  short = "fi${var.environment}${random_string.suffix.result}" # storage accounts: 3-24 lowercase alnum
  tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    Repository         = "frosty-irie-cloud"
    Role               = "standby"
    DataClassification = "internal"
    Compliance         = "NIST-CSF/ISO27001/SOC2/SOX/GDPR"
    VantaOwner         = var.owner_email
    VantaNonProd       = var.environment == "prod" ? "false" : "true"
  }
  cors_origins = compact([var.primary_web_origin, trimsuffix(azurerm_storage_account.web.primary_web_endpoint, "/")])
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}-standby"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.15 # stays well inside the 5 GB/month free allowance
  tags                = local.tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Static website (standby copy of the site; also CloudFront's failover origin)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "web" {
  name                              = "${local.short}web"
  resource_group_name               = azurerm_resource_group.main.name
  location                          = azurerm_resource_group.main.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  account_kind                      = "StorageV2"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false # Entra ID only
  infrastructure_encryption_enabled = true
  default_to_oauth_authentication   = true

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = merge(local.tags, { VantaDescription = "Standby static website for Frosty Irie ordering" })
}

resource "azurerm_role_assignment" "deployer_web" {
  count                = var.deployer_object_id == "" ? 0 : 1
  scope                = azurerm_storage_account.web.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.deployer_object_id
}

resource "azurerm_storage_account_static_website" "web" {
  storage_account_id = azurerm_storage_account.web.id
  index_document     = "index.html"
  error_404_document = "index.html"
  depends_on         = [azurerm_role_assignment.deployer_web]
}

# ---------------------------------------------------------------------------
# Order API (standby): Linux Consumption Function App, Python 3.11
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "func" {
  name                            = "${local.short}fn"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # Documented exception (compliance/exceptions.md, EXC-001): the Consumption
  # host and zip deployment still need key access to its own runtime storage.
  #checkov:skip=CKV2_AZURE_40:EXC-001 Functions runtime storage needs shared key
  shared_access_key_enabled = true

  sas_policy {
    expiration_period = "01.00:00:00" # any SAS minted from the keys lives at most 1 day
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
  tags = merge(local.tags, {
    VantaDescription    = "Azure Functions runtime storage (no customer data)"
    ComplianceException = "EXC-001"
  })
}

resource "azurerm_service_plan" "func" {
  name                = "asp-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption: 1M executions/month free
  tags                = local.tags
}

resource "azurerm_linux_function_app" "api" {
  name                       = "func-${local.name}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.func.id
  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key
  https_only                 = true

  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  site_config {
    minimum_tls_version                    = "1.2"
    ftps_state                             = "Disabled"
    http2_enabled                          = true
    application_insights_connection_string = azurerm_application_insights.main.connection_string

    application_stack {
      python_version = "3.11"
    }

    cors {
      allowed_origins = local.cors_origins
    }
  }

  app_settings = {
    COSMOS_ENDPOINT                = azurerm_cosmosdb_account.main.endpoint
    COSMOS_DATABASE                = azurerm_cosmosdb_sql_database.main.name
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
  }

  lifecycle {
    # Code is deployed by GitHub Actions (Azure/functions-action), not Terraform.
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"], tags["hidden-link: /app-insights-resource-id"]]
  }

  tags = merge(local.tags, { VantaDescription = "Standby Frosty Irie order API" })
}

# ---------------------------------------------------------------------------
# Order data (standby): Cosmos DB free tier, keyless, continuous backup
# ---------------------------------------------------------------------------
resource "azurerm_cosmosdb_account" "main" {
  name                          = "cosmos-${local.name}-${random_string.suffix.result}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  offer_type                    = "Standard"
  kind                          = "GlobalDocumentDB"
  free_tier_enabled             = var.cosmos_free_tier
  local_authentication_disabled = true # Entra ID (managed identity) only
  minimal_tls_version           = "Tls12"
  automatic_failover_enabled    = false
  # Only ARM (Terraform, audited in Activity Log) may change databases/containers.
  access_key_metadata_writes_enabled = false

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
  }

  backup {
    type = "Continuous"
    tier = "Continuous7Days" # point-in-time restore, last 7 days
  }

  tags = merge(local.tags, {
    DataClassification    = "restricted-pii"
    VantaDescription      = "Standby order ledger and short-lived customer contacts"
    VantaContainsUserData = "true"
    VantaUserDataStored   = "name, phone number, delivery address or beach spot (contacts container, TTL 30 days)"
  })
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "frostyirie"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  throughput          = 400 # shared by both containers; free tier covers up to 1000 RU/s
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                = "orders"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/orderId"]
}

resource "azurerm_cosmosdb_sql_container" "contacts" {
  name                = "contacts"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/orderId"]
  default_ttl         = 2592000 # 30 days, matches DynamoDB TTL
}

locals {
  cosmos_data_contributor = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
}

resource "azurerm_cosmosdb_sql_role_assignment" "func" {
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_data_contributor
  principal_id        = azurerm_linux_function_app.api.identity[0].principal_id
  scope               = azurerm_cosmosdb_account.main.id
}

resource "azurerm_cosmosdb_sql_role_assignment" "deployer" {
  count               = var.deployer_object_id == "" ? 0 : 1
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_data_contributor
  principal_id        = var.deployer_object_id
  scope               = azurerm_cosmosdb_account.main.id
}
