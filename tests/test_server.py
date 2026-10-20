import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai_service"))
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


if __name__ == "__main__":
    unittest.main()
