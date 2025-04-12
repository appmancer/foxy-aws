#!/bin/bash

# This script checks AWS estimated costs for the current month.
# Make sure Cost Explorer is enabled in your AWS account.
# Permissions required: ce:GetCostAndUsage

set -euo pipefail

echo "🔍 Fetching AWS cost breakdown for the current month..."

START_DATE=$(date -d "$(date +%Y-%m-01)" +%F)
END_DATE=$(date -d "+1 day" +%F)

aws ce get-cost-and-usage \
  --time-period Start=${START_DATE},End=${END_DATE} \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[*].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
  --output table
