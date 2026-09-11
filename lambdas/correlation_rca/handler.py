"""
Correlation + Root Cause Analysis engine.

Triggered by an EventBridge rule matching CloudWatch Alarm State Change
events (state -> ALARM). Responsibilities:
  1. Dedup / correlate: suppress repeat findings for the same alarm
     within a short window so a flapping metric doesn't spam alerts.
  2. Look up the affected resource in the CMDB_Assets table.
  3. Write a root-cause finding to RCA_Findings.
  4. Publish a human-readable summary to SNS (fans out to ChatOps +
     Incident lifecycle Lambdas).
  5. If the alarm is on the high-confidence auto-remediate list, kick
     off the SSM Automation runbook directly.
"""
import json
import os
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
ssm = boto3.client("ssm")

CMDB_TABLE = dynamodb.Table(os.environ["CMDB_TABLE_NAME"])
RCA_TABLE = dynamodb.Table(os.environ["RCA_TABLE_NAME"])
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
SSM_RUNBOOK_NAME = os.environ["SSM_RUNBOOK_NAME"]
HIGH_CONFIDENCE_ALARMS = set(os.environ.get("HIGH_CONFIDENCE_ALARMS", "").split(","))
CORRELATION_WINDOW_SECONDS = 120

# Root-cause heuristics keyed by alarm name substring. In the full labs
# this also cross-references X-Ray trace segments; kept metric-based
# here to stay inside the weekend build scope.
ROOT_CAUSE_HINTS = {
    "cpu": ("Sustained CPU saturation on the instance", 0.8),
    "error": ("Elevated application error rate, likely a downstream dependency failure", 0.65),
}


def _recent_duplicate(alarm_name: str) -> bool:
    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=CORRELATION_WINDOW_SECONDS)).isoformat()
    resp = RCA_TABLE.scan(
        FilterExpression="alarm_name = :a AND created_at > :c",
        ExpressionAttributeValues={":a": alarm_name, ":c": cutoff},
    )
    return len(resp.get("Items", [])) > 0


def _lookup_asset() -> dict:
    # Weekend-scope build tracks a single EC2 instance; scan is fine at
    # this scale. At real scale this would be a targeted get_item by
    # resource_id sourced from the alarm's dimensions.
    resp = CMDB_TABLE.scan(Limit=1)
    items = resp.get("Items", [])
    return items[0] if items else {}


def _classify(alarm_name: str):
    lowered = alarm_name.lower()
    for keyword, (cause, confidence) in ROOT_CAUSE_HINTS.items():
        if keyword in lowered:
            return cause, confidence
    return "Unclassified anomaly - manual investigation required", 0.3


def handler(event, context):
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName") or event.get("alarm_name", "unknown-alarm")
    new_state = detail.get("state", {}).get("value", "ALARM")

    if new_state != "ALARM":
        return {"status": "ignored", "reason": f"state={new_state}"}

    if _recent_duplicate(alarm_name):
        return {"status": "suppressed", "reason": "duplicate within correlation window"}

    asset = _lookup_asset()
    root_cause, confidence = _classify(alarm_name)

    finding_id = str(uuid.uuid4())
    finding = {
        "finding_id": finding_id,
        "alarm_name": alarm_name,
        "resource_id": asset.get("resource_id", "unknown"),
        "resource_name": asset.get("name", "unknown"),
        "root_cause": root_cause,
        "confidence": str(confidence),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    RCA_TABLE.put_item(Item=finding)

    message = (
        f"RCA Finding {finding_id[:8]}\n"
        f"Alarm: {alarm_name}\n"
        f"Resource: {finding['resource_name']} ({finding['resource_id']})\n"
        f"Probable root cause: {root_cause}\n"
        f"Confidence: {confidence:.0%}"
    )
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"AIOps RCA: {alarm_name}",
        Message=json.dumps(finding),
        MessageAttributes={
            "summary": {"DataType": "String", "StringValue": message}
        },
    )

    if alarm_name in HIGH_CONFIDENCE_ALARMS and asset.get("ssm_target"):
        ssm.start_automation_execution(
            DocumentName=SSM_RUNBOOK_NAME,
            Parameters={"InstanceId": [asset["ssm_target"]], "FindingId": [finding_id]},
        )
        finding["remediation_triggered"] = True

    return {"status": "processed", "finding_id": finding_id}
