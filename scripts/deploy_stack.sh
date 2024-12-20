#!/bin/bash

# Usage: ./deploy_stack.sh <STACK_KEY> <TEMPLATE_FILE> <CONFIG_FILE>

STACK_KEY=$1
TEMPLATE_FILE=$2
CONFIG_FILE=$3

if [ -z "$STACK_KEY" ] || [ -z "$TEMPLATE_FILE" ] || [ -z "$CONFIG_FILE" ]; then
  echo "Usage: ./deploy_stack.sh <STACK_KEY> <TEMPLATE_FILE> <CONFIG_FILE>"
  exit 1
fi

# Extract stack name from config file
STACK_NAME=$(jq -r ".Stacks[\"$STACK_KEY\"]" "$CONFIG_FILE")

if [ -z "$STACK_NAME" ] || [ "$STACK_NAME" == "null" ]; then
  echo "Error: Stack key '$STACK_KEY' not found in config file."
  exit 1
fi

# Extract parameters from config file
PARAMETERS=$(jq -r '.Parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' "$CONFIG_FILE")

# Add RoleExportName if it exists in the config file
ROLE_EXPORT_NAME=$(jq -r '.RoleExportName // empty' "$CONFIG_FILE")
if [ -n "$ROLE_EXPORT_NAME" ]; then
  PARAMETERS="$PARAMETERS ExportName=$ROLE_EXPORT_NAME"
fi

# Deploy the stack
echo "Deploying stack '$STACK_NAME' with template '$TEMPLATE_FILE' and parameters: $PARAMETERS"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --parameter-overrides $PARAMETERS \
  --capabilities CAPABILITY_NAMED_IAM

if [ $? -eq 0 ]; then
  echo "Successfully deployed stack '$STACK_NAME'."
else
  echo "Failed to deploy stack '$STACK_NAME'."
  exit 1
fi

