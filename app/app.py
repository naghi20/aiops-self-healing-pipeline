"""
Minimal Flask app instrumented with AWS X-Ray.
Exists purely to generate realistic traces, logs, and metrics for the
AIOps pipeline to observe. Not production code.
"""
import logging
import random
import time

from aws_xray_sdk.core import xray_recorder, patch_all
from aws_xray_sdk.ext.flask.middleware import XRayMiddleware
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("aiops-demo-app")

app = Flask(__name__)

xray_recorder.configure(service="aiops-demo-app")
XRayMiddleware(app, xray_recorder)
patch_all()  # instruments requests, boto3, sqlite3, etc.


@app.route("/health")
def health():
    return jsonify(status="ok"), 200


@app.route("/api/work")
def do_work():
    """Simulated downstream call with variable latency, occasionally slow
    or erroring so CloudWatch anomaly detection has something to catch."""
    with xray_recorder.in_subsegment("downstream-call"):
        latency_ms = random.gauss(120, 30)
        if random.random() < 0.02:
            latency_ms += 1500  # inject occasional latency spike
        time.sleep(max(latency_ms, 0) / 1000)

        if random.random() < 0.01:
            logger.error("Downstream call failed: simulated 500 error")
            return jsonify(error="downstream failure"), 500

    logger.info("Request served in %.1fms", latency_ms)
    return jsonify(result="ok", latency_ms=round(latency_ms, 1)), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
