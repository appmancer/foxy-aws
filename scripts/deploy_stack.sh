#!/bin/bash

# Usage: ./deploy_stack.sh <STACK_KEY> <TEMPLATE_FILE> <CONFIG_FILE> [ROLE_ARN]

STACK_KEY=$1
TEMPLATE_FILE=$2
CONFIG_FILE=$3
ROLE_ARN=$4

if [ -z "$STACK_KEY" ] || [ -z "$TEMPLATE_FILE" ] || [ -z "$CONFIG_FILE" ]; then
  echo "Usage: ./deploy_stack.sh <STACK_KEY> <TEMPLATE_FILE> <CONFIG_FILE> [ROLE_ARN]"
  exit 1
fi

STACK_NAME=$(jq -r ".Stacks[\"$STACK_KEY\"]" "$CONFIG_FILE")

if [ -z "$STACK_NAME" ] || [ "$STACK_NAME" == "null" ]; then
  echo "Error: Stack key '$STACK_KEY' not found in config file."
  exit 1
fi

PARAMETERS=$(jq -r '.Parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' "$CONFIG_FILE")

# Append the Role ARN if provided
if [ -n "$ROLE_ARN" ]; then
  PARAMETERS="$PARAMETERS RoleArn=$ROLE_ARN"
fi

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

