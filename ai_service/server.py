"""Local HTTP bridge between Garry's Mod and a neural model exposed by Ollama.

Only the standard library is required. By default the HTTP server binds to loopback.
It returns validated data; it never executes code supplied by the model.
"""
from __future__ import annotations

import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

HOST = "127.0.0.1"  # Keep local by default; do not expose this service to the Internet.
PORT = int(os.environ.get("TOLIC_PORT", "8765"))
OLLAMA_URL = os.environ.get("TOLIC_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
MODEL = os.environ.get("TOLIC_OLLAMA_MODEL", "qwen2.5:3b")
MODEL_TIMEOUT = float(os.environ.get("TOLIC_MODEL_TIMEOUT", "40"))
MAX_BODY_BYTES = 64 * 1024

ALLOWED_INTENTS = {
    "observe",
    "stay_near_player",
    "follow_player",
    "assist_player",
}
ALLOWED_RISK_LEVELS = {"none", "low", "moderate", "high", "critical"}

DECISION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "intent": {"type": "string", "enum": sorted(ALLOWED_INTENTS)},
        "risk_level": {"type": "string", "enum": sorted(ALLOWED_RISK_LEVELS)},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "summary": {"type": "string"},
    },
    "required": ["intent", "risk_level", "confidence", "summary"],
    "additionalProperties": False,
}


def validate_observation(payload: Any) -> dict[str, Any]:
    """Validate the outer protocol and required sections, not game-specific semantics."""
    if not isinstance(payload, dict):
        raise ValueError("request must be a JSON object")
    if payload.get("schema_version") != 1:
        raise ValueError("schema_version must be 1")

    observation = payload.get("observation")
    if not isinstance(observation, dict):
        raise ValueError("observation must be a JSON object")

    for section in ("npc", "player", "environment"):
        if not isinstance(observation.get(section), dict):
            raise ValueError(f"observation.{section} must be a JSON object")

    return observation


def validate_decision(payload: Any) -> dict[str, Any]:
    """Reject unexpected model output before it can reach the game."""
    if not isinstance(payload, dict):
        raise ValueError("model decision must be a JSON object")

    intent = payload.get("intent")
    risk_level = payload.get("risk_level")
    confidence = payload.get("confidence")
    summary = payload.get("summary")

    if intent not in ALLOWED_INTENTS:
        raise ValueError("model returned an unsupported intent")
    if risk_level not in ALLOWED_RISK_LEVELS:
        raise ValueError("model returned an unsupported risk level")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        raise ValueError("confidence must be a number")
    if not 0 <= confidence <= 1:
        raise ValueError(f"confidence must be between 0 and 1; got {confidence!r}")
    if not isinstance(summary, str) or not summary.strip():
        raise ValueError("summary must be a non-empty string")
    if len(summary) > 280:
        raise ValueError("summary must be at most 280 characters")

    return {
        "intent": intent,
        "risk_level": risk_level,
        "confidence": float(confidence),
        "summary": summary.strip(),
    }


