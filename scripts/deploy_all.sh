#!/bin/bash

set -e

# Function to deploy a CloudFormation stack
deploy_stack() {
  local STACK_KEY=$1
  local TEMPLATE_FILE=$2
  local CONFIG_FILE=$3

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

  # Append Role ARN if provided
  if [ -n "$ROLE_ARN" ]; then
    PARAMETERS="$PARAMETERS RoleArn=$ROLE_ARN"
  fi
  
  if [ -n "$USER_POOL_ID" ]; then
    PARAMETERS="$PARAMETERS UserPoolId=$USER_POOL_ID"
  fi
  
  echo "Deploying stack '$STACK_NAME' with template '$TEMPLATE_FILE' and parameters: $PARAMETERS"

  # Deploy CloudFormation stack
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --parameter-overrides $PARAMETERS \
    --capabilities CAPABILITY_NAMED_IAM \
    --region eu-north-1

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
ROLE_STACK=$(jq -r '.Stacks.RoleStack' $PARAMETERS_FILE)
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' $PARAMETERS_FILE)
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)
CUSTOM_AUTH_STACK=$(jq -r '.Stacks.CustomAuthStack // empty' $PARAMETERS_FILE)

# Step 1: Deploy the IAM Role stack
echo "Deploying IAM Role stacks..."
echo "Deploying Cognito Role Stack..."
# This is the role that the Cognito lambda executes as
deploy_stack CognitoRoleStack templates/cognito_lambda_role.yaml $CONFIG_FILE
if [ $? -ne 0 ]; then
  echo "Failed to deploy CognitoRoleStack stack. Exiting."
  exit 1
fi
echo "Deploying GitHub Lambda Deployment Role Stack..."
# This is the role used to deploy the lambda functions
deploy_stack GitHubLambdaDeployRoleStack templates/github_lambda_deploy_role.yaml $CONFIG_FILE
if [ $? -ne 0 ]; then
  echo "Failed to deploy GitHubLambdaDeployRoleStack stack. Exiting."
  exit 1
fi
echo "Complete"
echo "Deploying GitHub Lambda Execution Role Stack..."
# This is the role that the lambda functions for transactions (validator, broadcaster) will use
deploy_stack GitHubLambdaExecutionRoleStack templates/github_lambda_execution_role.yaml $CONFIG_FILE
if [ $? -ne 0 ]; then
  echo "Failed to deploy GitHubLambdaExecutionRoleStack stack. Exiting."
  exit 1
fi
echo "Complete"

# Fetch the exported Role ARN
ROLE_EXPORT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="ExportName") | .ParameterValue' "$CONFIG_FILE")
ENVIRONMENT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$CONFIG_FILE")
ROLE_NAME=$(aws cloudformation list-exports --query "Exports[?Name=='${ROLE_EXPORT_NAME}'].Value" --output text)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
if [ -z "$ROLE_ARN" ]; then
  echo "Failed to fetch the Cognito Lambda Execution Role ARN. Aborting."
  exit 1
fi
echo "Fetched Role ARN: $ROLE_ARN"

# Step 2: Deploy the Cognito User Pool stack
echo "Deploying Cognito User Pool stack..."
deploy_stack UserPoolStack templates/cognito_user_pool.yaml $CONFIG_FILE

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name $USER_POOL_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
  --output text \
  --region $REGION)

# Step 3: Deploy the Service Accounts stack
echo "Deploying Service Accounts..."
if [ -n "$SERVICE_ACCOUNT_STACK" ]; then
  deploy_stack ServiceAccountStack templates/create_service_accounts.yaml $CONFIG_FILE $ROLE_ARN
  
  # Fetch access keys for the CognitoServiceAccount
  COGNITO_USER=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$CONFIG_FILE")-CognitoServiceAccount
  echo "Fetching access keys for CognitoServiceAccount: $COGNITO_USER"
  ACCESS_KEYS=$(aws iam create-access-key --user-name "$COGNITO_USER")
  echo $ACCESS_KEYS
  ACCESS_KEY_ID=$(echo "$ACCESS_KEYS" | jq -r '.AccessKey.AccessKeyId')
  SECRET_ACCESS_KEY=$(echo "$ACCESS_KEYS" | jq -r '.AccessKey.SecretAccessKey')
  SERVICE_ACCOUNT_ARN="arn:aws:iam::971422686568:user/${ENVIRONMENT_NAME}-CognitoServiceAccount"

  # Generate trust-policy.json dynamically
  cat > trust-policy.json <<-EOL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${SERVICE_ACCOUNT_ARN}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOL

  # Update the trust policy
  echo "Updating trust policy for CognitoLambdaExecutionRole..."
  aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document file://trust-policy.json
  if [ $? -ne 0 ]; then
    echo "Failed to update trust policy. Exiting."
    exit 1
  fi

  if [ $? -ne 0 ]; then
    echo "Failed to deploy service account stack. Exiting."
    exit 1
  fi
else
  echo "No Service Account stack defined. Skipping deployment."
fi

# Step n: Deploy S3 Buckets
echo "Deploying S3 Buckets..."
deploy_stack S3BucketStack templates/s3_buckets.yaml $CONFIG_FILE
echo "Complete."

# Step 4: Deploy Lambda Function
echo "Deploying Lambda function..."
# Define variables
BUCKET_NAME="foxy-${ENVIRONMENT_NAME}-lambda-deployments-${ACCOUNT}"
ZIP_FILE="function.zip"
S3_KEY="lambda/${ZIP_FILE}"

LAMBDA_FUNCTION_NAME="foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda"
zip -q -j $ZIP_FILE ./scripts/custom_auth_lambda.py

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

deploy_stack CustomAuthStack templates/custom_auth_lambda.yaml $CONFIG_FILE

# this used to work in cloudformation, but I've had to move it here.  TODO: fix.

aws cognito-idp update-user-pool \
  --user-pool-id $USER_POOL_ID \
  --lambda-config "{
    \"CreateAuthChallenge\": \"arn:aws:lambda:eu-north-1:971422686568:function:foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda\",
    \"DefineAuthChallenge\": \"arn:aws:lambda:eu-north-1:971422686568:function:foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda\",
    \"VerifyAuthChallengeResponse\": \"arn:aws:lambda:eu-north-1:971422686568:function:foxy-${ENVIRONMENT_NAME}-CognitoCustomAuthLambda\"
  }"

rm -f $ZIP_FILE
echo "Cleaned up local $ZIP_FILE"

# Step 5: Deploy DynamoDB Database
echo "Deploying database..."
deploy_stack DatabaseStack templates/database.yaml $CONFIG_FILE
echo "Complete."

# Step 6: Deploying Queues
echo "Deploying queues..."
deploy_stack QueueStack templates/queues.yaml $CONFIG_FILE
echo "Complete."

# Cleanup
rm -f $LAMBDA_CONFIG_FILE

echo "Access Key ID: $ACCESS_KEY_ID"
echo "Secret Access Key: $SECRET_ACCESS_KEY"
echo "Deployment completed successfully!"
