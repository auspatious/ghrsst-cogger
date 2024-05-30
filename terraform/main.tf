# Configure the AWS provider
provider "aws" {
  region = "us-west-2"
}

variable "destination_bucket_name" {
  description = "The name of the S3 bucket to store the output files"
  type        = string
  default     = "fake-test-bucket"
}

variable "image_tag" {
  description = "The image URL for the lambda docker image"
  type        = string
  default     = "TAG"
}

# Get the secret manager secret called earthdata-token
data "aws_secretsmanager_secret" "earthdata_token" {
  name = "earthdata-token"
}

# Retrieve the earthdata token... needs to be manually created
data "aws_secretsmanager_secret_version" "earthdata_token" {
  secret_id = data.aws_secretsmanager_secret.earthdata_token.id
}

# Set up a ECR repository
resource "aws_ecr_repository" "ghrsst" {
  name = "ghrsst-cogger"
}

# Set up a S3 bucket
resource "aws_s3_bucket" "ghrsst_bucket" {
  bucket = var.destination_bucket_name
}

# Create an SQS queue
resource "aws_sqs_queue" "ghrsst_queue" {
  name                       = "ghrsst-queue"
  delay_seconds              = 90
  max_message_size           = 2048
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 3
  visibility_timeout_seconds = 900 # 15 minutes
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ghrsst_queue_dead.arn
    maxReceiveCount     = 3
  })
}

# And a dead-letter queue
resource "aws_sqs_queue" "ghrsst_queue_dead" {
  name                      = "ghrsst-queue-dead"
  delay_seconds             = 90
  max_message_size          = 2048
  message_retention_seconds = 86400 # 1 day
  receive_wait_time_seconds = 10
}

# Set up a log group
resource "aws_cloudwatch_log_group" "ghrsst_log_group" {
  name              = "/aws/lambda/ghrsst-lambda"
  retention_in_days = 5
}

# Create a Lambda function
resource "aws_lambda_function" "ghrsst_lambda" {
  function_name = "ghrsst-lambda"
  role          = aws_iam_role.ghrsst_role.arn
  timeout       = 480   # 8 minutes
  memory_size   = 10240 # 10240 10 GB
  ephemeral_storage {
    size = 1536
  }

  # Run a dockerfile
  image_uri    = "${resource.aws_ecr_repository.ghrsst.repository_url}:${var.image_tag}"
  package_type = "Image"

  environment {
    variables = {
      EARTHDATA_TOKEN = data.aws_secretsmanager_secret_version.earthdata_token.secret_string,
      OUTPUT_LOCATION = "s3://${var.destination_bucket_name}/ghrsst/",
      CACHE_LOCAL     = "True"
    }
  }
}

# Create an IAM role for the Lambda function
resource "aws_iam_role" "ghrsst_role" {
  name = "ghrsst-data-writer-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# And a policy
resource "aws_iam_policy" "ghrsst_role_policy" {
  name   = "ghrsst-data-writer-policy"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "${aws_cloudwatch_log_group.ghrsst_log_group.arn}:*",
      "Effect": "Allow"
    },
    {
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "${aws_sqs_queue.ghrsst_queue.arn}",
      "Effect": "Allow"
    },
    {
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${var.destination_bucket_name}",
        "arn:aws:s3:::${var.destination_bucket_name}/*"
      ],
      "Effect": "Allow"
    }
  ]
}
EOF
}

# Join the role and policy
resource "aws_iam_role_policy_attachment" "ghrsst_role_policy_attachment" {
  role       = aws_iam_role.ghrsst_role.name
  policy_arn = aws_iam_policy.ghrsst_role_policy.arn
}

# Connect the lambda to the queue
resource "aws_lambda_event_source_mapping" "sqs_event_source_mapping" {
  event_source_arn = aws_sqs_queue.ghrsst_queue.arn
  function_name    = aws_lambda_function.ghrsst_lambda.function_name
  batch_size       = 1
}

# Set up a second log group
resource "aws_cloudwatch_log_group" "ghrsst_log_group_daily" {
  name              = "/aws/lambda/ghrsst-lambda-daily"
  retention_in_days = 5
}


# The second lambda function, this one just adds the last 7 days
resource "aws_lambda_function" "daily_lambda" {
  function_name = "ghrsst-lambda-daily"
  role          = aws_iam_role.ghrsst_role_daily.arn
  image_config {
    command = ["ghrsst.dategen.lambda_handler"]
  }
  timeout     = 30
  memory_size = 512

  # Run a dockerfile
  image_uri    = "${resource.aws_ecr_repository.ghrsst.repository_url}:${var.image_tag}"
  package_type = "Image"

  environment {
    variables = {
      SQS_QUEUE = aws_sqs_queue.ghrsst_queue.name
    }
  }
}


# Create an IAM role for the daily Lambda function
resource "aws_iam_role" "ghrsst_role_daily" {
  name = "ghrsst-role-daily"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# And a daily policy
resource "aws_iam_policy" "ghrsst_role_policy_daily" {
  name   = "ghrsst-policy-daily"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "${aws_cloudwatch_log_group.ghrsst_log_group_daily.arn}:*",
      "Effect": "Allow"
    },
    {
      "Action": [
        "sqs:SendMessage",
        "sqs:GetQueueUrl"
      ],
      "Resource": "${aws_sqs_queue.ghrsst_queue.arn}",
      "Effect": "Allow"
    }
  ]
}
EOF
}

# Join the role and policy
resource "aws_iam_role_policy_attachment" "ghrsst_role_policy_attachment_daily" {
  role       = aws_iam_role.ghrsst_role_daily.name
  policy_arn = aws_iam_policy.ghrsst_role_policy_daily.arn
}

# Schedule that daily lambda
resource "aws_cloudwatch_event_rule" "daily_lambda" {
  name                = "ghrsst-lambda-daily"
  description         = "Run the daily lambda"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "daily_lambda" {
  rule      = aws_cloudwatch_event_rule.daily_lambda.name
  target_id = "ghrsst-lambda-daily"
  arn       = aws_lambda_function.daily_lambda.arn
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_daily" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.daily_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_lambda.arn
}
