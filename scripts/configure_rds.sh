#!/bin/bash

set -e

# Parameters

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
STACK_NAME=$(jq -r '.Stacks.DatabaseStack' $PARAMETERS_FILE)

echo "Starting configuration phase"

echo "Getting the DatabaseAccessRole ARN"
DATABASE_ACCESS_ROLE_ARN=$(aws iam list-roles \
  --query "Roles[*].Arn" --output json | \
  jq -r '.[] | select(contains("DatabaseAccessRole"))')

echo "DATABASE_ACCESS_ROLE_ARN:$DATABASE_ACCESS_ROLE_ARN"

echo "Creating the lambda to execute sql..."
EXECUTE_SQL_FUNCTION_NAME="execute_sql"
zip -q -j execute_sql_lambda.zip ./scripts/execute_sql_lambda.py"

aws lambda create-function \
    --function-name $EXECUTE_SQL_FUNCTION_NAME \
    --runtime python3.9 \
    --role $DATABASE_ACCESS_ROLE_ARN \
    --handler execute_sql_lambda.lambda_handler \
    --timeout 15 \
    --memory-size 128 \
    --zip-file fileb://execute_sql_lambda.zip 

echo "Lambda creation complete"

echo "Creating S3 buckets"
BUCKET_PREFIX="rds-schema-deployments"
BUCKET_NAME="${BUCKET_PREFIX}-${ENVIRONMENT}"
VPC_CIDR="172.31.0.0/16"
TEMPLATE_FILE="./templates/bucket-policy-template.json"
POLICY_FILE="bucket-policy.json"

echo "Creating S3 bucket: $BUCKET_NAME in $REGION..."

if [[ ! -f $TEMPLATE_FILE ]]; then
  echo "Error: Template file '$TEMPLATE_FILE' not found."
  exit 1
fi

# Create the bucket
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $REGION \
    --create-bucket-configuration LocationConstraint=$REGION

echo "Generating policy for bucket: $BUCKET_NAME..."
sed "s/{{BUCKET_NAME}}/$BUCKET_NAME/g; s/{{VPC_CIDR}}/$VPC_CIDR/g" $TEMPLATE_FILE > $POLICY_FILE
echo "Applying bucket policies for $BUCKET_NAME..."
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file://$POLICY_FILE

echo "S3 bucket $BUCKET_NAME created and secured."

echo "Copying schema to bucket"
aws s3 cp ./schema.sql s3://$BUCKET_NAME/
echo "Schema complete"
echo "Check for success by running:aws logs tail /aws/lambda/execute_sql --follow"


