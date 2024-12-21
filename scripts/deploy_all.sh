#!/bin/bash

CONFIG_FILE=$1

if [ -z "$CONFIG_FILE" ]; then
  echo "Usage: ./deploy_all.sh <CONFIG_FILE>"
  exit 1
fi

echo "Deploying role stack..."
./scripts/deploy_stack.sh RoleStack templates/cognito_lambda_role.yaml "$CONFIG_FILE"
if [ $? -ne 0 ]; then
  echo "Failed to deploy RoleStack. Aborting."
  exit 1
fi

# Fetch the exported Role ARN
ROLE_ARN=$(aws cloudformation list-exports --query "Exports[?Name=='$(jq -r '.Parameters[] | select(.ParameterKey=="ExportName") | .ParameterValue' $CONFIG_FILE)'].Value" --output text)
if [ -z "$ROLE_ARN" ]; then
  echo "Failed to fetch the Cognito Lambda Execution Role ARN. Aborting."
  exit 1
fi
echo "Fetched Role ARN: $ROLE_ARN"

echo "Deploying user pool stack..."
./scripts/deploy_stack.sh UserPoolStack templates/cognito_user_pool.yaml "$CONFIG_FILE"
if [ $? -ne 0 ]; then
  echo "Failed to deploy UserPoolStack. Aborting."
  exit 1
fi

echo "Deploying service account stack..."
./scripts/deploy_stack.sh ServiceAccountStack templates/create_service_accounts.yaml "$CONFIG_FILE" "$ROLE_ARN"
if [ $? -ne 0 ]; then
  echo "Failed to deploy ServiceAccountStack. Aborting."
  exit 1
fi

echo "All stacks deployed successfully."

