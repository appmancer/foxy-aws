#!/bin/bash

set -e

# Parameters
ENVIRONMENT_NAME=$1
DB_INSTANCE_CLASS="db.t3.micro"
ALLOCATED_STORAGE="20"
DB_NAME="foxydb"
REGION="us-east-1"
USE_MULTI_AZ="false"
ENABLE_IAM_AUTH="false"
SQL_FILE="./templates/schema.sql"

if [[ -z "$ENVIRONMENT_NAME" ]]; then
  echo "Usage: $0 <environment-name>"
  exit 1
fi

# Prompt for production vs. development settings
read -p "Is this a production environment? (y/n): " PRODUCTION

if [[ "$PRODUCTION" == "y" || "$PRODUCTION" == "Y" ]]; then
  USE_MULTI_AZ="true"
  ENABLE_IAM_AUTH="true"
  MASTER_PASSWORD="Placeholder@123"
  echo "Configuring for production..."
else
  MASTER_PASSWORD=$(openssl rand -base64 16) # Generate a secure random password
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
CF_TEMPLATE="rds_template_${ENVIRONMENT_NAME}.yaml"
echo "Generating CloudFormation template: $CF_TEMPLATE..."
cat <<EOF > $CF_TEMPLATE
AWSTemplateFormatVersion: "2010-09-09"
Description: RDS PostgreSQL Deployment for ${ENVIRONMENT_NAME}

Parameters:
  EnvironmentName:
    Type: String
    Default: ${ENVIRONMENT_NAME}

Resources:
  DBSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupDescription: !Sub "${ENVIRONMENT_NAME} RDS Subnet Group"
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
      MasterUsername: foxydbadmin
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
          Value: ${ENVIRONMENT_NAME}

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

echo "Loading schema"

# Install `psql` if not already installed
if ! command -v psql &> /dev/null; then
  echo "psql not found. Installing PostgreSQL client..."
  sudo yum install -y postgresql # For Amazon Linux/CloudShell
  echo "psql installed successfully."
fi

# Check if the SQL file exists
if [[ ! -f $SQL_FILE ]]; then
  echo "Error: Schema not found!"
  exit 1
fi


echo "Executing SQL commands from '$SQL_FILE'..."
PGPASSWORD=$DB_PASSWORD psql \
    --host=$DB_ENDPOINT \
    --port=$DB_PORT \
    --username=$DB_USER \
    --dbname=$DB_NAME \
    --file=$SQL_FILE

echo "SQL commands executed successfully."

# Fetch and display outputs
echo "Fetching RDS Outputs..."
DB_ENDPOINT=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='DBEndpoint'].OutputValue" --output text)
DB_PORT=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='DBPort'].OutputValue" --output text)
DB_RESOURCE_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='DBResourceId'].OutputValue" --output text)

echo "RDS Endpoint: $DB_ENDPOINT"
echo "RDS Port: $DB_PORT"

# Suggest adding details to .env for dev
if [[ "$PRODUCTION" != "y" && "$PRODUCTION" != "Y" ]]; then
  echo "Add the following to your .env file:"
  echo "DB_HOST=$DB_ENDPOINT"
  echo "DB_PORT=$DB_PORT"
  echo "DB_NAME=$DB_NAME"
  echo "DB_MASTER_PASSWORD=$MASTER_PASSWORD"
fi

# Update IAM role for Lambda (Production only)
if [[ "$PRODUCTION" == "y" || "$PRODUCTION" == "Y" ]]; then
  echo "Updating Lambda IAM role for production..."
  LAMBDA_ROLE_ARN=$(aws iam list-roles --query "Roles[?contains(RoleName, 'foxy-lambda')].Arn" --output text)
  aws iam attach-role-policy \
    --role-name $(basename $LAMBDA_ROLE_ARN) \
    --policy-arn arn:aws:iam::aws:policy/AmazonRDSFullAccess
  echo "Lambda IAM role updated for RDS IAM Authentication."
fi

