package terraform.azure_test

import rego.v1

import data.terraform.azure

tags := {"Project": "frostyirie", "Environment": "prod", "ManagedBy": "terraform", "VantaOwner": "o@x.cr", "DataClassification": "internal"}

rc(type, name, after) := {"address": sprintf("%s.%s", [type, name]), "type": type, "name": name, "change": {"actions": ["create"], "after": after}}

storage_ok := {"location": "eastus2", "tags": tags, "min_tls_version": "TLS1_2", "https_traffic_only_enabled": true, "allow_nested_items_to_be_public": false, "shared_access_key_enabled": false}

cosmos_ok := {"location": "eastus2", "tags": tags, "local_authentication_disabled": true, "minimal_tls_version": "Tls12", "backup": [{"type": "Continuous", "tier": "Continuous7Days"}]}

func_ok := {"location": "eastus2", "tags": tags, "https_only": true, "site_config": [{"ftps_state": "Disabled", "cors": [{"allowed_origins": ["https://d111.cloudfront.net"]}]}]}

test_compliant if {
	plan := {"resource_changes": [
		rc("azurerm_storage_account", "web", storage_ok),
		rc("azurerm_cosmosdb_account", "main", cosmos_ok),
		rc("azurerm_cosmosdb_sql_container", "contacts", {"default_ttl": 2592000}),
		rc("azurerm_linux_function_app", "api", func_ok),
		rc("azurerm_service_plan", "func", {"location": "eastus2", "tags": tags, "sku_name": "Y1"}),
	]}
	count(azure.deny) == 0 with input as plan
}

test_shared_key_needs_exception_tag if {
	bad := {"resource_changes": [rc("azurerm_storage_account", "fn", object.union(storage_ok, {"shared_access_key_enabled": true}))]}
	some msg in azure.deny with input as bad
	contains(msg, "STO-004")
	ok := {"resource_changes": [rc("azurerm_storage_account", "fn", object.union(storage_ok, {"shared_access_key_enabled": true, "tags": object.union(tags, {"ComplianceException": "EXC-001"})}))]}
	count(azure.deny) == 0 with input as ok
}

test_cosmos_keys_denied if {
	bad := {"resource_changes": [rc("azurerm_cosmosdb_account", "main", object.union(cosmos_ok, {"local_authentication_disabled": false}))]}
	some msg in azure.deny with input as bad
	contains(msg, "COS-001")
}

test_wrong_region_denied if {
	bad := {"resource_changes": [rc("azurerm_storage_account", "web", object.union(storage_ok, {"location": "westeurope"}))]}
	some msg in azure.deny with input as bad
	contains(msg, "LOC-001")
}

test_premium_plan_denied if {
	bad := {"resource_changes": [rc("azurerm_service_plan", "p", {"location": "eastus2", "tags": tags, "sku_name": "P1v3"})]}
	some msg in azure.deny with input as bad
	contains(msg, "COST-001")
}

test_cors_wildcard_denied if {
	f := object.union(func_ok, {"site_config": [{"ftps_state": "Disabled", "cors": [{"allowed_origins": ["*"]}]}]})
	bad := {"resource_changes": [rc("azurerm_linux_function_app", "api", f)]}
	some msg in azure.deny with input as bad
	contains(msg, "FN-003")
}

test_global_location_allowed if {
	plan := {"resource_changes": [rc("azurerm_monitor_action_group", "owner", {"location": "global", "tags": tags})]}
	count(azure.deny) == 0 with input as plan
}
