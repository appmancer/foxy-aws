import json
import boto3
import os
import secrets
import datetime
import logging

# AWS setup
AWS_REGION = os.getenv("AWS_REGION", "eu-north-1")
SECRET_KEY_NAME = "foxy/secret-key"
PREVIOUS_KEYS_NAME = "foxy/previous-keys"

# AWS clients
secrets_client = boto3.client("secretsmanager", region_name=AWS_REGION)
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    try:
        # Fetch current secret key
        current_secret = secrets_client.get_secret_value(SecretId=SECRET_KEY_NAME)
        current_key = current_secret["SecretString"]

        # Fetch previous keys list
        previous_keys_secret = secrets_client.get_secret_value(SecretId=PREVIOUS_KEYS_NAME)
        previous_keys = json.loads(previous_keys_secret["SecretString"])

        # Add current key to previous keys
        previous_keys.append(current_key)

        # Generate a new secure key
        new_key = secrets.token_hex(32)  # 256-bit key
        key_rotation_time = datetime.datetime.utcnow().isoformat()

        # Update previous keys in Secrets Manager
        secrets_client.update_secret(SecretId=PREVIOUS_KEYS_NAME, SecretString=json.dumps(previous_keys))

        # Set the new secret key
        secrets_client.update_secret(SecretId=SECRET_KEY_NAME, SecretString=new_key)

        # Structured log entry
        log_entry = {
            "event": "DID Key Rotation",
            "timestamp": key_rotation_time,
            "new_key_length": len(new_key),
            "previous_keys_count": len(previous_keys),
            "message": "Secret key rotated successfully!"
        }

        logger.info(json.dumps(log_entry))  # ✅ Logs structured JSON for easy parsing

        return {
            "statusCode": 200,
            "body": json.dumps(log_entry)
        }

    except Exception as e:
        logger.error(json.dumps({"event": "DID Key Rotation Error", "error": str(e)}))
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)})
        }
