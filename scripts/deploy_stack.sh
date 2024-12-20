#!/bin/bash
set -e

STACK_NAME=$1
TEMPLATE_FILE=$2
PARAMETERS_FILE=$3

if [[ -z "$STACK_NAME" || -z "$TEMPLATE_FILE" ]]; then
  echo "Usage: $0 <stack-name> <template-file> [parameters-file]"
  exit 1
fi

if [[ -n "$PARAMETERS_FILE" ]]; then
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --parameter-overrides "$(cat "$PARAMETERS_FILE")" \
    --capabilities CAPABILITY_NAMED_IAM
else
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --capabilities CAPABILITY_NAMED_IAM
fi
