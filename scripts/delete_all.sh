#!/bin/bash

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <parameter-file>"
    exit 1
fi

PARAMETERS_FILE="$1"

if [[ ! -f "$PARAMETERS_FILE" ]]; then
    echo "Error: Parameters file $PARAMETERS_FILE not found."
    exit 1
fi

echo "Loading configuration from $PARAMETERS_FILE..."
ENVIRONMENT=$(jq -r '.Environment' "$PARAMETERS_FILE")
REGION=$(jq -r '.Region' "$PARAMETERS_FILE")
ROLE_STACK=$(jq -r '.Stacks.RoleStack' "$PARAMETERS_FILE")
USER_POOL_STACK=$(jq -r '.Stacks.UserPoolStack' "$PARAMETERS_FILE")
SERVICE_ACCOUNT_STACK=$(jq -r '.Stacks.ServiceAccountStack' "$PARAMETERS_FILE")

echo "Environment: $ENVIRONMENT"
echo "Region: $REGION"

STACKS=(
    "$USER_POOL_STACK"
    "$ROLE_STACK"
)

if [[ "$SERVICE_ACCOUNT_STACK" != "null" ]]; then
    STACKS+=("$SERVICE_ACCOUNT_STACK")
fi

for STACK_NAME in "${STACKS[@]}"; do
    echo "Deleting stack: $STACK_NAME"
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

    echo "Waiting for stack deletion to complete: $STACK_NAME"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"

    if [[ $? -eq 0 ]]; then
        echo "Successfully deleted stack: $STACK_NAME"
    else
        echo "Failed to delete stack: $STACK_NAME. Check the CloudFormation console for details."
        exit 1
    fi
done

echo "All stacks deleted successfully for $ENVIRONMENT environment!"
