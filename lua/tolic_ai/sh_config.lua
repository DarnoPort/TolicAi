TolicAI = TolicAI or {}

TolicAI.Config = TolicAI.Config or {}

-- Local bridge: keep this bound to loopback during development.
TolicAI.Config.BridgeURL = "http://127.0.0.1:8765"
TolicAI.Config.EntityClass = "tolic_ai"
TolicAI.Config.MaxHealth = 100

-- Keep this above Python's TOLIC_MODEL_TIMEOUT plus response overhead.
-- The current slow-model test setup uses a 180-second Python timeout.
TolicAI.Config.RequestTimeout = 190

-- Stage 3: asynchronous decision loop and bounded movement execution.
-- Keep routine decisions responsive while avoiding a model request every frame.
TolicAI.Config.DecisionInterval = 2
TolicAI.Config.FailureRetryInterval = 10
-- A stale answer is not a bridge failure; quickly re-observe the changed world.
TolicAI.Config.StaleDecisionRetryInterval = 1
TolicAI.Config.MaxDecisionAge = 35
TolicAI.Config.MaxNPCDrift = 200
TolicAI.Config.MaxPlayerDrift = 400
TolicAI.Config.MoveTimeout = 15
TolicAI.Config.MoveGoalTolerance = 60
TolicAI.Config.MoveArrivalTolerance = 85

-- Movement distances are in Source engine units.
TolicAI.Config.StayNearMoveThreshold = 350
TolicAI.Config.StayNearStopDistance = 220
TolicAI.Config.FollowMoveThreshold = 230
TolicAI.Config.FollowStopDistance = 125
TolicAI.Config.AssistMoveThreshold = 180
TolicAI.Config.AssistStopDistance = 110
