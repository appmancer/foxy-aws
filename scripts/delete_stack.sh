#!/bin/bash
set -e

STACK_NAME=$1

if [[ -z "$STACK_NAME" ]]; then
  echo "Usage: $0 <stack-name>"
  exit 1
fi

aws cloudformation delete-stack --stack-name "$STACK_NAME"
echo "Deleting stack $STACK_NAME. This may take a few minutes."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
echo "Finished"
