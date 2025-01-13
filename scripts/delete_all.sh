#!/bin/bash

set -e

delete_stack(){
  local STACK_KEY=$1
  if aws cloudformation describe-stacks --stack-name "$STACK_KEY" --region "$REGION" > /dev/null 2>&1; then
    echo "Stack $STACK_KEY exists. Deleting..."
    aws cloudformation delete-stack --stack-name "$STACK_KEY" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_KEY" --region "$REGION"
    echo "Stack $STACK_KEY deletion completed."
  else
    echo "Stack $STACK_KEY does not exist. Skipping deletion."
  fi
}

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
DATABASE_STACK=$(jq -r '.Stacks.DatabaseStack' $PARAMETERS_FILE)
QUEUE_STACK=$(jq -r '.Stacks.QueueStack' $PARAMETERS_FILE)
BUCKET_STACK=$(jq -r '.Stacks.S3BucketStack' $PARAMETERS_FILE)

# Step 1: Delete the Lambda Function
echo "Deleting Lambda function..."
LAMBDA_FUNCTION_NAME="foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda"
aws lambda delete-function \
  --function-name $LAMBDA_FUNCTION_NAME \
  --region $REGION || echo "Lambda function $LAMBDA_FUNCTION_NAME does not exist."

# Step 2: Delete the Service Account Stack
if [ -n "$SERVICE_ACCOUNT_STACK" ]; then
  delete_stack $SERVICE_ACCOUNT_STACK
fi

# Step 3: Delete the Cognito User Pool Stack
echo "Deleting Cognito User Pool stack..."

if [ -n "$USER_POOL_STACK" ]; then
  delete_stack $USER_POOL_STACK
fi

# Step 4: Detach Policies and Delete the Lambda Execution Role]
echo "Detaching policies and deleting Lambda execution role..."
echo "Detaching policies and deleting Lambda execution role..."

# Check if the Role Stack exists
if aws cloudformation describe-stacks --stack-name "$ROLE_STACK" --region "$REGION" > /dev/null 2>&1; then
  # Safely retrieve the Lambda Role Name
  LAMBDA_ROLE_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$ROLE_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='CognitoLambdaExecutionRoleName'].OutputValue" \
    --output text)

  if [ -n "$LAMBDA_ROLE_NAME" ]; then
    # Check if the IAM Role actually exists
    if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" > /dev/null 2>&1; then

      # 1. Detach Managed Policies
      ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
        --role-name "$LAMBDA_ROLE_NAME" \
        --query "AttachedPolicies[].PolicyArn" \
        --output text)

      for POLICY_ARN in $ATTACHED_POLICIES; do
        echo "Detaching managed policy $POLICY_ARN from role $LAMBDA_ROLE_NAME..."
        aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn "$POLICY_ARN"
      done

      # 2. Delete Inline Policies
      INLINE_POLICIES=$(aws iam list-role-policies \
        --role-name "$LAMBDA_ROLE_NAME" \
        --query "PolicyNames[]" \
        --output text)

      for POLICY_NAME in $INLINE_POLICIES; do
        echo "Deleting inline policy $POLICY_NAME from role $LAMBDA_ROLE_NAME..."
        aws iam delete-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name "$POLICY_NAME"
      done

      # 3. Delete the IAM Role
      aws iam delete-role --role-name "$LAMBDA_ROLE_NAME"
      echo "IAM role $LAMBDA_ROLE_NAME deleted successfully."
    else
      echo "IAM role $LAMBDA_ROLE_NAME does not exist or was already deleted."
    fi
  else
    echo "No Lambda execution role found in the outputs of $ROLE_STACK."
  fi
else
  echo "Role stack $ROLE_STACK does not exist. Skipping role deletion."
fi


# Step 5: Delete the remaining stacks
echo "Deleting IAM Role stack..."
if [ -n "$ROLE_STACK" ]; then
  delete_stack $ROLE_STACK
fi

# Wait for stacks to be deleted
echo "Waiting for stacks to be deleted..."

if [ -n "$DATABASE_STACK" ]; then
  delete_stack $DATABASE_STACK
fi
if [ -n "$QUEUE_STACK" ]; then
  delete_stack $QUEUE_STACK
fi
if [ -n "$BUCKET_STACK" ]; then
  delete_stack $BUCKET_STACK
fi

echo "Environment reset completed successfully!"

