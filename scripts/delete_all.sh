#!/bin/bash

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <parameter-file>"
    exit 1
fi

PARAMETERS_FILE="$1"

if [[ ! -f "$PARAMETERS_FILE" ]]; then
    echo "Error: Parameters file $PARAMETERS_FILE not found."
    exit 1
fi

echo "Loading configuration from $PARAMETERS_FILE..."
ENVIRONMENT=$(jq -r '.Environment' "$PARAMETERS_FILE")
REGION=$(jq -r '.Region' "$PARAMETERS_FILE")
ROLE_STACK=$(jq -r '.Stacks.RoleStack' "$PARAMETERS_FILE")
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' "$PARAMETERS_FILE")
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)

echo "Environment: $ENVIRONMENT"
echo "Region: $REGION"

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

# Step 5: Delete the Lambda Execution Role
echo "Deleting Lambda execution role..."
LAMBDA_ROLE_NAME=$(aws cloudformation describe-stacks \
  --stack-name $ROLE_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoLambdaExecutionRoleName'].OutputValue" \
  --output text)

if [ -n "$LAMBDA_ROLE_NAME" ]; then
  aws iam delete-role --role-name $LAMBDA_ROLE_NAME || echo "IAM role $LAMBDA_ROLE_NAME does not exist or could not be deleted."
else
  echo "No Lambda execution role found to delete."
fi

# Wait for stacks to be deleted
echo "Waiting for stacks to be deleted..."
aws cloudformation wait stack-delete-complete --stack-name $USER_POOL_STACK || echo "User Pool stack deletion completed."
aws cloudformation wait stack-delete-complete --stack-name $ROLE_STACK || echo "IAM Role stack deletion completed."

echo "Environment reset completed successfully!"

