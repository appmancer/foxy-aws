import boto3
import psycopg2
import os
from botocore.exceptions import BotoCoreError, ClientError

# RDS Connection Details (from environment variables)
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", 5432)
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")  # IAM-authenticated database user

# Initialize AWS SDK Clients
rds_client = boto3.client("rds")
s3_client = boto3.client("s3")

def get_iam_auth_token():
    """Generate an IAM authentication token for RDS."""
    try:
        return rds_client.generate_db_auth_token(
            DBHostname=DB_HOST,
            Port=DB_PORT,
            DBUsername=DB_USER
        )
    except (BotoCoreError, ClientError) as e:
        raise Exception(f"Failed to generate IAM auth token: {e}")

def execute_sql(sql_content):
    """Execute SQL content on the RDS instance."""
    try:
        auth_token = get_iam_auth_token()
        connection = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            database=DB_NAME,
            user=DB_USER,
            password=auth_token,
            sslmode="require"  # Ensures secure connection
        )
        cursor = connection.cursor()
        cursor.execute(sql_content)
        connection.commit()
        cursor.close()
        connection.close()
        return True, None
    except Exception as e:
        return False, str(e)

def lambda_handler(event, context):
    """Lambda handler to process SQL files from S3."""
    for record in event["Records"]:
        bucket_name = record["s3"]["bucket"]["name"]
        object_key = record["s3"]["object"]["key"]
        
        # Download SQL file
        try:
            response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
            sql_content = response["Body"].read().decode("utf-8")
        except ClientError as e:
            print(f"Error reading file from S3: {e}")
            continue

        # Execute SQL
        success, error = execute_sql(sql_content)
        if success:
            print(f"Executed SQL file {object_key} successfully.")
            # Delete the file from S3
            s3_client.delete_object(Bucket=bucket_name, Key=object_key)
        else:
            print(f"Error executing SQL file {object_key}: {error}")

    return {"statusCode": 200, "body": "SQL processing complete"}

