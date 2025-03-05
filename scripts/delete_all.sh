#!/bin/bash

set -e

remove_policies(){
  local STACK=$1
  local ROLE_NAME=$2

  echo "Removing policies for ${STACK}"
  # Check if the Role Stack exists
  if aws cloudformation describe-stacks --stack-name "$STACK" --region "eu-north-1" > /dev/null 2>&1; then
    # Safely retrieve the Lambda Role Name
    LAMBDA_ROLE_NAME=$(aws cloudformation describe-stacks \
      --stack-name "$STACK" \
      --query "Stacks[0].Outputs[?OutputKey=='$ROLE_NAME'].OutputValue" \
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
      echo "No Lambda execution role found in the outputs of $STACK."
    fi
  else
    echo "Role stack $STACK does not exist. Skipping role deletion."
  fi
}

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
ROLE_STACK=$(jq -r '.Stacks.CognitoRoleStack' $PARAMETERS_FILE)
KEY_ROTATION_ROLE_STACK=$(jq -r '.Stacks.KeyRotationRoleStack' $PARAMETERS_FILE)
KEY_ROTATION_STACK=$(jq -r '.Stacks.KeyRotationStack' $PARAMETERS_FILE)
GITHUB_LAMBDA_DEPLOY_ROLE_STACK=$(jq -r '.Stacks.GitHubLambdaDeployRoleStack' $PARAMETERS_FILE)
GITHUB_LAMBDA_EXEC_ROLE_STACK=$(jq -r '.Stacks.GitHubLambdaExecutionRoleStack' $PARAMETERS_FILE)
CUSTOM_AUTH_STACK=$(jq -r '.Stacks.CustomAuthStack' $PARAMETERS_FILE)
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' $PARAMETERS_FILE)
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)
DATABASE_STACK=$(jq -r '.Stacks.DatabaseStack' $PARAMETERS_FILE)
QUEUE_STACK=$(jq -r '.Stacks.QueueStack' $PARAMETERS_FILE)
BUCKET_STACK=$(jq -r '.Stacks.S3BucketStack' $PARAMETERS_FILE)
API_GATEWAY_STACK=$(jq -r '.Stacks.APIGatewayStack' $PARAMETERS_FILE)
ROLE_EXPORT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="ExportName") | .ParameterValue' "$PARAMETERS_FILE")
ROLE_NAME=$(aws cloudformation list-exports --query "Exports[?Name=='${ROLE_EXPORT_NAME}'].Value" --output text)

echo "Removing User Pool..."

# Check if the CloudFormation stack exists
if aws cloudformation describe-stacks --stack-name "$USER_POOL_STACK" --region "$REGION" > /dev/null 2>&1; then
  USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "$USER_POOL_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
    --output text \
    --region "$REGION")
  
  # Proceed to delete the User Pool
  if [[ -n "$USER_POOL_ID" && "$USER_POOL_ID" != "None" ]]; then
    aws cognito-idp delete-user-pool \
      --user-pool-id "$USER_POOL_ID" \
      --region "$REGION"
    echo "User Pool with ID $USER_POOL_ID has been deleted."
  else
    echo "User Pool ID not found in stack '$USER_POOL_STACK'. Skipping deletion."
  fi

else
  echo "Warning: CloudFormation stack '$USER_POOL_STACK' does not exist in region '$REGION'. Skipping User Pool deletion."
fi

# List and delete all event source mappings starting with Foxy-{EnvironmentName}
echo "Deleting triggers matching 'foxy-${ENVIRONMENT_NAME}*'..."
aws lambda list-event-source-mappings \
  --query "EventSourceMappings[?starts_with(FunctionArn, 'arn:aws:lambda:eu-north-1:*:function:Foxy-${ENVIRONMENT_NAME}')].UUID" \
  --output text | while read uuid; do
    echo "Deleting trigger $uuid..."
    aws lambda delete-event-source-mapping --uuid "$uuid"
  done

echo "Deleting Lambda functions matching 'foxy-${ENVIRONMENT_NAME}*'..."

# List and delete all Lambda functions matching the pattern
LAMBDA_FUNCTIONS=$(aws lambda list-functions --region $REGION --query "Functions[?starts_with(FunctionName, 'foxy-${ENVIRONMENT_NAME}')].FunctionName" --output text)

if [ -z "$LAMBDA_FUNCTIONS" ]; then
  echo "No Lambda functions matching 'foxy-${ENVIRONMENT_NAME}*' found."
else
  for FUNCTION in $LAMBDA_FUNCTIONS; do
    echo "Deleting Lambda function: $FUNCTION"
    aws lambda delete-function --function-name "$FUNCTION" --region "$REGION" || echo "Failed to delete $FUNCTION."
  done
