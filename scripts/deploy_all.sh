#!/bin/bash

set -e

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
ROLE_STACK=$(jq -r '.Stacks.RoleStack' $PARAMETERS_FILE)
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' $PARAMETERS_FILE)
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack' $PARAMETERS_FILE)

# Step 1: Deploy the Role Stack
echo "Deploying IAM Role stack..."
ROLE_STACK_OUTPUT=$(aws cloudformation deploy \
  --stack-name $ROLE_STACK \
  --template-file templates/cognito_lambda_role.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides $(jq -r '.Parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' $PARAMETERS_FILE))

LAMBDA_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name $ROLE_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" \
  --output text)

echo "IAM Role ARN: $LAMBDA_ROLE_ARN"

# Step 2: Deploy the Cognito User Pool Stack
echo "Deploying Cognito User Pool stack..."
aws cloudformation deploy \
  --stack-name $USER_POOL_STACK \
  --template-file templates/cognito_user_pool.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides $(jq -r '.Parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' $PARAMETERS_FILE)

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name $USER_POOL_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
  --output text)

USER_POOL_CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name $USER_POOL_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" \
  --output text)

echo "User Pool ID: $USER_POOL_ID"
echo "User Pool Client ID: $USER_POOL_CLIENT_ID"

# Step 3: Deploy Service Accounts
echo "Deploying Service Accounts..."
aws cloudformation deploy \
  --stack-name $SERVICE_ACCOUNT_STACK \
  --template-file templates/create_service_accounts.yaml \
  --parameter-overrides RoleArn=$LAMBDA_ROLE_ARN EnvironmentName=$ENVIRONMENT

# Step 4: Deploy Lambda Function
echo "Deploying Lambda function..."
LAMBDA_FUNCTION_NAME="CognitoCustomAuthLambda"
zip -q function.zip scripts/custom_auth_lambda.py

LAMBDA_ARN=$(aws lambda create-function \
  --function-name $LAMBDA_FUNCTION_NAME \
  --runtime python3.9 \
  --role $LAMBDA_ROLE_ARN \
  --handler custom_auth_lambda.lambda_handler \
  --zip-file fileb://function.zip \
  --region $REGION \
  --query "FunctionArn" \
  --output text 2>/dev/null || \
  aws lambda update-function-code \
    --function-name $LAMBDA_FUNCTION_NAME \
    --zip-file fileb://function.zip \
    --region $REGION \
    --query "FunctionArn" \
    --output text)

echo "Lambda Function ARN: $LAMBDA_ARN"

# Step 5: Attach Lambda to Cognito Triggers
echo "Configuring Cognito User Pool triggers..."
LAMBDA_CONFIG_FILE="lambda-config.json"
cat <<EOF > $LAMBDA_CONFIG_FILE
{
    "DefineAuthChallenge": "$LAMBDA_ARN",
    "CreateAuthChallenge": "$LAMBDA_ARN",
    "VerifyAuthChallengeResponse": "$LAMBDA_ARN"
}
EOF

aws cognito-idp update-user-pool \
  --user-pool-id $USER_POOL_ID \
  --lambda-config file://$LAMBDA_CONFIG_FILE \
  --region $REGION

rm -f $LAMBDA_CONFIG_FILE function.zip

echo "Deployment completed successfully!"

