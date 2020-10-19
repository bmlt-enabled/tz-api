provider "aws" {
  region  = "us-east-1"
  profile = "mvana"
}

terraform {
  backend "s3" {
    bucket  = "tomato-terraform-state-mvana"
    key     = "tz-api.tfstate"
    region  = "us-east-1"
    profile = "mvana"
  }
}

variable "google_api_key" {
  type = string
}

resource "aws_security_group" "tz_api" {
  name   = "tz_api"
  vpc_id = "vpc-0b06abcc49c87c31f"

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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

  vpc_config {
    security_group_ids = [aws_security_group.tz_api.id]
    subnet_ids         = ["subnet-08cea9c9b1562577a", "subnet-0610d9d763aa86fad"]
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

  integration_http_method = "GET"
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

output "base_url" {
  value = aws_api_gateway_deployment.example.invoke_url
}
