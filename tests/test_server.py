import json
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai_service"))
import server as bridge_server  # noqa: E402
from server import DECISION_SCHEMA, validate_decision, validate_observation  # noqa: E402


class ProtocolValidationTests(unittest.TestCase):
    def test_accepts_valid_observation(self):
        payload = {
            "schema_version": 1,
            "observation": {"npc": {}, "player": {}, "environment": {}},
        }
        self.assertEqual(validate_observation(payload), payload["observation"])

    def test_rejects_wrong_schema_version(self):
        with self.assertRaises(ValueError):
            validate_observation(
                {"schema_version": 2, "observation": {"npc": {}, "player": {}, "environment": {}}}
            )

    def test_rejects_missing_observation_section(self):
        with self.assertRaises(ValueError):
            validate_observation({"schema_version": 1, "observation": {"npc": {}, "player": {}}})

    def test_accepts_supported_decision(self):
        decision = validate_decision(
            {
                "intent": "stay_near_player",
                "risk_level": "low",
                "confidence": 0.8,
                "summary": "Remain close while the area is calm.",
            }
        )
        self.assertEqual(decision["intent"], "stay_near_player")
        self.assertEqual(decision["confidence"], 0.8)

    def test_rejects_unsupported_intent(self):
        with self.assertRaises(ValueError):
            validate_decision(
                {
                    "intent": "run_arbitrary_code",
                    "risk_level": "low",
                    "confidence": 0.8,
                    "summary": "Unsupported.",
                }
            )

    def test_move_to_safety_is_not_supported_until_executor_exists(self):
        self.assertNotIn("move_to_safety", DECISION_SCHEMA["properties"]["intent"]["enum"])
        with self.assertRaisesRegex(ValueError, "unsupported intent"):
            validate_decision(
                {
                    "intent": "move_to_safety",
                    "risk_level": "high",
                    "confidence": 0.85,
                    "summary": "Move to higher ground for safety",
                }
            )

    def test_confidence_schema_enforces_range(self):
        confidence_schema = DECISION_SCHEMA["properties"]["confidence"]
        self.assertEqual(confidence_schema["minimum"], 0)
        self.assertEqual(confidence_schema["maximum"], 1)

    def test_rejects_confidence_out_of_range(self):
        with self.assertRaisesRegex(ValueError, r"got 1\.5"):
            validate_decision(
                {
                    "intent": "observe",
                    "risk_level": "none",
                    "confidence": 1.5,
                    "summary": "Out of range.",
                }
            )

    def test_rejects_negative_confidence(self):
        with self.assertRaisesRegex(ValueError, r"got -0\.1"):
            validate_decision(
                {
                    "intent": "observe",
                    "risk_level": "none",
                    "confidence": -0.1,
                    "summary": "Below the allowed range.",
                }
            )

    def test_rejects_boolean_confidence(self):
        with self.assertRaises(ValueError):
            validate_decision(
                {
                    "intent": "observe",
                    "risk_level": "none",
                    "confidence": True,
                    "summary": "A boolean is not a numeric confidence.",
                }
            )


class BridgeHTTPTests(unittest.TestCase):
    """Exercise HTTP status and error handling without contacting a real Ollama model."""

    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), bridge_server.BridgeHandler)
        cls.httpd.daemon_threads = True
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.thread.join(timeout=2)
        cls.httpd.server_close()

    def send_request(self, method, path, body=None):
        request = Request(self.base_url + path, data=body, method=method)
        try:
            with urlopen(request, timeout=3) as response:
                status = response.status
                response_body = response.read()
        except HTTPError as error:
            status = error.code
            response_body = error.read()
        return status, json.loads(response_body.decode("utf-8"))

    def test_post_decision_returns_model_result(self):
        observation = {"npc": {}, "player": {}, "environment": {}}
        payload = {"schema_version": 1, "observation": observation}
        expected = {
            "schema_version": 1,
            "model": "qwen2.5:3b",
            "decision": {
                "intent": "assist_player",
                "risk_level": "moderate",
                "confidence": 0.75,
                "summary": "Assist player",
            },
        }
        with patch.object(bridge_server, "request_decision", return_value=expected) as mocked:
            status, body = self.send_request(
                "POST", "/api/decision", json.dumps(payload).encode("utf-8")
            )
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        mocked.assert_called_once_with(observation)

    def test_invalid_json_returns_400_without_calling_model(self):
        with patch.object(bridge_server, "request_decision") as mocked:
            status, body = self.send_request("POST", "/api/decision", b"{not-json")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "invalid_request")
        mocked.assert_not_called()

    def test_model_connection_failure_returns_502(self):
        with patch.object(
            bridge_server, "request_decision", side_effect=URLError("simulated offline model")
        ):
            status, body = self.send_request(
                "POST",
                "/api/decision",
                json.dumps({
                    "schema_version": 1,
                    "observation": {"npc": {}, "player": {}, "environment": {}},
                }).encode("utf-8"),
            )
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "model_unavailable")

    def test_model_timeout_returns_502(self):
        with patch.object(
            bridge_server, "request_decision", side_effect=TimeoutError("simulated timeout")
        ):
            status, body = self.send_request(
                "POST",
                "/api/decision",
                json.dumps({
                    "schema_version": 1,
                    "observation": {"npc": {}, "player": {}, "environment": {}},
                }).encode("utf-8"),
            )
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "model_unavailable")
        self.assertEqual(body["detail"], "Could not obtain a model response")

    def test_invalid_model_response_returns_502(self):
        with patch.object(
            bridge_server, "request_decision", side_effect=ValueError("model content is not JSON")
        ):
            status, body = self.send_request(
                "POST",
                "/api/decision",
                json.dumps({
                    "schema_version": 1,
                    "observation": {"npc": {}, "player": {}, "environment": {}},
                }).encode("utf-8"),
            )
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "invalid_model_response")
        self.assertEqual(body["detail"], "model content is not JSON")

    def test_health_remains_available_when_ollama_is_offline(self):
        with patch.object(bridge_server, "_read_json_url", side_effect=URLError("offline")):
            status, body = self.send_request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertFalse(body["ollama_reachable"])
        self.assertFalse(body["model_available"])

    def test_unknown_post_path_returns_404(self):
        status, body = self.send_request("POST", "/unknown", b"{}")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "not_found")


if __name__ == "__main__":
    unittest.main()
