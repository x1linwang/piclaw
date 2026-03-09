#!/usr/bin/env python3
"""
============================================================
Lark Webhook Server for OpenClaw
Handles incoming Lark events and interactive card callbacks

Run: python3 lark_server.py
Port: 8080 (set WEBHOOK_PORT in .env to override)
============================================================
"""

import json
import os
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from dotenv import load_dotenv

load_dotenv(os.path.expanduser("~/.openclaw/.env"))

VERIFICATION_TOKEN = os.getenv("LARK_VERIFICATION_TOKEN")
APP_ID             = os.getenv("LARK_APP_ID")
APP_SECRET         = os.getenv("LARK_APP_SECRET")
EVENTS_DIR         = os.path.join(os.getenv("OPENCLAW_WORKSPACE", "/data/openclaw/workspace"), "events")


class LarkWebhookHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._respond(400, {"error": "invalid json"})
            return

        # ── Lark challenge verification (first-time setup) ──
        if data.get("type") == "url_verification":
            challenge = data.get("challenge", "")
            print(f"[LARK] URL verification challenge received")
            self._respond(200, {"challenge": challenge})
            return

        # ── Route event to skill handler ────────────────────
        event_type = data.get("header", {}).get("event_type", "")
        event      = data.get("event", {})

        print(f"[LARK] Event received: {event_type}")

        if event_type == "im.message.receive_v1":
            self._handle_message(event)
        elif event_type == "card.action.trigger":
            self._handle_card_action(event)
        else:
            print(f"[LARK] Unhandled event type: {event_type}")

        self._respond(200, {"code": 0})

    # ── Message handler ──────────────────────────────────────
    def _handle_message(self, event):
        msg_type = event.get("message", {}).get("message_type")
        content  = event.get("message", {}).get("content", "{}")

        if msg_type == "text":
            text = json.loads(content).get("text", "").strip()
            print(f"[MSG] Received: {text}")
            self._dispatch("message", {"text": text, "event": event})

        elif msg_type == "file":
            file_key = json.loads(content).get("file_key")
            print(f"[FILE] Received file: {file_key}")
            self._dispatch("file_upload", {"file_key": file_key, "event": event})

        else:
            print(f"[MSG] Unsupported message type: {msg_type}")

    # ── Card action handler ──────────────────────────────────
    def _handle_card_action(self, event):
        action_value = event.get("action", {}).get("value", {})
        action_type  = action_value.get("action")
        print(f"[CARD] Action: {action_type}")
        self._dispatch("card_action", {
            "action":    action_type,
            "value":     action_value,
            "event":     event
        })

    # ── Dispatch to OpenClaw via event file queue ────────────
    def _dispatch(self, event_type, payload):
        """
        Write event to file queue for OpenClaw skill runner to pick up.
        TODO: Replace with direct OpenClaw skill runner call once integrated.
        """
        os.makedirs(EVENTS_DIR, exist_ok=True)
        timestamp  = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        event_file = os.path.join(EVENTS_DIR, f"{timestamp}_{event_type}.json")

        with open(event_file, "w") as f:
            json.dump({"type": event_type, "payload": payload}, f, indent=2)

        print(f"[DISPATCH] Written → {event_file}")

    # ── HTTP helpers ─────────────────────────────────────────
    def _respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, format, *args):
        pass  # Suppress default noisy HTTP access log


if __name__ == "__main__":
    PORT = int(os.getenv("WEBHOOK_PORT", 8080))
    os.makedirs(EVENTS_DIR, exist_ok=True)
    server = HTTPServer(("0.0.0.0", PORT), LarkWebhookHandler)
    print(f"[LARK] Webhook server listening on port {PORT}")
    print(f"[LARK] Events queue → {EVENTS_DIR}")
    server.serve_forever()
