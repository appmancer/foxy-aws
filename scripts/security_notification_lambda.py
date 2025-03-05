import json
import boto3
import os

# Initialize SES client
ses_client = boto3.client("ses", region_name="eu-north-1") 

# Email settings
SES_SENDER = "admin@getfoxy.app"
SES_RECIPIENT = "foxy@getfoxy.app"
EMAIL_SUBJECT = "Foxy Security Notification"

def lambda_handler(event, context):
    """
    AWS Lambda function to process SNS messages and forward them via SES.
    """
    try:
        # Extract SNS message
        for record in event["Records"]:
            sns_message = record["Sns"]["Message"]
            sns_subject = record["Sns"].get("Subject", "No Subject")

            # Compose email
            email_body = f"Subject: {sns_subject}\n\n{sns_message}"
            
            # Send email via SES
            response = ses_client.send_email(
                Source=SES_SENDER,
                Destination={"ToAddresses": [SES_RECIPIENT]},
                Message={
                    "Subject": {"Data": EMAIL_SUBJECT},
                    "Body": {"Text": {"Data": email_body}},
                },
            )

            print(f"Email sent! Message ID: {response['MessageId']}")

        return {"statusCode": 200, "body": json.dumps("Email forwarded successfully")}

    except Exception as e:
        print(f"Error: {str(e)}")
        return {"statusCode": 500, "body": json.dumps(f"Error: {str(e)}")}