def _read_json_url(url: str, timeout: float) -> Any:
    request = Request(url, headers={"Accept": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def get_health() -> dict[str, Any]:
    health: dict[str, Any] = {
        "ok": True,
        "service": "tolic-ai-bridge",
        "ollama_reachable": False,
        "model": MODEL,
        "model_available": False,
    }
    try:
        tags = _read_json_url(f"{OLLAMA_URL}/api/tags", timeout=2.5)
        health["ollama_reachable"] = True
        models = tags.get("models", []) if isinstance(tags, dict) else []
        names = {item.get("name") for item in models if isinstance(item, dict)}
        health["model_available"] = MODEL in names
    except (HTTPError, URLError, TimeoutError, OSError, ValueError):
        # The bridge remains healthy even if the model host is down; report readiness separately.
        pass
    return health


def request_decision(observation: dict[str, Any]) -> dict[str, Any]:
    system_message = (
        "You are the decision module for a nonverbal game NPC. "
        "Choose exactly one permitted high-level intent from the schema. "
        "Use only facts in the structured observation. Never invent unseen threats, cover, exits, "
        "higher ground, destinations, or safe locations. "
        "In this prototype there is no verified action for moving to a safety destination; do not "
        "pretend such an action is available. "
        "When a living player is present and there is no concrete evidence of immediate danger, normally "
        "choose stay_near_player; when distance_to_player is over 500 game units, prefer follow_player. "
        "Use assist_player only when the player's own observation facts support a real need for help, such "
        "as low player.health_fraction. Do not infer injury from proximity or the player's mere presence, "
        "and never claim the player is injured without supporting facts. "
        "Important: npc.health_fraction and npc.recent_damage describe YOUR NPC body, not the player. "
        "If npc.recent_damage is true, this NPC took damage within the last 10 seconds. Treat that as "
        "evidence of possible danger to yourself: do not choose assist_player merely because the player is "
        "nearby. Since this prototype has no verified retreat action yet, choose observe after recent damage "
        "rather than approaching the player; set risk to moderate, or high if npc.health_fraction is at or "
        "below 0.5. If there is no recent damage and health is normal, use none/low risk unless other "
        "observed facts justify a higher risk. "
        "Choose observe when no living player is available or the observation is too incomplete to support "
        "a movement choice. A nearby NPC/NextBot or its class name alone is not evidence that it is hostile. "
        "Use high/critical only when concrete facts justify serious or immediate danger; do not invent danger. "
        "Do not imitate risky player actions without considering the NPC's own state. "
        "The summary must be a brief decision label, not a chain of reasoning. "
        "The confidence field is any number from 0 to 1 inclusive. "
        "Never express confidence as a percentage or use a value outside that range. "
        "Return only a JSON object matching this exact schema: "
        f"{json.dumps(DECISION_SCHEMA, separators=(',', ':'))}"
    )
    request_body = {
        "model": MODEL,
        "stream": False,
        "format": DECISION_SCHEMA,
        "options": {"temperature": 0.0},
        "messages": [
            {"role": "system", "content": system_message},
            {
                "role": "user",
                "content": json.dumps(observation, ensure_ascii=False, separators=(",", ":")),
            },
        ],
    }
    encoded = json.dumps(request_body, ensure_ascii=False).encode("utf-8")
    request = Request(
        f"{OLLAMA_URL}/api/chat",
        data=encoded,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=MODEL_TIMEOUT) as response:
        result = json.loads(response.read().decode("utf-8"))

    if not isinstance(result, dict):
        raise ValueError("Ollama returned an unexpected response")
    message = result.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        raise ValueError("Ollama response has no message content")

    try:
        raw_decision = json.loads(message["content"])
    except json.JSONDecodeError as exc:
        raise ValueError("model content is not JSON") from exc

    return {
        "schema_version": 1,
        "model": MODEL,
        "decision": validate_decision(raw_decision),
    }


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "TolicAIBridge/0.1"

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path != "/health":
            self._send_json(404, {"error": "not_found"})
            return
        self._send_json(200, get_health())

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path != "/api/decision":
            self._send_json(404, {"error": "not_found"})
            return

        try:
            raw_length = self.headers.get("Content-Length")
            if raw_length is None:
                raise ValueError("Content-Length is required")
            length = int(raw_length)
            if length < 1 or length > MAX_BODY_BYTES:
                raise ValueError(f"request body must be between 1 and {MAX_BODY_BYTES} bytes")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            observation = validate_observation(payload)
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._send_json(400, {"error": "invalid_request", "detail": str(exc)[:240]})
            return

        try:
            result = request_decision(observation)
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            logging.warning("Model request failed: %s", type(exc).__name__)
            self._send_json(502, {"error": "model_unavailable", "detail": "Could not obtain a model response"})
            return
        except (ValueError, TypeError, KeyError) as exc:
            logging.warning("Model response rejected: %s", str(exc)[:200])
            self._send_json(502, {"error": "invalid_model_response", "detail": str(exc)[:240]})
            return

        self._send_json(200, result)

    def log_message(self, format_string: str, *args: Any) -> None:
        logging.info("%s - %s", self.address_string(), format_string % args)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)
    server.daemon_threads = True
    logging.info("Tolic AI bridge listening at http://%s:%s", HOST, PORT)
    logging.info("Ollama URL: %s; configured model: %s", OLLAMA_URL, MODEL)
    logging.info("Keep this bridge local; do not expose port %s to the Internet.", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down Tolic AI bridge...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
