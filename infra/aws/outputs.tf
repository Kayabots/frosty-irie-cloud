output "website_url" {
  description = "Primary website (CloudFront)."
  value       = "https://${aws_cloudfront_distribution.web.domain_name}"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

output "web_bucket" {
  value = aws_s3_bucket.web.bucket
}

output "api_url" {
  description = "Order API base URL (primary)."
  value       = aws_apigatewayv2_api.orders.api_endpoint
}

output "orders_table" {
  value = aws_dynamodb_table.orders.name
}

output "contacts_table" {
  value = aws_dynamodb_table.contacts.name
}

output "backup_vault" {
  value = try(aws_backup_vault.main[0].name, null)
}
