#!/bin/bash

set -e

# Check if configuration file is provided as a parameter
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <config-file>"
  exit 1
fi

PARAMETERS_FILE=$1

# Ensure the configuration file exists
if [ ! -f "$PARAMETERS_FILE" ]; then
  echo "Configuration file $PARAMETERS_FILE does not exist."
  exit 1
fi

# Parse parameters
ENVIRONMENT=$(jq -r '.Environment' $PARAMETERS_FILE)
ENVIRONMENT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$PARAMETERS_FILE")
REGION=$(jq -r '.Region' $PARAMETERS_FILE)
ROLE_STACK=$(jq -r '.Stacks.RoleStack' $PARAMETERS_FILE)
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' $PARAMETERS_FILE)
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)
DATABASE_STACK=$(jq -r '.Stacks.DatabaseStack // empty' $PARAMETERS_FILE)
PREFIX="foxy"

echo "Deleting SQL lambda..."
EXECUTE_SQL_FUNCTION_NAME="execute_sql"
aws lambda delete-function --function-name $EXECUTE_SQL_FUNCTION_NAME || echo "Failed to delete Lambda function: $EXECUTE_SQL_FUNCTION_NAME"

BUCKET_NAME="rds-schema-deployments"
BUCKET_NAME="foxy-${ENVIRONMENT_NAME}-${BUCKET_NAME}"
BUCKET_NAME="${BUCKET_NAME,,}" # Convert to lowercase

echo "Checking if S3 bucket exists: $BUCKET_NAME"

# Check if the bucket exists
if aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
  echo "Deleting S3 bucket: $BUCKET_NAME"
  aws s3api delete-bucket-policy --bucket $BUCKET_NAME
  aws s3 rm s3://$BUCKET_NAME --recursive
  aws s3api delete-bucket --bucket $BUCKET_NAME --region $REGION
  echo "Bucket $BUCKET_NAME deleted successfully."
else
  echo "S3 bucket $BUCKET_NAME does not exist. Skipping deletion."
fi

echo "Complete"
