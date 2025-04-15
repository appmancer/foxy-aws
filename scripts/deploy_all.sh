#!/bin/bash

set -e

deploy_function(){
  local SOURCE_FILE="$1"
  local BUCKET_NAME="$2"
  local ZIP_FILE="$3"
  local ENVIRONMENT_NAME="$4"
  local S3_KEY="lambda/${ZIP_FILE}"

  local LAMBDA_FUNCTION_NAME="foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda"
  zip -q -j $ZIP_FILE $SOURCE_FILE

  echo "Deploying $LAMBDA_FUNCTION_NAME..."
  # Upload function.zip to S3
  aws s3 cp $ZIP_FILE s3://$BUCKET_NAME/$S3_KEY --region $REGION

  echo "Uploaded $ZIP_FILE to s3://$BUCKET_NAME/$S3_KEY"

  # Check if the Lambda package exists in S3
  if aws s3api head-object --bucket "$BUCKET_NAME" --key "$S3_KEY" --region "$REGION" > /dev/null 2>&1; then
    echo "✅ File s3://$BUCKET_NAME/$S3_KEY exists. Continuing deployment..."
  else
    echo "❌ File s3://$BUCKET_NAME/$S3_KEY does not exist. Aborting deployment."
    exit 1
  fi

  rm -f $ZIP_FILE
  echo "Cleaned up local $ZIP_FILE"
  echo "✅ Complete."
}

# Function to deploy a CloudFormation stack
deploy_stack() {
  local STACK_KEY=$1
  local TEMPLATE_FILE=$2
  local CONFIG_FILE=$3
  shift 3  # Shift past the first three arguments to capture any additional parameters
  
  local REGION
  REGION=$(jq -r '.Region' $CONFIG_FILE)

  # Extract stack name from config file
  local STACK_NAME
  STACK_NAME=$(jq -r ".Stacks[\"$STACK_KEY\"]" "$CONFIG_FILE")
  
  if [ -z "$STACK_NAME" ] || [ "$STACK_NAME" == "null" ]; then
    echo "Error: Stack key '$STACK_KEY' not found in config file."
    return 1
  fi

  if [ -z "$TEMPLATE_FILE" ] || [ "$TEMPLATE_FILE" == "null" ]; then
    echo "Error: Template not provided"
    return 1
  fi
  
  # Build parameters from config file
  local PARAMETERS
  PARAMETERS=$(jq -r '.Parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' "$CONFIG_FILE")

  # Append additional parameters passed to the function
  for param in "$@"; do
    PARAMETERS="$PARAMETERS $param"
  done
  
  echo "Deploying stack '$STACK_NAME' with template '$TEMPLATE_FILE' and parameters: $PARAMETERS"

  # Deploy CloudFormation stack
  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --parameter-overrides $PARAMETERS \
    --capabilities CAPABILITY_NAMED_IAM 

  # Report the outputs to the console
  aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[*].[OutputKey, OutputValue]" \
  --output table

  # Check deployment success
  if [ $? -eq 0 ]; then
    echo "Successfully deployed stack '$STACK_NAME'."
  else
    echo "Failed to deploy stack '$STACK_NAME'."
    return 1
  fi
}

# Check if configuration file is provided as a parameter
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <config-file>"
  exit 1
fi

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
REGION=$(jq -r '.Region' $PARAMETERS_FILE)
ACCOUNT=$(jq -r '.Account' $PARAMETERS_FILE)
EXECUTION_ROLE_STACK=$(jq -r '.Stacks.ExecutionRoleStack' $PARAMETERS_FILE)
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' $PARAMETERS_FILE)
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)
CUSTOM_AUTH_STACK=$(jq -r '.Stacks.CustomAuthStack // empty' $PARAMETERS_FILE)

echo "Deploying to region: $REGION, account: $ACCOUNT, environment: $ENVIRONMENT"

# Step 1: Deploying Queues
echo "Deploying queues..."
deploy_stack QueueStack templates/queues.yaml $CONFIG_FILE
echo "✅ Complete."

# Step 2: Deploy the Role stack
echo "Deploying Role Stack..."
# This is the role that the lambda executes as
deploy_stack RoleStack templates/roles.yaml $CONFIG_FILE
if [ $? -ne 0 ]; then
  echo "Failed to deploy RoleStack stack. Exiting."
  exit 1
fi
echo "✅ Complete."


# These next two function support creating roles for deploying and executing microservices
# echo "Deploying GitHub Lambda Deployment Role Stack..."
# This is the role used to deploy the lambda functions
# deploy_stack GitHubLambdaDeployRoleStack templates/github_lambda_deploy_role.yaml $CONFIG_FILE
# if [ $? -ne 0 ]; then
#  echo "Failed to deploy GitHubLambdaDeployRoleStack stack. Exiting."
#  exit 1
# fi
# echo "Complete"
# echo "Deploying GitHub Lambda Execution Role Stack..."
# This is the role that the lambda functions for transactions (validation, broadcaster) will use
# deploy_stack GitHubLambdaExecutionRoleStack templates/github_lambda_execution_role.yaml $CONFIG_FILE
# if [ $? -ne 0 ]; then
#  echo "Failed to deploy GitHubLambdaExecutionRoleStack stack. Exiting."
#  exit 1
# fi
# echo "Complete"

