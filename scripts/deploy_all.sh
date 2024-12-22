#!/bin/bash

# Deploy role stack
echo "Deploying role stack..."
./scripts/deploy_stack.sh RoleStack templates/cognito_lambda_role.yaml config/dev-parameters.json
if [ $? -ne 0 ]; then
  echo "Failed to deploy role stack. Exiting."
  exit 1
fi
echo "Successfully deployed role stack."

# Deploy user pool stack
echo "Deploying user pool stack..."
./scripts/deploy_stack.sh UserPoolStack templates/cognito_user_pool.yaml config/dev-parameters.json
if [ $? -ne 0 ]; then
  echo "Failed to deploy user pool stack. Exiting."
  exit 1
fi
echo "Successfully deployed user pool stack."

# Deploy service account stack
echo "Deploying service account stack..."
./scripts/deploy_stack.sh ServiceAccountStack templates/create_service_accounts.yaml config/dev-parameters.json
if [ $? -ne 0 ]; then
  echo "Failed to deploy service account stack. Exiting."
  exit 1
fi
echo "Successfully deployed service account stack."

# Deploy additional policies for Cognito Lambda Execution Role
echo "Deploying additional policies for Cognito Lambda Execution Role..."
./scripts/deploy_stack.sh CognitoLambdaAdditionalPolicies templates/update_aws_policies.yaml config/dev-parameters.json
if [ $? -ne 0 ]; then
  echo "Failed to deploy additional policies for Cognito Lambda Execution Role. Exiting."
  exit 1
fi
echo "Successfully deployed additional policies for Cognito Lambda Execution Role."

echo "All stacks deployed successfully."

