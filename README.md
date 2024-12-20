# Cognito User Pool with Default Group and Lambda Trigger

This repository contains a CloudFormation template to create an AWS Cognito User Pool with a **default user group** and a **Lambda function** to automatically assign new users to this group upon creation. The template is designed for applications that use Cognito for **authorization (authz)** rather than authentication (authn).

## Features

- Creates a Cognito User Pool with:
  - Required attributes ('email', 'phone_number', 'name').
  - Auto-verified attributes for 'email' and 'phone_number'.
  - No password-based authentication.
- Configures a default user group ('Default') with a dynamically created IAM role.
- Deploys a Lambda function that:
  - Adds new users to the 'Default' group using the 'PostConfirmation' trigger.
- Uses IAM roles with least privilege for Lambda and Cognito group operations.

---

## Deployment

### Prerequisites
1. **AWS CLI**: Install and configure the AWS CLI with proper credentials and region.
   - [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
   - Configure the CLI:
     '''bash
     aws configure
     '''
2. **CloudFormation Capabilities**: Ensure your AWS account has permission to deploy CloudFormation stacks and create IAM resources.

### Steps to Deploy
1. Clone this repository:
   '''bash
   git clone https://github.com/your-repo-name.git
   cd your-repo-name
   '''

2. Deploy the CloudFormation stack:
   '''bash
   aws cloudformation deploy \
     --template-file template.yml \
     --stack-name CognitoUserPoolStack \
     --capabilities CAPABILITY_NAMED_IAM
   '''

3. Monitor the deployment progress in the AWS Management Console under the **CloudFormation** service.

---

## Repository Structure

'''
infrastructure/
├── templates/                 # Directory for CloudFormation templates
│   ├── cognito_user_pool.yml  # Your Cognito User Pool template
│   ├── networking.yml         # Networking resources (if needed)
│   └── other_services.yml     # Other resources
├── scripts/                   # Helper scripts (e.g., validation, deployments)
├── pipelines/                 # CI/CD pipeline definitions (e.g., GitHub Actions, CodePipeline)
└── README.md                  # Documentation
'''

---

## How It Works

1. **Cognito User Pool**:
   - A new User Pool ('ProductionUserPool') is created with attributes like 'email', 'phone_number', and 'name'.

2. **Default Group**:
   - A 'Default' group is created with a dynamically generated IAM role for baseline permissions.
   - The IAM role includes a sample policy (e.g., 's3:ListBucket' and 'dynamodb:Query').

3. **PostConfirmation Lambda**:
   - A Lambda function is triggered after user sign-up confirmation to add the user to the 'Default' group.

4. **IAM Roles**:
   - The 'DefaultGroupRole' provides baseline permissions for users in the default group.
   - The 'LambdaExecutionRole' allows the Lambda function to manage Cognito group assignments.

---

## Customization

1. **Default Group Policy**:
   - Modify the 'DefaultGroupPolicy' in the 'DefaultGroupRole' resource to align with your application’s requirements.

2. **Lambda Function Logic**:
   - Extend the Lambda function to handle additional use cases, such as logging or notifying administrators.

3. **Attributes**:
   - Add custom attributes to the 'Schema' property of the User Pool for more user metadata.

4. **Additional Groups**:
   - Use the 'AWS::Cognito::UserPoolGroup' resource to define additional groups (e.g., 'Admin', 'Viewer').

---

## Testing

1. **Verify Default Group Membership**:
   - Create a new user in the Cognito User Pool via the AWS Console or CLI.
   - Confirm the user is automatically added to the 'Default' group.

2. **Test Group Permissions**:
   - Test the permissions associated with the 'DefaultGroupRole'.

3. **Check Logs**:
   - View Lambda execution logs in Amazon CloudWatch to confirm successful group assignments.

---

## Clean Up

To remove the stack and all associated resources, run:
'''bash
aws cloudformation delete-stack --stack-name CognitoUserPoolStack
'''

---

## Contributing

Feel free to open issues or submit pull requests if you’d like to improve this repository.

---

## License

This project is licensed under the MIT License.
