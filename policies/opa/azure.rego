# Pre-deployment policy checks for the Azure plan (terraform show -json).
package terraform.azure

import rego.v1

allowed_locations := {"eastus", "eastus2", "centralus"}

required_tags := {"Project", "Environment", "ManagedBy", "VantaOwner", "DataClassification"}

changes contains rc if {
	some rc in input.resource_changes
	startswith(rc.type, "azurerm_")
	not rc.change.actions == ["delete"]
	not rc.change.actions == ["no-op"]
}

by_type(t) := {rc | some rc in changes; rc.type == t}

tagged_types := {
	"azurerm_resource_group", "azurerm_storage_account", "azurerm_cosmosdb_account",
	"azurerm_linux_function_app", "azurerm_service_plan", "azurerm_log_analytics_workspace",
}

deny contains msg if {
	some rc in changes
	tagged_types[rc.type]
	tags := object.get(rc.change.after, "tags", {})
	missing := required_tags - {k | some k, _ in tags}
	count(missing) > 0
	msg := sprintf("[TAG-001] %s missing required tags %v (NIST ID.AM-02, ISO A.5.9)", [rc.address, missing])
}

deny contains msg if {
	some rc in changes
	loc := object.get(rc.change.after, "location", "")
	loc != ""
	loc != "global" # region-less services such as Monitor action groups
	not allowed_locations[loc]
	msg := sprintf("[LOC-001] %s is in %s; allowed: %v (GDPR Art.44 data residency record)", [rc.address, loc, allowed_locations])
}

# --- Storage ------------------------------------------------------------------
deny contains msg if {
	some s in by_type("azurerm_storage_account")
	s.change.after.min_tls_version != "TLS1_2"
	msg := sprintf("[STO-001] %s must require TLS 1.2 (NIST PR.DS-02)", [s.address])
}

deny contains msg if {
	some s in by_type("azurerm_storage_account")
	not s.change.after.https_traffic_only_enabled == true
	msg := sprintf("[STO-002] %s must be HTTPS only (NIST PR.DS-02)", [s.address])
}

deny contains msg if {
	some s in by_type("azurerm_storage_account")
	s.change.after.allow_nested_items_to_be_public == true
	msg := sprintf("[STO-003] %s allows public blob containers (NIST PR.AA-05)", [s.address])
}

deny contains msg if {
	some s in by_type("azurerm_storage_account")
	s.change.after.shared_access_key_enabled == true
	not s.change.after.tags.ComplianceException
	msg := sprintf("[STO-004] %s enables shared keys without a recorded exception tag (ISO A.8.5)", [s.address])
}

# --- Cosmos DB ----------------------------------------------------------------
deny contains msg if {
	some c in by_type("azurerm_cosmosdb_account")
	not c.change.after.local_authentication_disabled == true
	msg := sprintf("[COS-001] %s must disable key auth; use Entra ID (ISO A.8.5, SOC2 CC6.1)", [c.address])
}

deny contains msg if {
	some c in by_type("azurerm_cosmosdb_account")
	not c.change.after.backup[0].type == "Continuous"
	msg := sprintf("[COS-002] %s must use continuous backup (NIST PR.DS-11, SOC2 A1.2)", [c.address])
}

deny contains msg if {
	some c in by_type("azurerm_cosmosdb_account")
	c.change.after.minimal_tls_version != "Tls12"
	msg := sprintf("[COS-003] %s must require TLS 1.2", [c.address])
}

deny contains msg if {
	some c in by_type("azurerm_cosmosdb_sql_container")
	c.name == "contacts"
	not c.change.after.default_ttl > 0
	msg := sprintf("[GDPR-001] %s holds contact data and needs a TTL (GDPR storage limitation)", [c.address])
}

# --- Functions ----------------------------------------------------------------
deny contains msg if {
	some f in by_type("azurerm_linux_function_app")
	not f.change.after.https_only == true
	msg := sprintf("[FN-001] %s must be HTTPS only", [f.address])
}

deny contains msg if {
	some f in by_type("azurerm_linux_function_app")
	f.change.after.site_config[0].ftps_state != "Disabled"
	msg := sprintf("[FN-002] %s must disable FTP/FTPS (NIST PR.PS-01)", [f.address])
}

deny contains msg if {
	some f in by_type("azurerm_linux_function_app")
	some origin in f.change.after.site_config[0].cors[0].allowed_origins
	origin == "*"
	msg := sprintf("[FN-003] %s allows CORS from any origin", [f.address])
}

# --- Cost guardrail -----------------------------------------------------------
deny contains msg if {
	some p in by_type("azurerm_service_plan")
	not p.change.after.sku_name in {"Y1", "FC1"}
	msg := sprintf("[COST-001] %s uses SKU %s; only consumption plans are allowed", [p.address, p.change.after.sku_name])
}
