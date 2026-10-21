# Протокол AI-моста — версия 1

AI-мост предназначен для запросов от серверной стороны Garry's Mod. Он принимает только JSON и возвращает структурированное намерение; он не принимает от модели исполняемый код.

## Запуск

```sh
python ai_service/server.py
```

Переменные окружения:
- `TOLIC_PORT` — порт HTTP-моста, по умолчанию `8765`.
- `TOLIC_OLLAMA_URL` — адрес Ollama, по умолчанию `http://127.0.0.1:11434`.
- `TOLIC_OLLAMA_MODEL` — имя модели, по умолчанию `qwen2.5:3b`.
- `TOLIC_MODEL_TIMEOUT` — тайм-аут запроса модели в секундах, по умолчанию `40`.

Внешний тайм-аут запроса Garry's Mod в `lua/tolic_ai/sh_config.lua` должен быть немного больше `TOLIC_MODEL_TIMEOUT`, иначе игра может прекратить ожидание раньше Python-моста. Текущая Lua-настройка — `190` секунд для локального запуска с `TOLIC_MODEL_TIMEOUT=180`.

Сервис намеренно привязан к `127.0.0.1`. Не изменяйте адрес привязки так, чтобы сервис был доступен из внешней сети.

## GET /health

Пример ответа:

```json
{
  "ok": true,
  "service": "tolic-ai-bridge",
  "ollama_reachable": true,
  "model": "qwen2.5:3b",
  "model_available": true
}
```

`ok` означает, что HTTP-мост отвечает. Если `ollama_reachable` или `model_available` равны `false`, нейросетевое решение не готово.

## POST /api/decision

Запрос:

```json
{
  "schema_version": 1,
  "observation": {
    "npc": {
      "health_fraction": 1.0,
      "recent_damage": false,
      "distance_to_player": 200
    },
    "player": {
      "present": true,
      "under_threat": false,
      "invulnerability_observed": false
    },
    "environment": {
      "visible_threat_count": 0,
      "recent_danger": false,
      "navmesh_available": true
    }
  }
}
```

Объекты `npc`, `player` и `environment` обязательны. В последующих версиях схема расширяется только с изменением `schema_version` и тестов.

Ответ:

```json
{
  "schema_version": 1,
  "model": "qwen2.5:3b",
  "decision": {
    "intent": "stay_near_player",
    "risk_level": "low",
    "confidence": 0.84,
    "summary": "The area appears calm; remain near the player."
  }
}
```

Возможные намерения прототипа:
- `observe`
- `stay_near_player`
- `follow_player`
- `assist_player`

`move_to_safety` намеренно не входит в список допустимых намерений текущей реализации: модель не должна выбирать действие, для которого ещё нет проверенного исполнителя и источника данных о безопасной точке.

Допустимые уровни риска: `none`, `low`, `moderate`, `high`, `critical`.

Значения выше иллюстративны; реальный ответ зависит от модели и запроса. `confidence` может быть любым числом от `0` до `1` включительно, в том числе дробным (например, `0.84`); логическое значение `true`/`false` не считается числовой уверенностью. Сервис отклоняет неизвестные намерения, уверенность вне допустимого диапазона и слишком длинное резюме.

## Ошибки

- `400 invalid_request` — невалидный JSON или неверная структура наблюдения.
- `404 not_found` — неизвестный путь.
- `502 model_unavailable` — Ollama не отвечает либо модель недоступна.
- `502 invalid_model_response` — ответ модели нельзя разобрать или он не соответствует схеме.

Вызов модели может занять несколько секунд или завершиться по тайм-ауту. Не отправляйте HTTP-запрос из блокирующего игрового цикла.
