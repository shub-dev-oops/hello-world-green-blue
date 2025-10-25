import os
from datetime import datetime, timezone
from flask import Flask, jsonify

app = Flask(__name__)

APP_NAME = os.getenv("APP_NAME", "myapp")
APP_COLOR = os.getenv("APP_COLOR", "blue")
APP_SERVICE_PORT = os.getenv("APP_SERVICE_PORT", "80")


def current_payload():
    return {
        "app": APP_NAME,
        "color": APP_COLOR,
        "servicePort": APP_SERVICE_PORT,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.route("/")
def root():
    payload = current_payload()
    payload["message"] = f"Hello from {APP_NAME} ({APP_COLOR})"
    return jsonify(payload)


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok", **current_payload()})


@app.route("/readyz")
def readyz():
    return jsonify({"status": "ready", **current_payload()})


def create_app():
    return app


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
