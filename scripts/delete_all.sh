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
ENVIRONMENT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$PARAMETERS_FILE")
REGION=$(jq -r '.Region' $PARAMETERS_FILE)
ACCOUNT=$(jq -r '.Account' $PARAMETERS_FILE)
ROLE_STACK=$(jq -r '.Stacks.RoleStack' $PARAMETERS_FILE)
CUSTOM_AUTH_STACK=$(jq -r '.Stacks.CustomAuthStack' $PARAMETERS_FILE)
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
# Wait for stacks to be deleted
echo "Waiting for stacks to be deleted..."
echo "Deleting IAM Role stack..."
if [ -n "$ROLE_STACK" ]; then
  delete_stack $ROLE_STACK
fi

# Remove the database roles safely
ROLE_NAMES=("foxy_dev_AppRole" "foxy_dev_AdminRole" "foxy_dev_ReportingRole")

for ROLE in "${ROLE_NAMES[@]}"; do
  # Check if the role exists
  if aws iam get-role --role-name "$ROLE" > /dev/null 2>&1; then
    echo "Role $ROLE exists. Detaching policies..."

    # Detach all managed policies
    POLICIES=$(aws iam list-attached-role-policies \
      --role-name "$ROLE" \
      --query "AttachedPolicies[].PolicyArn" \
      --output text)

    for POLICY_ARN in $POLICIES; do
      echo "Detaching policy $POLICY_ARN from role $ROLE..."
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN"
    done

    # Delete the IAM role after detaching policies
    aws iam delete-role --role-name "$ROLE"
    echo "Role $ROLE deleted successfully."

  else
    echo "Role $ROLE does not exist. Skipping..."
  fi
done
if [ -n "$CUSTOM_AUTH_STACK" ]; then
  delete_stack $CUSTOM_AUTH_STACK
fi
if [ -n "$DATABASE_STACK" ]; then
  delete_stack $DATABASE_STACK
fi
if [ -n "$QUEUE_STACK" ]; then
  delete_stack $QUEUE_STACK
fi

# empty the bucket first
BUCKET_NAME="foxy-${ENVIRONMENT_NAME}-lambda-deployments-${ACCOUNT}"

# Check if the bucket exists
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket $BUCKET_NAME exists. Emptying it..."
  echo "Deleting all object versions from $BUCKET_NAME..."

  # Delete all object versions
  aws s3api list-object-versions --bucket "$BUCKET_NAME" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text |
  while read -r Key VersionId; do
    if [[ -n "$VersionId" ]]; then
      echo "Deleting object: $Key (VersionId: $VersionId)"
      aws s3api delete-object --bucket "$BUCKET_NAME" --key "$Key" --version-id "$VersionId"
    fi
  done

  echo "Deleting all delete markers from $BUCKET_NAME..."

  # Delete all delete markers
  aws s3api list-object-versions --bucket "$BUCKET_NAME" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text |
  while read -r Key VersionId; do
    if [[ -n "$VersionId" ]]; then
      echo "Deleting delete marker: $Key (VersionId: $VersionId)"
      aws s3api delete-object --bucket "$BUCKET_NAME" --key "$Key" --version-id "$VersionId"
    fi
  done

  echo "Bucket $BUCKET_NAME is now empty."
else
  echo "Bucket $BUCKET_NAME does not exist. Skipping deletion."
fi

if [ -n "$BUCKET_STACK" ]; then
  delete_stack $BUCKET_STACK
fi

echo "Environment reset completed successfully!"

