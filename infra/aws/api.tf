# ---------------------------------------------------------------------------
# Order API: API Gateway HTTP API -> Lambda (Python 3.12, arm64)
# ---------------------------------------------------------------------------

data "archive_file" "api" {
  type        = "zip"
  output_path = "${path.module}/.build/order-api.zip"

  source {
    content  = file("${path.module}/../../app/api/aws/handler.py")
    filename = "handler.py"
  }
  source {
    content  = file("${path.module}/../../app/api/common/pricing.py")
    filename = "pricing.py"
  }
  source {
    content  = file("${path.module}/../../app/menu/menu.json")
    filename = "menu.json"
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "${local.name}-order-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Least privilege: write-only to the two tables, its own log group, X-Ray.
data "aws_iam_policy_document" "api" {
  statement {
    sid       = "WriteOrders"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.orders.arn, aws_dynamodb_table.contacts.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "least-privilege"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.name}-order-api"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "api" {
  function_name    = "${local.name}-order-api"
  role             = aws_iam_role.api.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      ORDERS_TABLE   = aws_dynamodb_table.orders.name
      CONTACTS_TABLE = aws_dynamodb_table.contacts.name
      LOG_LEVEL      = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.api.name
  }

  tags = { VantaDescription = "Frosty Irie order API - validates and prices and stores orders" }
}

resource "aws_apigatewayv2_api" "orders" {
  name          = "${local.name}-orders"
  protocol_type = "HTTP"
  description   = "Frosty Irie order API"

  cors_configuration {
    allow_origins = local.web_origins
    allow_methods = ["GET", "POST"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "routes" {
  for_each  = toset(["POST /orders", "GET /health"])
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-orders"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.orders.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      time      = "$context.requestTime"
      route     = "$context.routeKey"
      status    = "$context.status"
      latency   = "$context.responseLatency"
      userAgent = "$context.identity.userAgent"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/*"
}