fi

echo "Lambda function cleanup completed."

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

# Step 5: Delete the remaining stacks
# Wait for stacks to be deleted
echo "Waiting for stacks to be deleted..."
echo "Deleting IAM Role stack..."
if [ -n "$ROLE_STACK" ]; then
  remove_policies $ROLE_STACK CognitoLambdaExecutionRoleName
  delete_stack $ROLE_STACK
fi

# echo "Deleting GitHub Lambda Deploy Role stack..."
# if [ -n "$GITHUB_LAMBDA_DEPLOY_ROLE_STACK" ]; then
#  remove_policies $GITHUB_LAMBDA_DEPLOY_ROLE_STACK
#  delete_stack $GITHUB_LAMBDA_DEPLOY_ROLE_STACK
#fi

# echo "Deleting GitHub Lambda Deploy Role stack..."
# if [ -n "$GITHUB_LAMBDA_EXEC_ROLE_STACK" ]; then
#   remove_policies $GITHUB_LAMBDA_EXEC_ROLE_STACK
#   delete_stack $GITHUB_LAMBDA_EXEC_ROLE_STACK
# fi

# Remove the database roles safely
ROLE_NAMES=("foxy_${ENVIRONMENT_NAME}_AppRole" "foxy_${ENVIRONMENT_NAME}_AdminRole" "foxy_${ENVIRONMENT_NAME}_ReportingRole")

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

# Catch-all backup for removing log groups - shouldn't really be needed
# TODO: test and delete
echo "Deleting log groups..."
# Define the search pattern
PATTERN="foxy-${ENVIRONMENT_NAME}"

# Get the list of log groups matching the pattern
LOG_GROUPS=$(aws logs describe-log-groups \
  --query "logGroups[?contains(logGroupName, '${PATTERN}')].logGroupName" \
  --output text --region eu-north-1)

# Check if any log groups are found
if [ -z "$LOG_GROUPS" ]; then
  echo "No log groups found matching pattern '${PATTERN}'."
else
  echo "Found the following log groups:"
  echo "$LOG_GROUPS"

  # Loop through each log group and delete it
  for LOG_GROUP in $LOG_GROUPS; do
    echo "Deleting log group: $LOG_GROUP"
    aws logs delete-log-group --log-group-name "$LOG_GROUP" --region eu-north-1
    if [ $? -eq 0 ]; then
      echo "Successfully deleted log group: $LOG_GROUP"
    else
      echo "Failed to delete log group: $LOG_GROUP"
    fi
  done
fi
echo "Complete..."

if [ -n "$CUSTOM_AUTH_STACK" ]; then
  delete_stack $CUSTOM_AUTH_STACK
fi
if [ -n "$DATABASE_STACK" ]; then
  delete_stack $DATABASE_STACK
fi
if [ -n "$QUEUE_STACK" ]; then
  delete_stack $QUEUE_STACK
fi
if [ -n "$API_GATEWAY_STACK" ]; then

  REST_API_ID=$(aws apigateway get-rest-apis --query "items[?name=='foxy-${ENVIRONMENT_NAME}-api'].id" --output text --region eu-north-1)

  if [ -n "$REST_API_ID" ]; then
    echo "Deleting API Gateway Stage $ENVIRONMENT_NAME for REST API $REST_API_ID"
	  aws apigateway delete-stage --rest-api-id "$REST_API_ID" --stage-name "$ENVIRONMENT_NAME" --region eu-north-1
	else
	  echo "API Gateway REST API not found for Stage $ENVIRONMENT_NAME"
	fi

  delete_stack $API_GATEWAY_STACK
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

# Delete the security groups
echo "Fetching all security groups in $REGION..."

# List all security groups except 'default'
SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups \
  --region $REGION \
  --query "SecurityGroups[?GroupName!='default'].GroupId" \
  --output text)

for SG_ID in $SECURITY_GROUP_IDS; do
  # Check if the security group is attached to any network interface
  ATTACHMENTS=$(aws ec2 describe-network-interfaces \
    --filters Name=group-id,Values=$SG_ID \
    --region $REGION \
    --query "NetworkInterfaces[].NetworkInterfaceId" \
    --output text)

  if [[ -z "$ATTACHMENTS" ]]; then
    echo "Deleting unused Security Group: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region $REGION
  else
    echo "⚠️ Security Group $SG_ID is attached to a resource and cannot be deleted."
  fi
done

echo "✅ Security group cleanup complete."


echo "Environment reset completed successfully!"
