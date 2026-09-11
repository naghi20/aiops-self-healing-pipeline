"""
Posts a formatted RCA finding to a Slack incoming webhook.
Uses urllib only, no third-party deps, so it needs no Lambda layer.
"""
import json
import os
import urllib.request

SLACK_WEBHOOK_URL = os.environ["SLACK_WEBHOOK_URL"]


def handler(event, context):
    for record in event["Records"]:
        finding = json.loads(record["Sns"]["Message"])
        summary = record["Sns"].get("MessageAttributes", {}).get("summary", {}).get("Value")

        text = summary or (
            f"*AIOps RCA Alert*\n"
            f"Alarm: `{finding.get('alarm_name')}`\n"
            f"Resource: {finding.get('resource_name')}\n"
            f"Root cause: {finding.get('root_cause')}\n"
            f"Confidence: {finding.get('confidence')}"
        )

        payload = json.dumps({"text": text}).encode("utf-8")
        req = urllib.request.Request(
            SLACK_WEBHOOK_URL, data=payload, headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=5)

    return {"status": "notified"}
