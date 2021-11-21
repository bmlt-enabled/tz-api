provider "aws" {
  region  = "us-east-1"
  profile = "mvana"
}

terraform {
  backend "s3" {
    bucket         = "mvana-account-terraform"
    dynamodb_table = "mvana-account-terraform"
    key            = "tz-api.tfstate"
    region         = "us-east-1"
    profile        = "mvana"
  }
}

variable "google_api_key" {
  type = string
}

resource "aws_lambda_function" "tz_api" {
  function_name    = "tz_api"
  filename         = "../lambda.zip"
  source_code_hash = filebase64sha256("../lambda.zip")
  handler          = "tz_api.handler"
  runtime          = "python3.8"
  role             = aws_iam_role.tz_api.arn

  environment {
    variables = {
      GOOGLE_API_KEY = var.google_api_key
    }
  }
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tz_api" {
  name               = "tz_api"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "tz_api" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_cloudwatch_log_group" "tz_api" {
  name              = "/aws/lambda/${aws_lambda_function.tz_api.function_name}"
  retention_in_days = 14
}

resource "aws_iam_policy" "tz_api" {
  name        = "lambda_logging"
  path        = "/"
  description = "tz_api"
  policy      = data.aws_iam_policy_document.tz_api.json
}

resource "aws_iam_role_policy_attachment" "tz_api" {
  role       = aws_iam_role.tz_api.name
  policy_arn = aws_iam_policy.tz_api.arn
}

resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.tz_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_api_gateway_rest_api" "tz_api" {
  name        = "tz_api"
  description = "tz_api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.tz_api.id
  parent_id   = aws_api_gateway_rest_api.tz_api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.tz_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.tz_api.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.tz_api.invoke_arn
}

resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.tz_api.id
  resource_id   = aws_api_gateway_rest_api.tz_api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.tz_api.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method

  integration_http_method = "GET"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.tz_api.invoke_arn
}

resource "aws_api_gateway_deployment" "example" {
  depends_on = [
    aws_api_gateway_integration.lambda,
    aws_api_gateway_integration.lambda_root,
  ]

  rest_api_id = aws_api_gateway_rest_api.tz_api.id
  stage_name  = "test"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tz_api.function_name
  principal     = "apigateway.amazonaws.com"

  # The "/*/*" portion grants access from any method on any resource
  # within the API Gateway REST API.
  source_arn = "${aws_api_gateway_rest_api.tz_api.execution_arn}/*/*"
}

data "aws_route53_zone" "tz" {
  name = "tz.bmltenabled.org."
}

resource "aws_acm_certificate" "tz" {
  domain_name       = "api.tz.bmltenabled.org"
  validation_method = "DNS"
}

resource "aws_route53_record" "tz_validation" {
  for_each = {
    for dvo in aws_acm_certificate.tz.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.tz.zone_id
}

resource "aws_acm_certificate_validation" "tz" {
  certificate_arn         = aws_acm_certificate.tz.arn
  validation_record_fqdns = [for record in aws_route53_record.tz_validation : record.fqdn]
}

resource "aws_route53_record" "tz" {
  name    = aws_api_gateway_domain_name.tz.domain_name
  type    = "A"
  zone_id = data.aws_route53_zone.tz.id

  alias {
    evaluate_target_health = true
    name                   = aws_api_gateway_domain_name.tz.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.tz.regional_zone_id
  }
}

resource "aws_api_gateway_domain_name" "tz" {
  regional_certificate_arn = aws_acm_certificate_validation.tz.certificate_arn
  domain_name              = aws_acm_certificate.tz.domain_name

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "tz" {
  api_id      = aws_api_gateway_rest_api.tz_api.id
  stage_name  = aws_api_gateway_deployment.example.stage_name
  domain_name = aws_api_gateway_domain_name.tz.domain_name
}

output "base_url" {
  value = aws_api_gateway_deployment.example.invoke_url
}
