"""
Lightweight ITSM incident lifecycle.

Two entry points into the same handler, distinguished by event source:
  - SNS (RCA finding published)      -> open a new incident ticket.
  - EventBridge schedule (every 5m)  -> sweep OPEN tickets and
                                         auto-close any whose alarm has
                                         returned to OK.
"""
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
cloudwatch = boto3.client("cloudwatch")

INCIDENTS_TABLE = dynamodb.Table(os.environ["INCIDENTS_TABLE_NAME"])


def _open_incident_from_finding(finding: dict):
    ticket_id = str(uuid.uuid4())
    INCIDENTS_TABLE.put_item(
        Item={
            "ticket_id": ticket_id,
            "status": "OPEN",
            "alarm_name": finding["alarm_name"],
            "finding_id": finding["finding_id"],
            "root_cause": finding.get("root_cause", ""),
            "opened_at": datetime.now(timezone.utc).isoformat(),
        }
    )
    return ticket_id


def _sweep_open_tickets():
    resp = INCIDENTS_TABLE.scan(FilterExpression="#s = :open", ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":open": "OPEN"})
    closed = []
    for ticket in resp.get("Items", []):
        alarm_state = cloudwatch.describe_alarms(AlarmNames=[ticket["alarm_name"]])
        alarms = alarm_state.get("MetricAlarms", [])
        if alarms and alarms[0]["StateValue"] == "OK":
            INCIDENTS_TABLE.update_item(
                Key={"ticket_id": ticket["ticket_id"]},
                UpdateExpression="SET #s = :closed, closed_at = :now",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":closed": "CLOSED",
                    ":now": datetime.now(timezone.utc).isoformat(),
                },
            )
            closed.append(ticket["ticket_id"])
    return closed


def handler(event, context):
    if "Records" in event:  # SNS-triggered: new finding
        results = []
        for record in event["Records"]:
            finding = json.loads(record["Sns"]["Message"])
            results.append(_open_incident_from_finding(finding))
        return {"status": "opened", "ticket_ids": results}

    # Otherwise: scheduled health-check sweep
    closed = _sweep_open_tickets()
    return {"status": "swept", "closed_ticket_ids": closed}
