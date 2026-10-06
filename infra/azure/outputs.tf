output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "website_url" {
  description = "Standby website (Azure Storage static website)."
  value       = azurerm_storage_account.web.primary_web_endpoint
}

output "website_host" {
  description = "Host only, for the CloudFront failover origin (AWS var standby_web_host)."
  value       = azurerm_storage_account.web.primary_web_host
}

output "web_storage_account" {
  value = azurerm_storage_account.web.name
}

output "function_app_name" {
  value = azurerm_linux_function_app.api.name
}

output "api_url" {
  description = "Standby order API base URL."
  value       = "https://${azurerm_linux_function_app.api.default_hostname}/api"
}

output "cosmos_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "cosmos_account" {
  value = azurerm_cosmosdb_account.main.name
}
