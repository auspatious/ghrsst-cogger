# Set up terraform remote state on S3
terraform {
  backend "s3" {
    bucket = "aad-ghrsst-terraform-state"
    key    = "ghrsst-prod-state"
    region = "us-west-2"
  }
}

# Configure the AWS provider
provider "aws" {
  region = "us-west-2"
}

variable "destination_bucket_path" {
  description = "The path to the destination S3 bucket"
  type        = string
  default     = "s3://fake-test-bucket/path/"
}

variable "image_tag" {
  description = "The image URL for the lambda docker image"
  type        = string
  default     = "TAG"
}

# Get the secret manager secret called earthdata-username
data "aws_secretsmanager_secret" "earthdata_username" {
  name = "earthdata-username"
}
data "aws_secretsmanager_secret_version" "earthdata_username" {
  secret_id = data.aws_secretsmanager_secret.earthdata_username.id
}

# Get the secret manager secret called earthdata-password
data "aws_secretsmanager_secret" "earthdata_password" {
  name = "earthdata-password"
}
data "aws_secretsmanager_secret_version" "earthdata_password" {
  secret_id = data.aws_secretsmanager_secret.earthdata_password.id
}

# Get the secret manager secret for the access key id
data "aws_secretsmanager_secret" "aws_access_key_id" {
  name = "source-coop-access-key"
}
data "aws_secretsmanager_secret_version" "aws_access_key_id" {
  secret_id = data.aws_secretsmanager_secret.aws_access_key_id.id
}

# Get the secret manager secret for the secret access key
data "aws_secretsmanager_secret" "aws_secret_access_key" {
  name = "source-coop-secret-key"
}
data "aws_secretsmanager_secret_version" "aws_secret_access_key" {
  secret_id = data.aws_secretsmanager_secret.aws_secret_access_key.id
}

# Set up a ECR repository
resource "aws_ecr_repository" "ghrsst" {
  name = "ghrsst-cogger"
}

# Set up a S3 bucket
resource "aws_s3_bucket" "ghrsst_bucket" {
  bucket = "idea-ghrsst-testing"
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
    size = 6000
  }

  # Run a dockerfile
  image_uri    = "${resource.aws_ecr_repository.ghrsst.repository_url}:${var.image_tag}"
  package_type = "Image"

  environment {
    variables = {
      EARTHDATA_USERNAME = data.aws_secretsmanager_secret_version.earthdata_username.secret_string,
      EARTHDATA_PASSWORD = data.aws_secretsmanager_secret_version.earthdata_password.secret_string,
      # SOURCECOOP_AWS_ENDPOINT_URL = "https://data.source.coop",
      # SOURCECOOP_AWS_ACCESS_KEY_ID = data.aws_secretsmanager_secret_version.aws_access_key_id.secret_string,
      # SOURCECOOP_AWS_SECRET_ACCESS_KEY = data.aws_secretsmanager_secret_version.aws_secret_access_key.secret_string,
      OUTPUT_LOCATION = "s3://${var.destination_bucket_path}",
      CACHE_LOCAL     = "true"
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
resource "aws_iam_policy" "ghrsst_writer_policy" {
  name   = "ghrsst-writer-policy"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "${aws_cloudwatch_log_group.ghrsst_log_group.arn}:*",
        "${aws_cloudwatch_log_group.parquet.arn}:*"
      ],
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
        "s3:ListBucket",
        "s3:ListMultiPartUploadParts",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::${aws_s3_bucket.ghrsst_bucket.bucket}",
        "arn:aws:s3:::${aws_s3_bucket.ghrsst_bucket.bucket}/*",
        "arn:aws:s3:::us-west-2.opendata.source.coop",
        "arn:aws:s3:::us-west-2.opendata.source.coop/*"
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
  policy_arn = aws_iam_policy.ghrsst_writer_policy.arn
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
      "Resource": [
        "${aws_cloudwatch_log_group.ghrsst_log_group_daily.arn}:*",
        "${aws_cloudwatch_log_group.parquet.arn}:*"
      ],
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
  schedule_expression = "cron(0 0 * * ? *)" # Run at midnight
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

# Set up a third log group, for the parquet creator
resource "aws_cloudwatch_log_group" "parquet" {
  name              = "/aws/lambda/ghrsst-lambda-parquet-daily"
  retention_in_days = 5
}

# The third lambda function, recreates a parquet file
resource "aws_lambda_function" "parquet" {
  function_name = "ghrsst-lambda-parquet-daily"
  role          = aws_iam_role.ghrsst_role.arn # re-use the og role, because it can write
  image_config {
    command = ["ghrsst.create_parquet.lambda_handler"]
  }
  timeout     = 600  # 10 minutes
  memory_size = 4096 # 4 GB
  ephemeral_storage {
    size = 1536
  }

  # Run a dockerfile
  image_uri    = "${resource.aws_ecr_repository.ghrsst.repository_url}:${var.image_tag}"
  package_type = "Image"

  environment {
    variables = {
      START_DATE      = "2003-05-30",
      OUTPUT_LOCATION = "s3://${var.destination_bucket_path}",
    }
  }
}

# Schedule that parquet lambda using cron
resource "aws_cloudwatch_event_rule" "parquet" {
  name                = "ghrsst-lambda-parquet-daily"
  description         = "Run the daily lambda"
  schedule_expression = "cron(0 1 * * ? *)" # Run at 1 am
}

resource "aws_cloudwatch_event_target" "parquet" {
  rule      = aws_cloudwatch_event_rule.parquet.name
  target_id = "ghrsst-lambda-parquet-daily"
  arn       = aws_lambda_function.parquet.arn
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_parquet" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parquet.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.parquet.arn
}
