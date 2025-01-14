# **Ethereum Transaction Lifecycle Data Model (Optimism-Compatible)**

## **Transaction Lifecycle States**

### **Core Transaction States for ETH Transfers:**

1. **Created** – Transaction intent is created but not yet signed.
2. **Signed** – Transaction is signed by the user's wallet.
3. **Broadcasted** – Signed transaction is sent to the network.
4. **Pending** – Transaction is waiting for confirmation (in mempool).
5. **Confirmed** – Transaction is mined and has at least 1 confirmation. This is the state in Foxy where we consider the transaction to have been settled.
6. **Finalized** – Transaction has multiple confirmations and is immutable.
7. **Failed** – Transaction failed due to an error (e.g., out of gas).
8. **Cancelled** – Transaction was replaced or canceled.
9. **Error** – System-level error occurred (network issue, timeout).

---
## Narrative Transaction Flow

The following is a detailed narrative of the transaction lifecycle within the Foxy system:

1. **User Initiates a Transaction Request (Client)**  
   The user opens the Foxy mobile app and selects a recipient and the amount to send. Upon confirming the payment, the app drafts a **Transaction Request** containing the transaction details (amount, recipient address, token type) and securely sends this request to the **Rust API backend**.

2. **Backend Validates and Logs the Request (API → DynamoDB)**  
   The backend API receives the request, authenticates the user via JWT and device fingerprint, and creates a new entry in the **DynamoDB Transaction Request Table**. The transaction is marked with the status `Requested`. The backend returns the **RequestID** to the client for further processing.

3. **User Signs the Transaction (Client)**  
   The client app receives the `RequestID`, prompts the user to confirm the transaction, and **signs the transaction** locally using the private key stored securely on the device. The signed transaction is sent back to the backend.

4. **Backend Updates the Transaction State (API → DynamoDB)**  
   The backend receives the **signed transaction**, verifies its integrity, and updates the corresponding DynamoDB record to `Signed`. The signed payload is stored, and this change triggers the DynamoDB **Streams**.

5. **DynamoDB Stream Triggers Processing (DynamoDB → SQS → Lambda)**  
   DynamoDB Streams detect the state change and push the signed transaction into the **SQS Queue**. This decouples the signing from processing, allowing the system to scale.

6. **Lambda Picks Up and Broadcasts the Transaction (Lambda → Optimism)**  
   A dedicated **Lambda function** listens to the SQS queue. It retrieves the signed transaction and broadcasts it to the **Optimism network**. If successful, the transaction status in DynamoDB is updated to `Broadcasted` and then progresses to `Pending` as it awaits confirmation.

7. **Transaction Confirmation and Finalization (Optimism → Lambda → DynamoDB)**  
   The Lambda function polls the Optimism network to monitor the transaction's progress. Once the transaction is mined, the status is updated to `Confirmed`. After sufficient confirmations, it is marked as `Finalized`.

8. **Error Handling and Retries**  
   If broadcasting fails (due to network issues or invalid transactions), the Lambda updates the status to `Failed` and logs the error in `ErrorMessage`. The system automatically retries broadcasting up to the maximum defined in the `Retries` field.

9. **User Notification**  
   The user is notified in the app once the transaction reaches a terminal state (`Confirmed`, `Failed`, or `Cancelled`).

---

## DynamoDB Data Model**

### **Event Store Table (`Transactions`)**

A **Transaction Request** in Foxy represents a user's intent to send funds on the Optimism network. This request moves through multiple states, reflecting both internal processing and external blockchain events. The system ensures a non-custodial model where signing is performed on the client device, and the backend manages validation, queuing, and broadcasting.

| **Attribute**         | **Type**  | **Description**                                                                 |
|----------------------|-----------|---------------------------------------------------------------------------------|
| `PK`                 | String    | **Partition Key** → `User#<UserID>` (groups transactions by user).              |
| `SK`                 | String    | **Sort Key** → `Transaction#<TransactionID>` (unique ID for each transaction).  |
| `Status`             | String    | Lifecycle state: `Requested`, `Signed`, `Broadcasted`, `Pending`, `Confirmed`, `Failed`. |
| `RequestID`          | String    | UUID for the transaction request.                                               |
| `UnsignedTx`         | Map       | Unsigned transaction payload (prepared by the API).                             |
| `SignedTx`           | String    | Hex-encoded signed transaction (submitted by the client).                       |
| `TxHash`             | String    | Blockchain transaction hash after broadcasting.                                 |
| `Network`            | String    | Blockchain network (`Optimism`).                                                |
| `Amount`             | Number    | Transaction amount.                                                             |
| `Token`              | String    | Token symbol (e.g., `ETH`, `USDC`).                                            |
| `ToAddress`          | String    | Recipient’s wallet address.                                                     |
| `FromAddress`        | String    | Sender's wallet address.                                                        |
| `DeviceFingerprint`  | String    | Device fingerprint for request validation.                                      |
| `Signature`          | String    | Digital signature to validate integrity.                                        |
| `Retries`            | Number    | Retry attempts for broadcasting the transaction.                                |
| `ExpiresAt`          | String    | Expiry time for the transaction request (ISO8601).                              |
| `CreatedAt`          | String    | Timestamp of when the request was created.                                      |
| `UpdatedAt`          | String    | Timestamp of the last state change.                                             |
| `Metadata`           | Map       | Custom metadata (messages, context, user info).                                 |
| `PriorityLevel`      | String    | `Normal`, `High`, or `Low` priority for processing.                             |
| `RequestedByIP`      | String    | IP address of the request origin.                                               |
| `UserAgent`          | String    | User device information (OS, app version).                                      |
| `ErrorMessage`       | String    | Error details if the transaction fails.                                         |
| `RequestSource`      | String    | Source of the request (e.g., `MobileApp`, `WebApp`).                            |
| `GeoLocation`        | Map       | Geolocation data (latitude, longitude) for the request.                         |
| `SessionID`          | String    | Session identifier for request correlation.                                     |
| `AppVersion`         | String    | Version of the app used to create the request.                                  |

