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
./scripts/deploy_stack.sh RoleStack templates/cognito_lambda_role.yaml $CONFIG_FILE
if [ $? -ne 0 ]; then
  echo "Failed to deploy role stack. Exiting."
  exit 1
fi

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

echo "Variables for deployment:"
echo "ROLE_EXPORT_NAME=$ROLE_EXPORT_NAME"
echo "ENVIRONMENT_NAME=$ENVIRONMENT_NAME"
echo "ROLE_NAME=$ROLE_NAME"
echo "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID"
echo "ROLE_ARN=$ROLE_ARN"
echo "ENVIRONMENT=$ENVIRONMENT"
echo "REGION=$REGION"
echo "ROLE_STACK=$ROLE_STACK"
echo "USER_POOL_STACK=$USER_POOL_STACK"
echo "SERVICE_ACCOUNT_STACK=$SERVICE_ACCOUNT_STACK"

# Step 2: Deploy the Cognito User Pool stack
echo "Deploying Cognito User Pool stack..."
./scripts/deploy_stack.sh UserPoolStack templates/cognito_user_pool.yaml $CONFIG_FILE

# Step 3: Deploy the Service Accounts stack
echo "Deploying Service Accounts..."
if [ -n "$SERVICE_ACCOUNT_STACK" ]; then
  ./scripts/deploy_stack.sh ServiceAccountStack templates/create_service_accounts.yaml $CONFIG_FILE $ROLE_ARN

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

  echo "Generated dynamic trust-policy.json:"
  cat trust-policy.json

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

# Step 4: Deploy Lambda Function
echo "Deploying Lambda function..."
LAMBDA_FUNCTION_NAME="CognitoCustomAuthLambda"
zip -q -j function.zip ./scripts/custom_auth_lambda.py

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

echo "Configuring Cognito User Pool triggers..."
USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name $USER_POOL_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
  --output text)

if [ -z "$USER_POOL_ID" ]; then
  echo "Error: Could not fetch User Pool ID. Exiting."
  exit 1
fi

LAMBDA_CONFIG_FILE="lambda-config.json"
cat <<EOF > $LAMBDA_CONFIG_FILE
{
    "DefineAuthChallenge": "$LAMBDA_ARN",
    "CreateAuthChallenge": "$LAMBDA_ARN",
    "VerifyAuthChallengeResponse": "$LAMBDA_ARN"
}
EOF

echo "Lambda configuration for Cognito Triggers:"
cat $LAMBDA_CONFIG_FILE

echo "Adding resource-based access policies for Lambda triggers"
aws lambda add-permission \
    --function-name $LAMBDA_FUNCTION_NAME \
    --statement-id CognitoInvokePermission \
    --action lambda:InvokeFunction \
    --principal cognito-idp.amazonaws.com \
    --source-arn arn:aws:cognito-idp:$REGION:$AWS_ACCOUNT_ID:userpool/$USER_POOL_ID
    
    
echo "Updating Lambda IAM role with access policy..."
LAMBDA_RDS_ROLE_ARN=$(aws iam list-roles --query "Roles[?contains(RoleName, 'foxy-role-DatabaseAccessRole')].Arn" --output text)
aws iam attach-role-policy \
    --role-name $(basename $LAMBDA_RDS_ROLE_ARN) \
    --policy-arn arn:aws:iam::aws:policy/AmazonRDSFullAccess
echo "Lambda IAM role updated for RDS IAM Authentication."


echo "Updating Cognito User Pool with triggers..."
UPDATE_OUTPUT=$(aws cognito-idp update-user-pool \
  --user-pool-id $USER_POOL_ID \
  --lambda-config file://$LAMBDA_CONFIG_FILE \
  --region $REGION 2>&1)

if [ $? -ne 0 ]; then
  echo "Error: Failed to update User Pool triggers."
  echo "AWS CLI Output:"
  echo "$UPDATE_OUTPUT"
  exit 1
else
  echo "Successfully updated User Pool triggers."
  echo "AWS CLI Output:"
  echo "$UPDATE_OUTPUT"
fi

# Cleanup
rm -f $LAMBDA_CONFIG_FILE

echo "Starting database build"
./scripts/deploy_rds.sh $CONFIG_FILE

echo "Created Lambda function"
aws lambda list-functions --query "Functions[*].[FunctionName]" --output table

echo "Deployment completed successfully!"

