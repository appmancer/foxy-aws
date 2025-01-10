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

# Define table names
EVENT_STORE_TABLE="foxy_${ENVIRONMENT_NAME}_EventStore"
MATERIALIZED_VIEW_TABLE="foxy_${ENVIRONMENT_NAME}_MaterializedView"

# Define IAM role names
APP_ROLE="foxy_${ENVIRONMENT_NAME}_AppRole"
ADMIN_ROLE="foxy_${ENVIRONMENT_NAME}_AdminRole"
REPORTING_ROLE="foxy_${ENVIRONMENT_NAME}_ReportingRole"

# AWS region (update as needed)
AWS_REGION="eu-north-1"

# Create Event Store table
echo "Creating Event Store table: $EVENT_STORE_TABLE..."
aws dynamodb create-table \
    --table-name $EVENT_STORE_TABLE \
    --attribute-definitions AttributeName=EntityID,AttributeType=S AttributeName=EventID,AttributeType=S \
    --key-schema AttributeName=EntityID,KeyType=HASH AttributeName=EventID,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE \
    --region $AWS_REGION

# Create Materialized View table
echo "Creating Materialized View table: $MATERIALIZED_VIEW_TABLE..."
aws dynamodb create-table \
    --table-name $MATERIALIZED_VIEW_TABLE \
    --attribute-definitions AttributeName=UserID,AttributeType=S \
    --key-schema AttributeName=UserID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region $AWS_REGION

# Create IAM policy for App Role
APP_POLICY_NAME="${APP_ROLE}_Policy"
echo "Creating IAM policy for App Role..."
aws iam create-policy \
    --policy-name $APP_POLICY_NAME \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Action\": [
                    \"dynamodb:PutItem\",
                    \"dynamodb:UpdateItem\",
                    \"dynamodb:Query\"
                ],
                \"Resource\": [
                    \"arn:aws:dynamodb:${AWS_REGION}:*:table/$EVENT_STORE_TABLE\",
                    \"arn:aws:dynamodb:${AWS_REGION}:*:table/$MATERIALIZED_VIEW_TABLE\"
                ]
            }
        ]
    }"

# Create IAM Role for App
echo "Creating IAM Role for App..."
APP_ROLE_ARN=$(aws iam create-role \
    --role-name $APP_ROLE \
    --assume-role-policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Principal\": {\"Service\": \"lambda.amazonaws.com\"},
                \"Action\": \"sts:AssumeRole\"
            }
        ]
    }" --query "Role.Arn" --output text)

aws iam attach-role-policy \
    --role-name $APP_ROLE \
    --policy-arn "arn:aws:iam::aws:policy/$APP_POLICY_NAME"

# Create IAM policy for Admin Role
ADMIN_POLICY_NAME="${ADMIN_ROLE}_Policy"
echo "Creating IAM policy for Admin Role..."
aws iam create-policy \
    --policy-name $ADMIN_POLICY_NAME \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Action\": \"dynamodb:*\",
                \"Resource\": \"*\"
            }
        ]
    }"

# Create IAM Role for Admin
echo "Creating IAM Role for Admin..."
ADMIN_ROLE_ARN=$(aws iam create-role \
    --role-name $ADMIN_ROLE \
    --assume-role-policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Principal\": {\"Service\": \"ec2.amazonaws.com\"},
                \"Action\": \"sts:AssumeRole\"
            }
        ]
    }" --query "Role.Arn" --output text)

aws iam attach-role-policy \
    --role-name $ADMIN_ROLE \
    --policy-arn "arn:aws:iam::aws:policy/$ADMIN_POLICY_NAME"

# Create IAM policy for Reporting Role
REPORTING_POLICY_NAME="${REPORTING_ROLE}_Policy"
echo "Creating IAM policy for Reporting Role..."
aws iam create-policy \
    --policy-name $REPORTING_POLICY_NAME \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Action\": \"dynamodb:Query\",
                \"Resource\": [
                    \"arn:aws:dynamodb:${AWS_REGION}:*:table/$MATERIALIZED_VIEW_TABLE\"
                ]
            }
        ]
    }"

# Create IAM Role for Reporting
echo "Creating IAM Role for Reporting..."
REPORTING_ROLE_ARN=$(aws iam create-role \
    --role-name $REPORTING_ROLE \
    --assume-role-policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Principal\": {\"Service\": \"quicksight.amazonaws.com\"},
                \"Action\": \"sts:AssumeRole\"
            }
        ]
    }" --query "Role.Arn" --output text)

aws iam attach-role-policy \
    --role-name $REPORTING_ROLE \
    --policy-arn "arn:aws:iam::aws:policy/$REPORTING_POLICY_NAME"

# Output configuration values
echo "Configuration for $ENVIRONMENT_NAME environment:"
echo "  Event Store Table Name: $EVENT_STORE_TABLE"
echo "  Materialized View Table Name: $MATERIALIZED_VIEW_TABLE"
echo "  App Role ARN: $APP_ROLE_ARN"
echo "  Admin Role ARN: $ADMIN_ROLE_ARN"
echo "  Reporting Role ARN: $REPORTING_ROLE_ARN"
