TolicAI = TolicAI or {}

TolicAI.Config = TolicAI.Config or {}

-- Local bridge: keep this bound to loopback during development.
TolicAI.Config.BridgeURL = "http://127.0.0.1:8765"
TolicAI.Config.EntityClass = "tolic_ai"
TolicAI.Config.MaxHealth = 100

-- Keep this above Python's TOLIC_MODEL_TIMEOUT plus response overhead.
-- The current slow-model test setup uses a 180-second Python timeout.
TolicAI.Config.RequestTimeout = 190
