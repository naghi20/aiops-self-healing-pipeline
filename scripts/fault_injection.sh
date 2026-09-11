#!/usr/bin/env bash
# Triggers the full pipeline: CPU spike -> anomaly alarm -> correlation/RCA
# -> Slack alert -> SSM auto-remediation -> incident ticket -> auto-close.
#
# Usage: ./fault_injection.sh <instance-id>
set -euo pipefail

INSTANCE_ID="${1:?Usage: fault_injection.sh <instance-id>}"

echo "Injecting CPU load on ${INSTANCE_ID} via SSM Run Command..."
aws ssm send-command \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters commands='["sudo dnf install -y stress-ng || true", "stress-ng --cpu 2 --timeout 180s"]' \
  --query "Command.CommandId" --output text

echo "Load injected. Watch for:"
echo "  1. CloudWatch alarm aiops-demo-cpu-anomaly -> ALARM"
echo "  2. RCA_Findings table gets a new item"
echo "  3. Slack channel receives the formatted alert"
echo "  4. SSM Automation execution starts (restart-service runbook)"
echo "  5. Incidents table ticket opens, then auto-closes within ~5-10 min"
