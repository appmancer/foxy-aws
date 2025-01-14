CONFIG_FILE=$1

# Ensure the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file $CONFIG_FILE does not exist."
  exit 1
fi

# Load environment-specific parameters
PARAMETERS_FILE=$CONFIG_FILE

# Parse parameters
ENVIRONMENT=$(jq -r '.Environment' $PARAMETERS_FILE)
ENVIRONMENT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$CONFIG_FILE")


# Variables
REGION="eu-north-1"
SIGNING_QUEUE="foxy_${ENVIRONMENT_NAME}_TransactionSigningQueue"
SIGNING_DLQ="foxy_${ENVIRONMENT_NAME}_TransactionSigningDLQ"
BROADCAST_QUEUE="foxy_${ENVIRONMENT_NAME}_TransactionBroadcastQueue"
BROADCAST_DLQ="foxy_${ENVIRONMENT_NAME}_TransactionBroadcastDLQ"
ROLE_NAME="foxy_${ENVIRONMENT_NAME}_FoxyLambdaSQSRole"

# Create Dead Letter Queues
aws sqs create-queue \
    --queue-name $SIGNING_DLQ \
    --region $REGION

echo "$SIGNING_DLQ created."

aws sqs create-queue \
    --queue-name $BROADCAST_DLQ \
    --region $REGION

echo "$BROADCAST_DLQ created."

# Get DLQ ARNs
SIGNING_DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url https://sqs.$REGION.amazonaws.com/$(aws sts get-caller-identity --query "Account" --output text)/$SIGNING_DLQ \
    --attribute-name QueueArn \
    --query "Attributes.QueueArn" --output text)

BROADCAST_DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url https://sqs.$REGION.amazonaws.com/$(aws sts get-caller-identity --query "Account" --output text)/$BROADCAST_DLQ \
    --attribute-name QueueArn \
    --query "Attributes.QueueArn" --output text)

# Create Main Queues with DLQ Redrive Policy
aws sqs create-queue \
    --queue-name $SIGNING_QUEUE \
    --attributes "RedrivePolicy={\"deadLetterTargetArn\":\"$SIGNING_DLQ_ARN\",\"maxReceiveCount\":\"5\"}" \
    --region $REGION

echo "$SIGNING_QUEUE created with DLQ."

aws sqs create-queue \
    --queue-name $BROADCAST_QUEUE \
    --attributes "RedrivePolicy={\"deadLetterTargetArn\":\"$BROADCAST_DLQ_ARN\",\"maxReceiveCount\":\"5\"}" \
    --region $REGION

echo "$BROADCAST_QUEUE created with DLQ."

# Create IAM Role for Lambda to access SQS
aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "lambda.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }'

echo "IAM Role $ROLE_NAME created."

# Attach SQS Full Access Policy to the Role
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess

echo "AmazonSQSFullAccess policy attached to $ROLE_NAME."

# Attach basic Lambda execution permissions
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

echo "AWSLambdaBasicExecutionRole policy attached to $ROLE_NAME."

echo "All queues and IAM role setup completed successfully."

