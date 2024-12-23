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
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack // empty' $PARAMETERS_FILE)

# Step 1: Deploy the IAM Role stack
echo "Deploying IAM Role stack..."
./scripts/deploy_stack.sh templates/cognito_lambda_role.yaml $ROLE_STACK "RoleStack"

# Step 2: Deploy the Cognito User Pool stack
echo "Deploying Cognito User Pool stack..."
./scripts/deploy_stack.sh templates/cognito_user_pool.yaml $USER_POOL_STACK "UserPoolStack"

# Step 3: Deploy the Service Accounts stack
echo "Deploying Service Accounts..."
if [ -n "$SERVICE_ACCOUNT_STACK" ]; then
  ./scripts/deploy_stack.sh templates/create_service_accounts.yaml $SERVICE_ACCOUNT_STACK "ServiceAccountStack"
else
  echo "No Service Account stack defined. Skipping deployment."
fi

# Step 4: Deploy Lambda Function
echo "Deploying Lambda function..."
LAMBDA_FUNCTION_NAME="CognitoCustomAuthLambda"
zip -q function.zip ./scripts/custom_auth_lambda.py

LAMBDA_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name $ROLE_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" \
  --output text)

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
USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name $USER_POOL_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
  --output text)

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

