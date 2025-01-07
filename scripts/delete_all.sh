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
PREFIX="foxy"

echo "Starting cleanup for environment: $ENVIRONMENT..."

# Step 1: Delete Lambda Functions
echo "Deleting Lambda functions..."
LAMBDA_FUNCTIONS=$(aws lambda list-functions --query "Functions[?starts_with(FunctionName, \`${PREFIX}-${ENVIRONMENT}\`)].FunctionName" --output text)
for FUNCTION in $LAMBDA_FUNCTIONS; do
  echo "Deleting Lambda function: $FUNCTION"
  aws lambda delete-function --function-name $FUNCTION
done

# Step 2: Detach and Delete Policies
echo "Detaching and deleting custom IAM policies..."
POLICIES=$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, \`${PREFIX}-${ENVIRONMENT}\`)].Arn" --output text)
for POLICY_ARN in $POLICIES; do
  echo "Detaching and deleting policy: $POLICY_ARN"
  # Detach the policy from all roles
  ROLES=$(aws iam list-entities-for-policy --policy-arn $POLICY_ARN --query "PolicyRoles[].RoleName" --output text)
  for ROLE in $ROLES; do
    echo "Detaching policy from role: $ROLE"
    aws iam detach-role-policy --role-name $ROLE --policy-arn $POLICY_ARN
  done
  # Delete the policy
  aws iam delete-policy --policy-arn $POLICY_ARN
done

# Step 3: Delete IAM Roles
echo "Deleting IAM roles..."
ROLES=$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`${PREFIX}-${ENVIRONMENT}\`)].RoleName" --output text)
for ROLE in $ROLES; do
  echo "Deleting IAM role: $ROLE"
  aws iam delete-role --role-name $ROLE
done

# Step 4: Delete S3 Bucket
BUCKET_NAME="${PREFIX}-schema-deployments-${ENVIRONMENT}"
echo "Deleting S3 bucket: $BUCKET_NAME"
aws s3 rm s3://$BUCKET_NAME --recursive
aws s3api delete-bucket --bucket $BUCKET_NAME --region $REGION

echo "Cleanup complete for environment: $ENVIRONMENT."

# Step 1: Delete the database
if [ -n "$DATABASE_STACK" ]; then
  echo "Deleting Database stack..."
  aws cloudformation delete-stack --stack-name $DATABASE_STACK
fi

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

