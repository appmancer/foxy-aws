#!/bin/bash

set -e

# Parameters

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
ENVIRONMENT_NAME=$(jq -r '.Parameters[] | select(.ParameterKey=="EnvironmentName") | .ParameterValue' "$CONFIG_FILE")
ROLE_STACK=$(jq -r '.Stacks.RoleStack' $PARAMETERS_FILE)

DB_INSTANCE_CLASS="db.t3.micro"
ALLOCATED_STORAGE="20"
DB_USER="foxydbadmin"
DB_NAME="foxydb"
REGION="us-east-1"
USE_MULTI_AZ="false"
ENABLE_IAM_AUTH="true"
SQL_FILE="./templates/schema.sql"


generate_master_password() {
  openssl rand -base64 16 | tr -d '/@" ' | cut -c1-16
}

# Prompt for production vs. development settingsDB_USER
read -p "Is this a production environment? (y/n): " PRODUCTION

if [[ "$PRODUCTION" == "y" || "$PRODUCTION" == "Y" ]]; then
  USE_MULTI_AZ="true"
  ENABLE_IAM_AUTH="true"
  MASTER_PASSWORD="Placeholder@123"
  echo "Configuring for production..."
else
  MASTER_PASSWORD=$(generate_master_password)
  echo "Generated password: $MASTER_PASSWORD"
  ENABLE_IAM_AUTH="false"
  echo "Configuring for development..."
fi

