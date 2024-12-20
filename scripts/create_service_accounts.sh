#!/bin/bash

# Variables
STACK_NAME="CognitoServiceAccountsStack"
REGION="eu-north-1"

# Step 1: Deploy the CloudFormation stack
echo "Deploying CloudFormation stack..."
aws cloudformation deploy \
    --template-file create_service_accounts.yaml \
    --stack-name $STACK_NAME \
    --region $REGION

# Step 2: Retrieve the CognitoServiceAccount username from the stack output
echo "Retrieving CognitoServiceAccount username..."
USER_NAME=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='UserName'].OutputValue" \
    --output text)

if [ -z "$USER_NAME" ]; then
    echo "Error: CognitoServiceAccount username not found in stack output."
    exit 1
fi

echo "CognitoServiceAccount username: $USER_NAME"

# Step 3: Create access keys for the CognitoServiceAccount
echo "Creating access keys for user $USER_NAME..."
ACCESS_KEYS=$(aws iam create-access-key --user-name $USER_NAME)

if [ $? -ne 0 ]; then
    echo "Error: Failed to create access keys."
    exit 1
fi

# Extract and display the Access Key ID and Secret Access Key
ACCESS_KEY_ID=$(echo $ACCESS_KEYS | jq -r '.AccessKey.AccessKeyId')
SECRET_ACCESS_KEY=$(echo $ACCESS_KEYS | jq -r '.AccessKey.SecretAccessKey')

echo "Access Key ID: $ACCESS_KEY_ID"
echo "Secret Access Key: $SECRET_ACCESS_KEY"

# Optional: Save credentials to a local file or configure AWS CLI
cat > ~/.aws/credentials <<EOL
[development]
aws_access_key_id = $ACCESS_KEY_ID
aws_secret_access_key = $SECRET_ACCESS_KEY
EOL

echo "Credentials saved to ~/.aws/credentials under [development] profile."

# End
echo "CognitoServiceAccount setup complete."