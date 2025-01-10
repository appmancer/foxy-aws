
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

# Define resource names
EVENT_STORE_TABLE="foxy_${ENVIRONMENT_NAME}_EventStore"
MATERIALIZED_VIEW_TABLE="foxy_${ENVIRONMENT_NAME}_MaterializedView"
APP_ROLE="foxy_${ENVIRONMENT_NAME}_AppRole"
ADMIN_ROLE="foxy_${ENVIRONMENT_NAME}_AdminRole"
REPORTING_ROLE="foxy_${ENVIRONMENT_NAME}_ReportingRole"
APP_POLICY_NAME="foxy_${ENVIRONMENT_NAME}_Policy"
ADMIN_POLICY_NAME="foxy_${ENVIRONMENT_NAME}_Policy"
REPORTING_POLICY_NAME="foxy_${ENVIRONMENT_NAME}_Policy"

# AWS region (update as needed)
AWS_REGION="eu-north-1"

# Function to delete a DynamoDB table
delete_table() {
  TABLE_NAME=$1
  echo "Deleting DynamoDB table: $TABLE_NAME..."
  aws dynamodb delete-table --table-name $TABLE_NAME --region $AWS_REGION
  echo "Waiting for table $TABLE_NAME to be deleted..."
  aws dynamodb wait table-not-exists --table-name $TABLE_NAME --region $AWS_REGION
}

# Delete tables
delete_table $EVENT_STORE_TABLE
delete_table $MATERIALIZED_VIEW_TABLE

# Function to detach and delete an IAM policy
delete_policy() {
  POLICY_NAME=$1
  echo "Deleting IAM policy: $POLICY_NAME..."
  POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
  if [ -n "$POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn $POLICY_ARN
    echo "Deleted policy: $POLICY_NAME"
  else
    echo "Policy $POLICY_NAME not found. Skipping."
  fi
}

# Function to detach and delete an IAM role
delete_role() {
  ROLE_NAME=$1
  echo "Deleting IAM role: $ROLE_NAME..."
  # Detach all policies from the role
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[].PolicyArn" --output text)
  for POLICY_ARN in $ATTACHED_POLICIES; do
    echo "Detaching policy $POLICY_ARN from role $ROLE_NAME..."
    aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
  done
  # Delete the role
  aws iam delete-role --role-name $ROLE_NAME
  echo "Deleted role: $ROLE_NAME"
}

# Delete policies
delete_policy $APP_POLICY_NAME
delete_policy $ADMIN_POLICY_NAME
delete_policy $REPORTING_POLICY_NAME

# Delete roles
delete_role $APP_ROLE
delete_role $ADMIN_ROLE
delete_role $REPORTING_ROLE

# Output cleanup confirmation
echo "All resources for environment $ENVIRONMENT_NAME have been deleted."