# Retrieve default VPC ID
echo "Retrieving default VPC ID..."
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`true\`].VpcId" --output text)
if [[ -z "$VPC_ID" ]]; then
  echo "No default VPC found!"
  exit 1
fi
echo "Default VPC ID: $VPC_ID"

# Retrieve Subnet IDs
echo "Retrieving Subnets for VPC: $VPC_ID..."
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text)
if [[ -z "$SUBNET_IDS" ]]; then
  echo "No subnets found in VPC: $VPC_ID"
  exit 1
fi
SUBNET_ARRAY=($SUBNET_IDS)
echo "Subnets: ${SUBNET_ARRAY[@]}"

# Retrieve Default Security Group ID
echo "Retrieving default Security Group for VPC: $VPC_ID..."
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" --query "SecurityGroups[?GroupName=='default'].GroupId" --output text)
if [[ -z "$SG_ID" ]]; then
  echo "No default security group found in VPC: $VPC_ID"
  exit 1
fi
echo "Default Security Group ID: $SG_ID"

echo "Retrieving default monitoring role"
MONITORING_ROLE_ARN=$(aws cloudformation list-exports --query "Exports[?Name=='${ENVIRONMENT_NAME}-RDSMonitoringRoleArn'].Value" --output text)
if [[ -z "$MONITORING_ROLE_ARN" ]]; then
  echo "Error: Could not retrieve RDS Monitoring Role ARN."
  exit 1
fi

# Generate a CloudFormation template dynamically
CF_TEMPLATE="rds_template_${ENVIRONMENT}.yaml"
echo "Generating CloudFormation template: $CF_TEMPLATE..."
cat <<EOF > $CF_TEMPLATE
AWSTemplateFormatVersion: "2010-09-09"
Description: RDS PostgreSQL Deployment for ${ENVIRONMENT}

Parameters:
  EnvironmentName:
    Type: String
    Default: ${ENVIRONMENT}

Resources:
  DBSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupDescription: !Sub "${ENVIRONMENT} RDS Subnet Group"
      SubnetIds:
        - ${SUBNET_ARRAY[0]}
        - ${SUBNET_ARRAY[1]}
        - ${SUBNET_ARRAY[2]}

  RDSInstance:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceClass: ${DB_INSTANCE_CLASS}
      AllocatedStorage: ${ALLOCATED_STORAGE}
      Engine: postgres
      DBName: ${DB_NAME}
      MasterUsername: ${DB_USER}
      MasterUserPassword: ${MASTER_PASSWORD}
      VPCSecurityGroups:
        - ${SG_ID}
      DBSubnetGroupName: !Ref DBSubnetGroup
      StorageEncrypted: true
      MultiAZ: ${USE_MULTI_AZ}
      EnableIAMDatabaseAuthentication: ${ENABLE_IAM_AUTH}
      PubliclyAccessible: false
      BackupRetentionPeriod: 7
      MonitoringInterval: 60
      MonitoringRoleArn: ${MONITORING_ROLE_ARN}
      EnablePerformanceInsights: ${ENABLE_IAM_AUTH}
      Tags:
        - Key: Environment
          Value: ${ENVIRONMENT}

Outputs:
  DBEndpoint:
    Description: The endpoint of the RDS instance
    Value: !GetAtt RDSInstance.Endpoint.Address
  DBPort:
    Description: The port of the RDS instance
    Value: !GetAtt RDSInstance.Endpoint.Port
  DBResourceId:
    Description: The unique resource identifier for IAM authentication
    Value: !GetAtt RDSInstance.DbiResourceId
EOF

# Deploy the stack
STACK_NAME="${ENVIRONMENT_NAME}-rds-stack"
echo "Deploying CloudFormation stack: $STACK_NAME..."
aws cloudformation deploy \
  --stack-name $STACK_NAME \
  --template-file $CF_TEMPLATE \
  --parameter-overrides EnvironmentName=$ENVIRONMENT_NAME \
  --capabilities CAPABILITY_NAMED_IAM

# Fetch and display outputs
echo "Fetching RDS Outputs..."
DB_ENDPOINT=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='DBEndpoint'].OutputValue" --output text)
DB_PORT=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='DBPort'].OutputValue" --output text)
DB_RESOURCE_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='DBResourceId'].OutputValue" --output text)

echo "RDS Endpoint: $DB_ENDPOINT"
echo "RDS Port: $DB_PORT"

echo "Getting the LambdaRDSAccessRole ARN"
DATABASE_ACCESS_ROLE_ARN=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='DatabaseAccessRole'].OutputValue" \
    --output text)
echo $DATABASE_ACCESS_ROLE_ARN

echo "Creating service user lambda"
CREATE_USER_FUNCTION_NAME "create-user"
zip -q -j create_user_lambda.zip ./scripts/create_user_lambda.py"

aws lambda create-function \
    --function-name $CREATE_USER_FUNCTION_NAME \
    --runtime python3.9 \
    --role $DATABASE_ACCESS_ROLE_ARN \
    --handler create_user_lambda.lambda_handler \
    --timeout 15 \
    --memory-size 128 \
    --zip-file fileb://create_user_lambda.zip \
    --environment "Variables={DB_HOST=$DB_ENDPOINT,DB_PORT=$DB_PORT,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$MASTER_PASSWORD}"

echo "Executing lambda to create service user"
echo "Invoking Lambda function to create the database user..."
aws lambda invoke \
    --function-name $CREATE_USER_FUNCTION_NAME \
    --log-type Tail \
    --query 'LogResult' \
    --output text \
    response.json | base64 -d

# Check the response for success
if grep -q '"statusCode": 200' response.json; then
    echo "Lambda executed successfully. Database user created."
   
   # Clean up temporary files
   rm -f response.json
else
    echo "Error: Lambda execution failed. Check response.json or CloudWatch logs for details."
    exit 1
fi
 
echo "Cleaning up the temporary Lambda function..."
aws lambda delete-function --function-name $CREATE_USER_FUNCTION_NAME
echo "Temporary Lambda function deleted."

echo "Creating the lambda to execute sql..."
EXECUTE_SQL_FUNCTION_NAME "execute_sql"
zip -q -j execute_sql_lambda.zip ./scripts/execute_sql_lambda.py"

aws lambda create-function \
    --function-name $EXECUTE_SQL_FUNCTION_NAME \
    --runtime python3.9 \
    --role $DATABASE_ACCESS_ROLE_ARN \
    --handler execute_sql_lambda.lambda_handler \
    --timeout 15 \
    --memory-size 128 \
    --zip-file fileb://execute_sql_lambda.zip 

echo "Lambda creation complete"

echo "Creating S3 buckets"
BUCKET_PREFIX="rds-schema-deployments"
BUCKET_NAME="${BUCKET_PREFIX}-${ENVIRONMENT}"
VPC_CIDR="172.31.0.0/16"
TEMPLATE_FILE="./templates/bucket-policy-template.json"
POLICY_FILE="bucket-policy.json"

echo "Creating S3 bucket: $BUCKET_NAME in $REGION..."

if [[ ! -f $TEMPLATE_FILE ]]; then
  echo "Error: Template file '$TEMPLATE_FILE' not found."
  exit 1
fi

# Create the bucket
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $REGION \
    --create-bucket-configuration LocationConstraint=$REGION

echo "Generating policy for bucket: $BUCKET_NAME..."
sed "s/{{BUCKET_NAME}}/$BUCKET_NAME/g; s/{{VPC_CIDR}}/$VPC_CIDR/g" $TEMPLATE_FILE > $POLICY_FILE
echo "Applying bucket policies for $BUCKET_NAME..."
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file://$POLICY_FILE

echo "S3 bucket $BUCKET_NAME created and secured."

echo "Copying schema to bucket"
aws s3 cp ./schema.sql s3://$BUCKET_NAME/
echo "Schema complete"
echo "Check for success by running:aws logs tail /aws/lambda/execute_sql --follow"

# Suggest adding details to .env for dev
if [[ "$PRODUCTION" != "y" && "$PRODUCTION" != "Y" ]]; then
  echo "Add the following to your .env file:"
  echo "DB_HOST=$DB_ENDPOINT"
  echo "DB_PORT=$DB_PORT"
  echo "DB_NAME=$DB_NAME"
  echo "DB_MASTER_PASSWORD=$MASTER_PASSWORD"
fi


