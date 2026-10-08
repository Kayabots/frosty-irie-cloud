# ---------------------------------------------------------------------------
# GitHub Actions -> Azure with OIDC workload identity federation (no secrets)
#   frostyirie-gh-plan   : pull requests + main   -> Reader (+ state)
#   frostyirie-gh-deploy : "prod" environment only -> Contributor + constrained RBAC admin
# ---------------------------------------------------------------------------
locals {
  gh_issuer = "https://token.actions.githubusercontent.com"
  gh_aud    = ["api://AzureADTokenExchange"]
  # Built-in role GUIDs
  storage_blob_data_contributor = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}

resource "azuread_application" "plan" {
  display_name = "frostyirie-gh-plan"
  owners       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "plan" {
  client_id = azuread_application.plan.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "plan_pr" {
  #checkov:skip=CKV_AZURE_249:Subject is pinned to one repository and one ref/environment; audience is the Azure token exchange
  application_id = azuread_application.plan.id
  display_name   = "pull-requests"
  issuer         = local.gh_issuer
  audiences      = local.gh_aud
  subject        = "repo:${local.gh_sub_repo}:pull_request"
}

resource "azuread_application_federated_identity_credential" "plan_main" {
  #checkov:skip=CKV_AZURE_249:Subject is pinned to one repository and one ref/environment; audience is the Azure token exchange
  application_id = azuread_application.plan.id
  display_name   = "main-branch"
  issuer         = local.gh_issuer
  audiences      = local.gh_aud
  subject        = "repo:${local.gh_sub_repo}:ref:refs/heads/main"
}

resource "azurerm_role_assignment" "plan_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.plan.object_id
}

# Needed so `terraform plan` can refresh the Functions storage key (listKeys).
resource "azurerm_role_assignment" "plan_reader_data" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader and Data Access"
  principal_id         = azuread_service_principal.plan.object_id
}

resource "azurerm_role_assignment" "plan_state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor" # state lock uses blob leases
  principal_id         = azuread_service_principal.plan.object_id
}

resource "azuread_application" "deploy" {
  display_name = "frostyirie-gh-deploy"
  owners       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "deploy" {
  client_id = azuread_application.deploy.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "deploy_env" {
  #checkov:skip=CKV_AZURE_249:Subject is pinned to one repository and one ref/environment; audience is the Azure token exchange
  application_id = azuread_application.deploy.id
  display_name   = "prod-environment"
  issuer         = local.gh_issuer
  audiences      = local.gh_aud
  subject        = "repo:${local.gh_sub_repo}:environment:prod"
}

resource "azurerm_role_assignment" "deploy_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.deploy.object_id
}

# The workload stack grants itself one data-plane role on the website storage
# account. The ABAC condition lets this identity assign *only* that role.
resource "azurerm_role_assignment" "deploy_rbac_admin" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.deploy.object_id
  condition_version    = "2.0"
  condition            = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.storage_blob_data_contributor}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.storage_blob_data_contributor}}
     )
    )
  EOT
}

resource "azurerm_role_assignment" "deploy_state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.deploy.object_id
}

output "azure_tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}

output "gh_plan_client_id" {
  value = azuread_application.plan.client_id
}

output "gh_deploy_client_id" {
  value = azuread_application.deploy.client_id
}

output "github_sp_object_id" {
  description = "Pass to the workload stack as deployer_object_id."
  value       = azuread_service_principal.deploy.object_id
}
