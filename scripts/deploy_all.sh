#!/bin/bash

# Usage: ./deploy_all.sh <CONFIG_FILE>

CONFIG_FILE=$1

if [ -z "$CONFIG_FILE" ]; then
  echo "Usage: ./deploy_all.sh <CONFIG_FILE>"
  exit 1
fi

# Retrieve stack keys from the config file
ROLE_STACK_KEY="RoleStack"
USER_POOL_STACK_KEY="UserPoolStack"
SERVICE_ACCOUNT_STACK_KEY="ServiceAccountStack"

# Templates
ROLE_TEMPLATE="templates/cognito_lambda_role.yaml"
USER_POOL_TEMPLATE="templates/cognito_user_pool.yaml"
SERVICE_ACCOUNT_TEMPLATE="templates/create_service_accounts.yaml"

# Deploy stacks
echo "Deploying role stack..."
./scripts/deploy_stack.sh "$ROLE_STACK_KEY" "$ROLE_TEMPLATE" "$CONFIG_FILE"

if [ $? -ne 0 ]; then
  echo "Failed to deploy the role stack. Aborting."
  exit 1
fi

echo "Deploying user pool stack..."
./scripts/deploy_stack.sh "$USER_POOL_STACK_KEY" "$USER_POOL_TEMPLATE" "$CONFIG_FILE"

if [ $? -ne 0 ]; then
  echo "Failed to deploy the user pool stack. Aborting."
  exit 1
fi

# Check if the ServiceAccountStack exists in the configuration
SERVICE_ACCOUNT_STACK_NAME=$(jq -r ".Stacks[\"$SERVICE_ACCOUNT_STACK_KEY\"]" "$CONFIG_FILE")

if [ "$SERVICE_ACCOUNT_STACK_NAME" != "null" ]; then
  echo "Deploying service account stack..."
  ./scripts/deploy_stack.sh "$SERVICE_ACCOUNT_STACK_KEY" "$SERVICE_ACCOUNT_TEMPLATE" "$CONFIG_FILE"

  if [ $? -ne 0 ]; then
    echo "Failed to deploy the service account stack. Aborting."
    exit 1
  fi
else
  echo "No service account stack defined in the configuration. Skipping."
fi

echo "All stacks deployed successfully."
