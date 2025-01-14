# Foxy SQS Queue Architecture

## Overview

Foxy uses an event-driven architecture to handle transaction processing securely and efficiently. To manage this workflow, we implement a two-stage queue system with dedicated **Dead Letter Queues (DLQs)** for fault tolerance. This design ensures reliability, scalability, and clear separation of responsibilities.

---

## 1. Transaction Signing Queue (`TransactionSigningQueue`)

### **Purpose**
- Manages **signed transactions** received from the client after signature verification.
- Ensures transactions are **valid** before broadcasting.

### **Triggered By**
- The backend API updates the transaction status to `Signed` in **DynamoDB**.
- **DynamoDB Streams** push this event into the queue.

### **Consumed By**
- **Lambda Function**: Validates the signed transaction and forwards it to the next queue.

### **Responsibilities**
- **Validate** the transaction signature using the client’s public key.
- **Verify** that the nonce matches the latest nonce on the Optimism network.
- **Deduplicate** requests using the ULID to ensure idempotency.
- Forward valid transactions to the `TransactionBroadcastQueue`.
- Send invalid transactions to the `TransactionSigningDLQ`.

### **Dead Letter Queue: `TransactionSigningDLQ`**
- Captures transactions that fail validation after maximum retry attempts.
- Allows for manual or automated investigation and remediation.

---

## 2. Transaction Broadcasting Queue (`TransactionBroadcastQueue`)

### **Purpose**
- Handles transactions that have been validated and are ready to be **broadcast** to the Optimism network.

### **Triggered By**
- Successfully validated transactions pushed from the `TransactionSigningQueue`.

### **Consumed By**
- **Lambda Function**: Broadcasts the transaction to the Optimism network.

### **Responsibilities**
- **Broadcast** the signed transaction to the Optimism network.
- **Monitor** the transaction status (Pending → Confirmed → Finalized).
- **Update DynamoDB** with the latest status (`Broadcasted`, `Pending`, `Confirmed`).
- Retry on temporary failures (e.g., network timeouts).
- Send permanently failed transactions to the `TransactionBroadcastDLQ`.

### **Dead Letter Queue: `TransactionBroadcastDLQ`**
- Captures transactions that fail broadcasting after maximum retries.
- Allows for further analysis and potential manual resubmission.

---

## 3. Queue Summary

| **Queue Name**                  | **Purpose**                               | **Consumer**            | **Error Handling**                 |
|---------------------------------|-------------------------------------------|-------------------------|-----------------------------------|
| `TransactionSigningQueue`       | Validate signed transactions              | Validation Lambda       | Fails to `TransactionSigningDLQ`  |
| `TransactionSigningDLQ`         | Handle failed validation attempts         | Manual/Automated        | Persistent validation failures    |
| `TransactionBroadcastQueue`     | Broadcast validated transactions          | Broadcasting Lambda     | Fails to `TransactionBroadcastDLQ`|
| `TransactionBroadcastDLQ`       | Handle failed broadcasting attempts       | Manual/Automated        | Persistent broadcasting failures  |

---

## 4. Workflow Diagram

```plaintext
Client → API → DynamoDB → TransactionSigningQueue → Validation Lambda
                                      ↓
                                TransactionSigningDLQ (on failure)
                                      ↓
                   TransactionBroadcastQueue → Broadcasting Lambda
                                      ↓
                                TransactionBroadcastDLQ (on failure)
```

---

## 5. Benefits of the Queue Design

1. **Separation of Concerns**: Validation and broadcasting are decoupled, simplifying scaling and fault isolation.
2. **Scalability**: Queues can scale independently, handling spikes without impacting the entire system.
3. **Fault Tolerance**: DLQs prevent processing failures from blocking the pipeline.
4. **Observability**: Failures are clearly logged and separated for easier troubleshooting.
5. **Idempotency**: ULID-based deduplication ensures no duplicate transactions.

---

## **Conclusion**

The use of dedicated **SQS queues** and **DLQs** ensures that Foxy maintains a robust, scalable, and secure transaction processing pipeline. This design allows for seamless handling of user-initiated transactions while isolating and managing failures effectively.