# Fetch the exported Role ARN
SQS_ROLE_EXPORT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="SQSExportName") | .ParameterValue' "$CONFIG_FILE")
LAMBDA_ROLE_EXPORT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="FoxyLambdaExportName") | .ParameterValue' "$CONFIG_FILE")
ENVIRONMENT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$CONFIG_FILE")
ROLE_NAME=$(aws cloudformation list-exports --query "Exports[?Name=='${LAMBDA_ROLE_EXPORT_NAME}'].Value" --output text)
SQS_ROLE_NAME=$(aws cloudformation list-exports --query "Exports[?Name=='${SQS_ROLE_EXPORT_NAME}'].Value" --output text)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
SQS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${SQS_ROLE_NAME}"

if [ -z "$ROLE_ARN" ]; then
  echo "Failed to fetch the Foxy Lambda Execution Role ARN. Aborting."
  exit 1
fi
echo "Fetched Foxy Lambda Role ARN: $ROLE_ARN"
if [ -z "$SQS_ROLE_ARN" ]; then
  echo "Failed to fetch the Foxy SQS Execution Role ARN. Aborting."
  exit 1
fi
echo "Fetched Foxy Lambda Role ARN: $SQS_ROLE_ARN"

# Step 3: Deploy the Cognito User Pool stack
echo "Deploying Cognito User Pool stack..."
deploy_stack UserPoolStack templates/cognito_user_pool.yaml $CONFIG_FILE

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name $USER_POOL_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
  --output text \
  --region $REGION)
echo "✅ Complete."

# Step 4: Deploy the Service Accounts stack
echo "Deploying Service Accounts..."
if [ -n "$SERVICE_ACCOUNT_STACK" ]; then
  deploy_stack ServiceAccountStack templates/create_service_accounts.yaml $CONFIG_FILE "RoleArn=$ROLE_ARN" "SQSRoleArn=$SQS_ROLE_ARN"
fi
if [ $? -ne 0 ]; then
  echo "Failed to deploy ServiceAccountStack stack. Exiting."
  exit 1
fi
echo "✅ Complete."

# Step 5: Update the IAM Role stack
echo "Updating Role Stack..."
# Now that we have an RoleStack and a service account, I need to patch the role stack to add the service account role to the trust policy
deploy_stack RoleStack templates/patch.yaml $CONFIG_FILE
if [ $? -ne 0 ]; then
  echo "Failed to patch RoleStack stack. Exiting."
  exit 1
fi
echo "✅ Complete."

# Step 6: Deploy S3 Buckets
echo "Deploying S3 Buckets..."
deploy_stack S3BucketStack templates/s3_buckets.yaml $CONFIG_FILE
echo "Complete."

# Step 7: Deploy Lambda Function
echo "Deploying Lambda functions..."

#Custom Auth
deploy_function ./scripts/custom_auth_lambda.py "foxy-${ENVIRONMENT_NAME}-lambda-deployments-${ACCOUNT}" "function.zip" $ENVIRONMENT_NAME
deploy_stack CustomAuthStack templates/custom_auth_lambda.yaml $CONFIG_FILE "RoleArn=$ROLE_ARN" "UserPoolId=$USER_POOL_ID"

# this used to work in cloudformation, but I've had to move it here.  TODO: fix.

aws cognito-idp update-user-pool \
  --user-pool-id $USER_POOL_ID \
  --lambda-config "{
    \"CreateAuthChallenge\": \"arn:aws:lambda:eu-north-1:971422686568:function:foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda\",
    \"DefineAuthChallenge\": \"arn:aws:lambda:eu-north-1:971422686568:function:foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda\",
    \"VerifyAuthChallengeResponse\": \"arn:aws:lambda:eu-north-1:971422686568:function:foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda\"
  }"

CUSTOM_AUTH_LAMBDA_ARN=$(aws cloudformation describe-stacks \
  --stack-name $CUSTOM_AUTH_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionArn'].OutputValue" \
  --output text \
  --region $REGION)

# Step 8: Deploy DynamoDB Database
echo "Deploying database..."
deploy_stack DatabaseStack templates/database.yaml $CONFIG_FILE

echo "Inserting default fees..."
aws dynamodb put-item \
  --table-name "foxy_${ENVIRONMENT_NAME}_Fees" \
  --item '{
    "fee_type": {"S": "service_fee"},
    "valid_from": {"S": "2025-01-01T00:00:00Z"},
    "base_fee": {"N": "0"},
    "percentage_fee": {"N": "200"}
  }'
echo "✅ Complete."

# Step 9: Configuring API Gateway
echo "Configuring API Gateway"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
deploy_stack APIGatewayStack templates/api_gateway.yaml $CONFIG_FILE "CustomAuthLambdaArn=$CUSTOM_AUTH_LAMBDA_ARN" "DeploymentTimestamp=$TIMESTAMP"
echo "✅ Complete."

# Fetch access keys for the FoxyServiceAccount
COGNITO_USER=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$CONFIG_FILE")-FoxyServiceAccount
echo "Fetching access keys for FoxyServiceAccount: $COGNITO_USER"
ACCESS_KEYS=$(aws iam create-access-key --user-name "$COGNITO_USER")
ACCESS_KEY_ID=$(echo "$ACCESS_KEYS" | jq -r '.AccessKey.AccessKeyId')
SECRET_ACCESS_KEY=$(echo "$ACCESS_KEYS" | jq -r '.AccessKey.SecretAccessKey')

echo "Access Key ID: $ACCESS_KEY_ID"
echo "Secret Access Key: $SECRET_ACCESS_KEY"
echo "Deployment completed successfully!"
