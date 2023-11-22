# Configure the AWS provider
provider "aws" {
  region = "us-west-2"
}

# Get the secret manager secret called earthdata-token
data "aws_secretsmanager_secret" "earthdata_token" {
  name = "earthdata-token"
}

data "aws_secretsmanager_secret_version" "earthdata_token" {
  secret_id = data.aws_secretsmanager_secret.earthdata_token.id
}

# Create an SQS queue
resource "aws_sqs_queue" "ghrsst_queue" {
  name                       = "ghrsst-queue"
  delay_seconds              = 90
  max_message_size           = 2048
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 10
  visibility_timeout_seconds = 630 # 10.5 minutes
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ghrsst_queue_dead.arn
    maxReceiveCount     = 2
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

# Create a Lambda function
resource "aws_lambda_function" "my_lambda" {
  function_name = "ghrsst-lambda"
  role          = aws_iam_role.ghrsst_role.arn
  timeout       = 600  # 10 minutes
  memory_size   = 10240 # 4GB

  # Run a dockerfile
  image_uri    = "334668851926.dkr.ecr.us-west-2.amazonaws.com/ghrsst-cogger:0.0.4"
  package_type = "Image"

  # # Set up a dead-letter queue
  # dead_letter_config {
  #   target_arn = aws_sqs_queue.ghrsst_queue_dead.arn
  # }

  # Configure the Lambda function to read from the SQS queue
  environment {
    variables = {
      EARTHDATA_TOKEN = data.aws_secretsmanager_secret_version.earthdata_token.secret_string
    }
  }
}

# Connect the lambda to the queue
resource "aws_lambda_event_source_mapping" "sqs_event_source_mapping" {
  event_source_arn = aws_sqs_queue.ghrsst_queue.arn
  function_name    = aws_lambda_function.my_lambda.function_name
  batch_size       = 1
}

# Set up a log group
resource "aws_cloudwatch_log_group" "ghrsst_log_group" {
  name = "/aws/lambda/ghrsst-lambda"
}

# Create an IAM role for the Lambda function
resource "aws_iam_role" "ghrsst_role" {
  name = "my-lambda-role"

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

resource "aws_iam_policy" "ghrsst_role_policy" {
  name   = "my-lambda-role-policy"
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
        "sqs:SendMessage"
      ],
      "Resource": "${aws_sqs_queue.ghrsst_queue_dead.arn}",
      "Effect": "Allow"
    },
    {
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::files.auspatious.com",
        "arn:aws:s3:::files.auspatious.com/*"
      ],
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ghrsst_role_policy_attachment" {
  role       = aws_iam_role.ghrsst_role.name
  policy_arn = aws_iam_policy.ghrsst_role_policy.arn
}
