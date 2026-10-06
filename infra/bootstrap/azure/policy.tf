# ---------------------------------------------------------------------------
# Azure Policy: custom definitions from policies/azure/*.json, grouped into one
# initiative and assigned to the subscription. Built-in ISO 27001 / NIST 800-53
# initiatives add audit-only evidence that Vanta and Defender for Cloud surface.
# ---------------------------------------------------------------------------
locals {
  policy_dir   = "${path.module}/../../../policies/azure"
  policy_files = fileset(local.policy_dir, "fi-*.json")
  policies     = { for f in local.policy_files : trimsuffix(f, ".json") => jsondecode(file("${local.policy_dir}/${f}")) }
}

resource "azurerm_policy_definition" "custom" {
  for_each     = local.policies
  name         = each.key
  policy_type  = "Custom"
  mode         = each.value.properties.mode
  display_name = each.value.properties.displayName
  description  = each.value.properties.description
  metadata     = jsonencode(each.value.properties.metadata)
  parameters   = jsonencode(each.value.properties.parameters)
  policy_rule  = jsonencode(each.value.properties.policyRule)
}

resource "azurerm_policy_set_definition" "baseline" {
  name         = "fi-baseline"
  policy_type  = "Custom"
  display_name = "Frosty Irie security baseline"
  description  = "Deployment-consistency guardrails for the Frosty Irie standby environment."
  metadata     = jsonencode({ category = "Frosty Irie", version = "1.0.0" })

  dynamic "policy_definition_reference" {
    for_each = azurerm_policy_definition.custom
    content {
      policy_definition_id = policy_definition_reference.value.id
      reference_id         = policy_definition_reference.key
    }
  }
}

resource "azurerm_subscription_policy_assignment" "baseline" {
  name                 = "fi-baseline"
  display_name         = "Frosty Irie security baseline"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_set_definition.baseline.id
  description          = "Assigned by infra/bootstrap/azure. Exceptions: compliance/exceptions.md"
  non_compliance_message {
    content = "Blocked by the Frosty Irie baseline. See compliance/exceptions.md to request an exception."
  }
}

data "azurerm_policy_set_definition" "iso27001" {
  count        = var.assign_regulatory_initiatives ? 1 : 0
  display_name = "ISO 27001:2013"
}

data "azurerm_policy_set_definition" "nist80053" {
  count        = var.assign_regulatory_initiatives ? 1 : 0
  display_name = "NIST SP 800-53 Rev. 5"
}

resource "azurerm_subscription_policy_assignment" "iso27001" {
  count                = var.assign_regulatory_initiatives ? 1 : 0
  name                 = "fi-iso27001"
  display_name         = "ISO 27001 (audit) - Frosty Irie"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = data.azurerm_policy_set_definition.iso27001[0].id
  location             = var.location
  enforce              = false # audit evidence only
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_subscription_policy_assignment" "nist80053" {
  count                = var.assign_regulatory_initiatives ? 1 : 0
  name                 = "fi-nist80053r5"
  display_name         = "NIST SP 800-53 Rev.5 (audit) - Frosty Irie"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = data.azurerm_policy_set_definition.nist80053[0].id
  location             = var.location
  enforce              = false
  identity {
    type = "SystemAssigned"
  }
}
