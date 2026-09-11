#!/usr/bin/env bash
# Tears down all billable resources. Safe to re-run.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

echo "Running terraform destroy..."
terraform destroy -auto-approve

echo "Double-checking for orphaned S3 objects (Terraform won't delete a non-empty bucket)..."
BUCKET=$(terraform output -raw telemetry_bucket 2>/dev/null || true)
if [ -n "${BUCKET:-}" ]; then
  aws s3 rm "s3://${BUCKET}" --recursive || true
  aws s3api delete-bucket --bucket "${BUCKET}" || true
fi

echo "Cleanup complete. Verify in the AWS Console that no EC2, Lambda, or DynamoDB resources remain."
