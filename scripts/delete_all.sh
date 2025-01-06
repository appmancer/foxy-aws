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
REGION=$(jq -r '.Region' $PARAMETERS_FILE)
ROLE_STACK=$(jq -r '.Stacks.RoleStack' $PARAMETERS_FILE)
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' $PARAMETERS_FILE)
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)
DATABASE_STACK=$(jq -r '.Stacks.DatabaseStack // empty' $PARAMETERS_FILE)

# Step 0: Delete the database
if [ -n "$DATABASE_STACK" ]; then
  echo "Deleting Database stack..."
  aws cloudformation delete-stack --stack-name $DATABASE_STACK
fi

# Step 1: Delete the Lambda Function
echo "Deleting Lambda function..."
LAMBDA_FUNCTION_NAME="CognitoCustomAuthLambda"
aws lambda delete-function \
  --function-name $LAMBDA_FUNCTION_NAME \
  --region $REGION || echo "Lambda function $LAMBDA_FUNCTION_NAME does not exist."

# Step 2: Delete the Service Account Stack
if [ -n "$SERVICE_ACCOUNT_STACK" ]; then
  echo "Deleting Service Account stack..."
  aws cloudformation delete-stack --stack-name $SERVICE_ACCOUNT_STACK
  aws cloudformation wait stack-delete-complete --stack-name $SERVICE_ACCOUNT_STACK || echo "Service Account stack deletion completed."
else
  echo "No Service Account stack defined. Skipping deletion."
fi

# Step 3: Delete the Cognito User Pool Stack
echo "Deleting Cognito User Pool stack..."
aws cloudformation delete-stack --stack-name $USER_POOL_STACK

# Step 4: Delete the Role Stack
echo "Deleting IAM Role stack..."
aws cloudformation delete-stack --stack-name $ROLE_STACK

# Step 5: Detach Policies and Delete the Lambda Execution Role
echo "Detaching policies and deleting Lambda execution role..."
LAMBDA_ROLE_NAME=$(aws cloudformation describe-stacks \
  --stack-name $ROLE_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoLambdaExecutionRoleName'].OutputValue" \
  --output text)

if [ -n "$LAMBDA_ROLE_NAME" ]; then
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name $LAMBDA_ROLE_NAME \
    --query "AttachedPolicies[].PolicyArn" \
    --output text)

  for POLICY_ARN in $ATTACHED_POLICIES; do
    echo "Detaching policy $POLICY_ARN from role $LAMBDA_ROLE_NAME..."
    aws iam detach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn $POLICY_ARN
  done

  aws iam delete-role --role-name $LAMBDA_ROLE_NAME || echo "IAM role $LAMBDA_ROLE_NAME does not exist or could not be deleted."
else
  echo "No Lambda execution role found to delete."
fi

# Wait for stacks to be deleted
echo "Waiting for stacks to be deleted..."
aws cloudformation wait stack-delete-complete --stack-name $USER_POOL_STACK || echo "User Pool stack deletion completed."
aws cloudformation wait stack-delete-complete --stack-name $ROLE_STACK || echo "IAM Role stack deletion completed."

echo "Environment reset completed successfully!"

