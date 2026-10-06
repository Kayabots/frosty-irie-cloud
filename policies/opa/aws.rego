# Pre-deployment policy checks for the AWS plan (terraform show -json).
# Run: conftest test plan.json --policy policies/opa --all-namespaces
# Each rule cites the controls it evidences; failures block the pipeline.
package terraform.aws

import rego.v1

required_tags := {"Project", "Environment", "ManagedBy", "VantaOwner", "DataClassification"}

taggable_types := {
	"aws_s3_bucket", "aws_dynamodb_table", "aws_lambda_function", "aws_cloudfront_distribution",
	"aws_apigatewayv2_api", "aws_cloudwatch_log_group", "aws_sns_topic", "aws_backup_vault", "aws_iam_role",
}

changes contains rc if {
	some rc in input.resource_changes
	startswith(rc.type, "aws_")
	not rc.change.actions == ["delete"]
	not rc.change.actions == ["no-op"]
}

by_type(t) := {rc | some rc in changes; rc.type == t}

# --- ID.AM-02 / ISO A.5.9: asset inventory tags (Vanta reads VantaOwner) ------
deny contains msg if {
	some rc in changes
	taggable_types[rc.type]
	tags := object.get(rc.change.after, "tags_all", {})
	missing := required_tags - {k | some k, _ in tags}
	count(missing) > 0
	msg := sprintf("[TAG-001] %s missing required tags %v (NIST ID.AM-02, ISO A.5.9)", [rc.address, missing])
}

# --- PR.AA-05 / ISO A.8.3: every bucket has a full public access block --------
deny contains msg if {
	some b in by_type("aws_s3_bucket")
	not has_pab(b.name)
	msg := sprintf("[S3-001] %s has no aws_s3_bucket_public_access_block (NIST PR.AA-05, SOC2 CC6.1)", [b.address])
}

has_pab(name) if {
	some p in by_type("aws_s3_bucket_public_access_block")
	p.name == name
	p.change.after.block_public_acls
	p.change.after.block_public_policy
	p.change.after.ignore_public_acls
	p.change.after.restrict_public_buckets
}

# --- PR.DS-01 / GDPR Art.32: encryption at rest on every bucket ---------------
deny contains msg if {
	some b in by_type("aws_s3_bucket")
	not has_sse(b.name)
	msg := sprintf("[S3-002] %s has no server-side encryption config (NIST PR.DS-01, ISO A.8.24)", [b.address])
}

has_sse(name) if {
	some s in by_type("aws_s3_bucket_server_side_encryption_configuration")
	s.name == name
}

# --- PR.DS-11 / RC.RP-03 / SOX: order data is recoverable ----------------------
deny contains msg if {
	some t in by_type("aws_dynamodb_table")
	not pitr_on(t)
	msg := sprintf("[DDB-001] %s must enable point-in-time recovery (NIST PR.DS-11, SOC2 A1.2)", [t.address])
}

pitr_on(t) if t.change.after.point_in_time_recovery[0].enabled == true

deny contains msg if {
	some t in by_type("aws_dynamodb_table")
	not t.change.after.server_side_encryption[0].enabled == true
	msg := sprintf("[DDB-002] %s must enable server-side encryption (NIST PR.DS-01)", [t.address])
}

deny contains msg if {
	some t in by_type("aws_dynamodb_table")
	not t.change.after.deletion_protection_enabled == true
	msg := sprintf("[DDB-003] %s must enable deletion protection (SOX ITGC change mgmt)", [t.address])
}

# --- GDPR Art.5(1)(e): tables holding personal data expire it ----------------
deny contains msg if {
	some t in by_type("aws_dynamodb_table")
	t.change.after.tags_all.VantaContainsUserData == "true"
	not t.change.after.ttl[0].enabled == true
	msg := sprintf("[GDPR-001] %s holds user data but has no TTL (GDPR storage limitation)", [t.address])
}

# --- PR.DS-02: HTTPS only at the edge -----------------------------------------
deny contains msg if {
	some d in by_type("aws_cloudfront_distribution")
	some cb in array.concat(d.change.after.default_cache_behavior, object.get(d.change.after, "ordered_cache_behavior", []))
	cb.viewer_protocol_policy == "allow-all"
	msg := sprintf("[CDN-001] %s allows plain HTTP (NIST PR.DS-02)", [d.address])
}

deny contains msg if {
	some d in by_type("aws_cloudfront_distribution")
	not has_headers_policy(d)
	msg := sprintf("[CDN-002] %s has no security response headers policy (ISO A.8.26)", [d.address])
}

# The policy ID is usually "known after apply" when both are created together.
has_headers_policy(d) if d.change.after.default_cache_behavior[0].response_headers_policy_id

has_headers_policy(d) if d.change.after_unknown.default_cache_behavior[0].response_headers_policy_id == true

# --- PR.AA-05: no public Lambda function URLs ---------------------------------
deny contains msg if {
	some u in by_type("aws_lambda_function_url")
	u.change.after.authorization_type == "NONE"
	msg := sprintf("[LAM-001] %s exposes an unauthenticated function URL", [u.address])
}

# --- DE.CM-09 / ISO A.8.15: log retention ------------------------------------
deny contains msg if {
	some g in by_type("aws_cloudwatch_log_group")
	r := object.get(g.change.after, "retention_in_days", 0)
	r < 30
	msg := sprintf("[LOG-001] %s retention %v days is below 30 (ISO A.8.15)", [g.address, r])
}

# --- PR.IR-04: API rate limiting ---------------------------------------------
deny contains msg if {
	some s in by_type("aws_apigatewayv2_stage")
	not s.change.after.default_route_settings[0].throttling_rate_limit
	msg := sprintf("[API-001] %s has no throttling (abuse / cost protection)", [s.address])
}

# --- PR.AA-05: IAM wildcards --------------------------------------------------
deny contains msg if {
	some p in by_type("aws_iam_role_policy")
	doc := json.unmarshal(p.change.after.policy)
	some st in doc.Statement
	st.Effect == "Allow"
	st.Action == "*"
	msg := sprintf("[IAM-001] %s grants Action \"*\" (least privilege)", [p.address])
}

# --- Cost guardrail: always-free DynamoDB capacity ----------------------------
warn contains msg if {
	some t in by_type("aws_dynamodb_table")
	t.change.after.billing_mode == "PROVISIONED"
	t.change.after.write_capacity > 10
	msg := sprintf("[COST-001] %s write capacity %v may exceed the 25 WCU always-free pool", [t.address, t.change.after.write_capacity])
}
