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

# Function to check if a stack exists and delete it
delete_stack() {
  local stack_name=$1
  local stack_status

  echo "Checking if stack $stack_name exists..."

  # Query CloudFormation to check the stack status, handle missing stack gracefully
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "STACK_NOT_FOUND")

  # Check the stack status
  if [ "$stack_status" == "CREATE_COMPLETE" ] || [ "$stack_status" == "UPDATE_COMPLETE" ] || [ "$stack_status" == "ROLLBACK_COMPLETE" ]; then
    echo "Stack $stack_name exists with status $stack_status. Deleting..."
    aws cloudformation delete-stack --stack-name "$stack_name"
    echo "Stack $stack_name deletion initiated."
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" || echo "$stack_name stack deletion completed."
  elif [ "$stack_status" == "DELETE_COMPLETE" ]; then
    echo "Stack $stack_name has already been deleted."
  elif [ "$stack_status" == "STACK_NOT_FOUND" ]; then
    echo "Stack $stack_name does not exist. Skipping."
  else
    echo "Stack $stack_name is in an unexpected state: $stack_status."
  fi
}

echo "Starting cleanup for environment: $ENVIRONMENT..."

# Step 1: Delete Lambda Functions
echo "Deleting Lambda functions..."

# List functions and extract only the FunctionName field
LAMBDA_FUNCTIONS=$(aws lambda list-functions --query "Functions[].FunctionName" --output text)

if [ -z "$LAMBDA_FUNCTIONS" ]; then
    echo "No Lambda functions found."
else
    for FUNCTION in $LAMBDA_FUNCTIONS; do
        echo "Deleting Lambda function: $FUNCTION"
        aws lambda delete-function --function-name $FUNCTION || echo "Failed to delete Lambda function: $FUNCTION"
    done
fi

# Step 2: Detach and Delete Policies
echo "Detaching and deleting custom IAM policies..."

# Extract only the PolicyArn column
POLICIES=$(aws iam list-policies --scope Local --query "Policies[].Arn" --output text)

if [ -z "$POLICIES" ]; then
  echo "No policies found to delete."
else
  for POLICY_ARN in $POLICIES; do
    echo "Processing policy: $POLICY_ARN"

    # Detach the policy from all roles
    ROLES=$(aws iam list-entities-for-policy --policy-arn $POLICY_ARN --query "PolicyRoles[].RoleName" --output text)
    if [ -n "$ROLES" ]; then
      for ROLE in $ROLES; do
        echo "Detaching policy from role: $ROLE"
        aws iam detach-role-policy --role-name $ROLE --policy-arn $POLICY_ARN || echo "Failed to detach policy $POLICY_ARN from role $ROLE"
      done
    fi

    # Delete all non-default versions of the policy
    echo "Deleting non-default policy versions for: $POLICY_ARN"
    VERSIONS=$(aws iam list-policy-versions --policy-arn $POLICY_ARN --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text)
    if [ -n "$VERSIONS" ]; then
      for VERSION in $VERSIONS; do
        echo "Deleting policy version: $VERSION"
        aws iam delete-policy-version --policy-arn $POLICY_ARN --version-id $VERSION || echo "Failed to delete version $VERSION of policy $POLICY_ARN"
      done
    fi

    # Delete the policy
    echo "Deleting policy: $POLICY_ARN"
    aws iam delete-policy --policy-arn $POLICY_ARN || echo "Failed to delete policy $POLICY_ARN"
  done
fi


# Step 3: Delete IAM Roles
echo "Deleting IAM roles..."
ROLES=$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`${ENVIRONMENT}\`)].RoleName" --output text)
for ROLE in $ROLES; do
  echo "Deleting IAM role: $ROLE"
  aws iam delete-role --role-name $ROLE
done

# Step 4: Delete S3 Bucket
BUCKET_NAME="rds-schema-deployments"
BUCKET_NAME="foxy-${ENVIRONMENT_NAME}-${BUCKET_NAME}"
BUCKET_NAME="${BUCKET_NAME,,}" # Convert to lowercase
echo "Checking if S3 bucket exists: $BUCKET_NAME"

# Check if the bucket exists
if aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
  echo "Deleting S3 bucket: $BUCKET_NAME"
  aws s3 rm s3://$BUCKET_NAME --recursive
  aws s3api delete-bucket --bucket $BUCKET_NAME --region $REGION
  echo "Bucket $BUCKET_NAME deleted successfully."
else
  echo "S3 bucket $BUCKET_NAME does not exist. Skipping deletion."
fi

echo "Cleanup complete for environment: $ENVIRONMENT."

# Step 1: Delete the database
if [ -n "$DATABASE_STACK" ]; then
 delete_stack "$DATABASE_STACK"
fi

# Step 2: Delete the Service Account Stack
delete_stack "$SERVICE_ACCOUNT_STACK"

# Step 3: Delete the Cognito User Pool Stack
echo "Deleting Cognito User Pool stack..."
delete_stack "$USER_POOL_STACK"

# Step 5: Detach Policies and Delete the Lambda Execution Role
echo "Detaching policies and deleting Lambda execution role..."

LAMBDA_ROLE_NAME=$(aws cloudformation describe-stacks \
  --stack-name $ROLE_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoLambdaExecutionRoleName'].OutputValue" \
  --output text 2>/dev/null || echo "ROLE_NOT_FOUND")

if [ "$LAMBDA_ROLE_NAME" == "ROLE_NOT_FOUND" ]; then
  echo "Role $LAMBDA_ROLE_NAME does not exist. Skipping."
else
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name $LAMBDA_ROLE_NAME \
    --query "AttachedPolicies[].PolicyArn" \
    --output text)

  for POLICY_ARN in $ATTACHED_POLICIES; do
    echo "Detaching policy $POLICY_ARN from role $LAMBDA_ROLE_NAME..."
    aws iam detach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn $POLICY_ARN
  done

  echo "Deleting IAM role $LAMBDA_ROLE_NAME..."
  aws iam delete-role --role-name $LAMBDA_ROLE_NAME || echo "IAM role $LAMBDA_ROLE_NAME does not exist or could not be deleted."
fi

# Step 4: Delete the Role Stack
delete_stack "$ROLE_STACK"

echo "Environment reset completed successfully!"