### **📄 Example Transaction Record (JSON)**

```json
{
  "PK": "User#123",
  "SK": "Transaction#456",
  "Status": "Requested",
  "RequestID": "uuid-789",
  "UnsignedTx": {
    "to": "0xABCDEF1234567890ABCDEF1234567890ABCDEF12",
    "value": "500000000000000000",
    "gas": "21000",
    "gasPrice": "1000000000",
    "nonce": "0",
    "chainId": "10"
  },
  "SignedTx": null,
  "TxHash": null,
  "Network": "Optimism",
  "Amount": 0.5,
  "Token": "ETH",
  "ToAddress": "0xABCDEF1234567890ABCDEF1234567890ABCDEF12",
  "FromAddress": "0x1234567890ABCDEF1234567890ABCDEF12345678",
  "DeviceFingerprint": "abc123xyz789",
  "Signature": null,
  "Retries": 0,
  "ExpiresAt": "2025-01-12T10:00:00Z",
  "CreatedAt": "2025-01-10T10:00:00Z",
  "UpdatedAt": "2025-01-10T10:00:00Z",
  "PriorityLevel": "Normal",
  "RequestedByIP": "192.168.1.100",
  "UserAgent": "FoxyApp/1.0 (Android 12)",
  "ErrorMessage": null,
  "RequestSource": "MobileApp",
  "GeoLocation": {
    "Latitude": "51.5074",
    "Longitude": "0.1278"
  },
  "SessionID": "session-xyz",
  "AppVersion": "1.0.0",
  "Metadata": {
    "Message": "Thanks for the pizza!",
    "From": {
      "Name": "George Michael",
      "UserID": 1234,
      "Wallet": "0xABCDEF1234567890ABCDEF1234567890ABCDEF23"
    },
    "To": {
      "Name": "Andrew Ridgeley",
      "UserID": 6543,
      "Wallet": "0xABCDEF1234567890ABCDEF1234567890ABCDEF12"
    }
  }
}
```

---

### **Transaction Events Table (`TransactionEvents`)**

| **Partition Key (`TransactionID`)** | **Sort Key (`EventID`)** | **EventType**       | **Details**                                    | **Timestamp**           |
|-------------------------------------|--------------------------|--------------------|------------------------------------------------|------------------------|
| `Transaction#456`                   | `Event#1`                | `Created`          | `{ "amount": 0.5, "token": "ETH" }`       | `2025-01-10T10:00Z`  |
| `Transaction#456`                   | `Event#2`                | `Signed`           | `{ "signature": "0x123..." }`              | `2025-01-10T10:01Z`  |
| `Transaction#456`                   | `Event#3`                | `Broadcasted`      | `{ "tx_hash": "0xabc123..." }`            | `2025-01-10T10:02Z`  |
| `Transaction#456`                   | `Event#4`                | `Confirmed`        | `{ "block_number": 1234567 }`              | `2025-01-10T10:03Z`  |

**Example JSON:**
```json
{
  "TransactionID": "Transaction#456",
  "EventID": "Event#3",
  "EventType": "Broadcasted",
  "Details": {
    "tx_hash": "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
  },
  "Timestamp": "2025-01-10T10:02:00Z"
}
```

---

### **Materialized View Table (`MaterializedView`)**

| **Partition Key (`UserID`)** | **TotalTransactions** | **TotalAmount** | **PendingTransactions** | **CompletedTransactions** |
|-------------------------------|----------------------|-----------------|------------------------|--------------------------|
| `User#123`                    | 25                   | 4500.00         | 2                      | 23                       |

**Example JSON:**
```json
{
  "UserID": "User#123",
  "TotalTransactions": 25,
  "TotalAmount": 4500.00,
  "PendingTransactions": 2,
  "CompletedTransactions": 23
}
```

---

## **3. Expanded Support for Multi-Network and Token Types**

```json
{
  "PK": "User#123",
  "SK": "Transaction#456",
  "Network": "Optimism",
  "ChainID": 10,
  "Amount": 0.5,
  "Token": "ETH",
  "TokenAddress": "0x0000000000000000000000000000000000000000",
  "ToAddress": "0xABCDEF1234567890ABCDEF1234567890ABCDEF12",
  "TxHash": "0xabc1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
  "Status": "Confirmed",
  "Confirmations": 12,
  "CreatedAt": "2025-01-10T10:00:00Z",
  "UpdatedAt": "2025-01-10T10:05:00Z"
}
```

---

## **4. Transaction Lifecycle Workflow**

1. **User Initiates Transfer → `Created`**
2. **Wallet Signs Transaction → `Signed`**
3. **Broadcast to Network → `Broadcasted`**
4. **Await Confirmation → `Pending` → `Confirmed`/`Failed`**
5. **Update Materialized View** with balance or status.

---

## **5. Additional States for Layer 2 (Optimism)**

- **Deposited** → Funds have been bridged from Layer 1 (Ethereum) to Layer 2 (Optimism) but are not yet available for use due to the settlement process.
- **Finalizing** → The transaction is in the fraud-proof window specific to Optimism rollups, ensuring no malicious activity has occurred before final confirmation.
- **Withdrawn** → Funds have been withdrawn from Layer 2 back to Layer 1, awaiting final settlement on the main Ethereum network.
- **Challenge Period** → The transaction is being challenged or validated within the fraud-proof period, common in optimistic rollups.
- **Bridging** → Indicates an ongoing cross-chain transfer between L1 and L2 or between different L2s.


