#!/bin/bash

chmod +rx ./scripts/*
ENV=$1

if [ -z "$ENV" ]; then
  echo "❌ Please provide an environment name (e.g., dev, test, prod)"
  exit 1
fi

LOG_FILE="deploy-$ENV.log"
CONFIG_FILE="config/${ENV}-parameters.json"

echo "📦 Deploying '$ENV' environment..."
echo "📝 Logging to $LOG_FILE"

rm -f "$LOG_FILE"

./scripts/deploy_all.sh "$CONFIG_FILE" 2>&1 | tee -a "$LOG_FILE"
