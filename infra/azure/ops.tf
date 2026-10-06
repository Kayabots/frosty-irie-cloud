# ---------------------------------------------------------------------------
# Diagnostics, alerts and cost guardrail
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_cosmosdb_account.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "ControlPlaneRequests"
  }
  enabled_log {
    category = "DataPlaneRequests"
  }
}

resource "azurerm_monitor_diagnostic_setting" "func" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_linux_function_app.api.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "FunctionAppLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "web_blob" {
  name                       = "to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.web.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}

resource "azurerm_monitor_action_group" "owner" {
  name                = "ag-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "frostyirie"

  email_receiver {
    name                    = "owner"
    email_address           = var.owner_email
    use_common_alert_schema = true
  }
  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "func_5xx" {
  name                = "func-5xx-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_linux_function_app.api.id]
  description         = "Standby order API returned server errors."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 2
  }

  action {
    action_group_id = azurerm_monitor_action_group.owner.id
  }
  tags = local.tags
}

resource "azurerm_consumption_budget_resource_group" "monthly" {
  name              = "budget-${local.name}"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.monthly_budget_usd
  time_grain        = "Monthly"

  # Azure requires the first day of the current month or later. The value is
  # set once at creation; ignore_changes below stops it drifting every month.
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.owner_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    contact_emails = [var.owner_email]
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
