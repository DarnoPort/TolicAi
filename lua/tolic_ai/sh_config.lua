TolicAI = TolicAI or {}

TolicAI.Config = TolicAI.Config or {}

-- Local bridge: keep this bound to loopback during development.
TolicAI.Config.BridgeURL = "http://127.0.0.1:8765"
TolicAI.Config.EntityClass = "tolic_ai"
TolicAI.Config.MaxHealth = 100
TolicAI.Config.RequestTimeout = 45
