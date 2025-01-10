import psycopg2
import os

# Environment variables
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", 5432)
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")  # Admin user
DB_PASSWORD = os.getenv("DB_PASSWORD")  # Admin password

# SQL commands to create the `lambdauser`
CREATE_USER_SQL = """
CREATE USER lambdauser WITH LOGIN;
GRANT CONNECT ON DATABASE {db_name} TO lambdauser;
GRANT USAGE ON SCHEMA public TO lambdauser;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO lambdauser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lambdauser;
""".format(db_name=DB_NAME)

def lambda_handler(event, context):
    try:
        # Connect to the RDS instance
        connection = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            database=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            sslmode="require"
        )
        cursor = connection.cursor()
        
        # Execute SQL commands
        cursor.execute(CREATE_USER_SQL)
        connection.commit()
        cursor.close()
        connection.close()
        return {"statusCode": 200, "body": "lambdauser created successfully"}
    except Exception as e:
        return {"statusCode": 500, "body": f"Error creating lambdauser: {str(e)}"}

