# Foxy AWS CloudFormation Deployment

This repository contains a set of CloudFormation templates and deployment scripts to create and manage the infrastructure for Foxy, a project with AWS resources such as Cognito, IAM roles, DynamoDB, and service accounts. The deployment process is fully automated and supports multiple environments (e.g., development, staging, production).

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Folder Structure](#folder-structure)
3. [Configuration](#configuration)
4. [Deployment Scripts](#deployment-scripts)
5. [How to Deploy](#how-to-deploy)
6. [Access Key Retrieval](#access-key-retrieval)
7. [Error Troubleshooting](#error-troubleshooting)

---

## Prerequisites

Ensure the following tools are installed and configured on your system before proceeding:

1. [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
2. [jq](https://stedolan.github.io/jq/) for JSON parsing
3. Proper AWS credentials with permissions to create and manage CloudFormation stacks, IAM users, roles, policies, DynamoDB tables, and Lambda functions.

Run the following command to verify your AWS CLI credentials:

```bash
aws sts get-caller-identity
```

---

## Folder Structure

```
.
├── config/
│   └── dev-parameters.json         # Configuration file for the development environment
├── scripts/
│   ├── deploy_stack.sh            # Script to deploy a single stack
│   ├── deploy_all.sh              # Script to deploy all stacks
│   ├── delete_all.sh              # Script to delete all stacks
│   └── cleanup_security_groups.sh # Script to clean up unused security groups
├── templates/
│   ├── cognito_lambda_role.yaml   # CloudFormation template for Cognito Lambda execution role
│   ├── cognito_user_pool.yaml     # CloudFormation template for Cognito User Pool
│   ├── dynamodb.yaml              # CloudFormation template for DynamoDB tables
│   └── create_service_accounts.yaml # CloudFormation template for service accounts
└── README.md                      # This file
```

---

## Configuration

### Parameter File
Each environment requires a parameter file in JSON format, stored in the `config/` directory. Below is an example `dev-parameters.json`:

```json
{
  "Environment": "Development",
  "Region": "eu-north-1",
  "Stacks": {
    "RoleStack": "foxy-role",
    "UserPoolStack": "foxy-dev",
    "ServiceAccountStack": "foxy-service-accounts",
    "DatabaseStack": "foxy-dev-dynamodb"
  },
  "Parameters": [
    {
      "ParameterKey": "EnvironmentName",
      "ParameterValue": "dev"
    },
    {
      "ParameterKey": "CognitoUserPoolName",
      "ParameterValue": "FoxyDevUserPool"
    },
    {
      "ParameterKey": "ExportName",
      "ParameterValue": "dev-CognitoLambdaExecutionRoleName"
    }
  ]
}
```

---

## Deployment Scripts

### deploy_stack.sh
Deploy a single CloudFormation stack using this script.

```bash
./scripts/deploy_stack.sh <STACK_KEY> <TEMPLATE_FILE> <CONFIG_FILE>
```

**Example:**

```bash
./scripts/deploy_stack.sh RoleStack templates/cognito_lambda_role.yaml config/dev-parameters.json
```

### deploy_all.sh
Deploy all required stacks in the correct order.

```bash
./scripts/deploy_all.sh <CONFIG_FILE>
```

**Example:**

```bash
./scripts/deploy_all.sh config/dev-parameters.json
```

### delete_all.sh
Delete all stacks for a specific environment.

```bash
./scripts/delete_all.sh <CONFIG_FILE>
```

**Example:**

```bash
./scripts/delete_all.sh config/dev-parameters.json
```

### cleanup_security_groups.sh
Deletes all unused security groups.

```bash
./scripts/cleanup_security_groups.sh
```

---

## How to Deploy

1. Ensure your parameter file (e.g., `dev-parameters.json`) is correctly configured.
2. Run the `deploy_all.sh` script:

   ```bash
   ./scripts/deploy_all.sh config/dev-parameters.json
   ```

3. Verify the stacks are created by checking the AWS CloudFormation console or running:

   ```bash
   aws cloudformation list-stacks --query "StackSummaries[?StackStatus=='CREATE_COMPLETE']"
   ```

4. Retrieve the generated access keys (if applicable) for service accounts.

---

## Access Key Retrieval

The script will automatically fetch access keys for the created `CognitoServiceAccount` and display them after stack creation. Example output:

```
Access Key ID: AKIAIOSFODNN7EXAMPLE
Secret Access Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

Save these securely, as they will not be shown again.

---

## Error Troubleshooting

### Common Errors

#### Unresolved Resource Dependencies
Ensure the stacks are deployed in the correct order:

1. RoleStack
2. UserPoolStack
3. DatabaseStack (DynamoDB)
4. ServiceAccountStack

#### No Export Named Error
Ensure the `ExportName` parameter in `config/<environment>-parameters.json` matches the exported name from the `RoleStack` template.

### Debugging Tips
- Use the AWS CLI to inspect stack events:

  ```bash
  aws cloudformation describe-stack-events --stack-name <STACK_NAME>
  ```

- Check the exported values:

  ```bash
  aws cloudformation list-exports
  ```

- Verify S3 bucket file existence before deployment:

  ```bash
  aws s3 ls s3://<bucket-name>/lambda/function.zip
  ```

---

## Contributions

Feel free to submit issues or pull requests to improve the deployment process.

---

## License

This project is licensed under the MIT License.

