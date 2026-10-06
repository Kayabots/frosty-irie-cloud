package terraform.aws_test

import rego.v1

import data.terraform.aws

good_tags := {"Project": "frostyirie", "Environment": "prod", "ManagedBy": "terraform", "VantaOwner": "o@x.cr", "DataClassification": "internal"}

rc(type, name, after) := {"address": sprintf("%s.%s", [type, name]), "type": type, "name": name, "change": {"actions": ["create"], "after": after}}

compliant := {"resource_changes": [
	rc("aws_s3_bucket", "web", {"tags_all": good_tags}),
	rc("aws_s3_bucket_public_access_block", "web", {"block_public_acls": true, "block_public_policy": true, "ignore_public_acls": true, "restrict_public_buckets": true}),
	rc("aws_s3_bucket_server_side_encryption_configuration", "web", {}),
	rc("aws_dynamodb_table", "contacts", {
		"tags_all": object.union(good_tags, {"VantaContainsUserData": "true"}),
		"point_in_time_recovery": [{"enabled": true}], "server_side_encryption": [{"enabled": true}],
		"deletion_protection_enabled": true, "ttl": [{"enabled": true, "attribute_name": "expiresAt"}],
		"billing_mode": "PROVISIONED", "write_capacity": 5,
	}),
	rc("aws_cloudwatch_log_group", "api", {"tags_all": good_tags, "retention_in_days": 30}),
	rc("aws_apigatewayv2_stage", "default", {"default_route_settings": [{"throttling_rate_limit": 10}]}),
]}

test_compliant_plan_passes if {
	count(aws.deny) == 0 with input as compliant
}

test_public_bucket_denied if {
	bad := {"resource_changes": [rc("aws_s3_bucket", "leaky", {"tags_all": good_tags}), rc("aws_s3_bucket_server_side_encryption_configuration", "leaky", {})]}
	some msg in aws.deny with input as bad
	contains(msg, "S3-001")
}

test_missing_tags_denied if {
	bad := {"resource_changes": [rc("aws_sns_topic", "alerts", {"tags_all": {"Project": "x"}})]}
	some msg in aws.deny with input as bad
	contains(msg, "TAG-001")
}

test_pii_table_without_ttl_denied if {
	bad := {"resource_changes": [rc("aws_dynamodb_table", "contacts", {
		"tags_all": object.union(good_tags, {"VantaContainsUserData": "true"}),
		"point_in_time_recovery": [{"enabled": true}], "server_side_encryption": [{"enabled": true}],
		"deletion_protection_enabled": true, "ttl": [],
	})]}
	some msg in aws.deny with input as bad
	contains(msg, "GDPR-001")
}

test_no_pitr_denied if {
	bad := {"resource_changes": [rc("aws_dynamodb_table", "orders", {
		"tags_all": good_tags, "point_in_time_recovery": [{"enabled": false}],
		"server_side_encryption": [{"enabled": true}], "deletion_protection_enabled": true,
	})]}
	some msg in aws.deny with input as bad
	contains(msg, "DDB-001")
}

test_short_log_retention_denied if {
	bad := {"resource_changes": [rc("aws_cloudwatch_log_group", "x", {"tags_all": good_tags, "retention_in_days": 7})]}
	some msg in aws.deny with input as bad
	contains(msg, "LOG-001")
}

test_wildcard_iam_denied if {
	pol := json.marshal({"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})
	bad := {"resource_changes": [rc("aws_iam_role_policy", "x", {"policy": pol})]}
	some msg in aws.deny with input as bad
	contains(msg, "IAM-001")
}

test_deletes_are_ignored if {
	del := {"resource_changes": [{"address": "aws_s3_bucket.old", "type": "aws_s3_bucket", "name": "old", "change": {"actions": ["delete"], "after": null}}]}
	count(aws.deny) == 0 with input as del
}

test_headers_policy_known_after_apply_passes if {
	d := {
		"address": "aws_cloudfront_distribution.web", "type": "aws_cloudfront_distribution", "name": "web",
		"change": {
			"actions": ["create"],
			"after": {"tags_all": good_tags, "default_cache_behavior": [{"viewer_protocol_policy": "redirect-to-https"}]},
			"after_unknown": {"default_cache_behavior": [{"response_headers_policy_id": true}]},
		},
	}
	count(aws.deny) == 0 with input as {"resource_changes": [d]}
}
