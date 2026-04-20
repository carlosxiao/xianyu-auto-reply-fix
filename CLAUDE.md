# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

闲鱼管理系统 (Xianyu/Goofish Management System) — a Chinese second-hand marketplace automation platform providing auto-reply, auto-delivery, multi-account management, item polishing, and order handling. Forked from `zhinianboke-new/xianyu-auto-reply`.

- **Language**: Python 3.11+ backend, vanilla JS + Bootstrap 5 frontend
- **Version**: tracked in `static/version.txt` (currently v1.9.3)

## Running the Project

```bash
# Install dependencies
pip install -r requirements.txt
playwright install chromium

# Run locally (defaults to http://localhost:8090)
python Start.py

# Docker (defaults to http://localhost:9000)
docker compose up -d --build

# Default login: admin / admin123
```

Key environment variables: `API_HOST`, `API_PORT`, `DB_PATH`, `SQL_LOG_ENABLED`, `SECRET_ENCRYPTION_KEY`, `JWT_SECRET_KEY`, `USE_XVFB`, `ENABLE_HEADFUL`, `ENABLE_VNC`, `TZ`.

## Release Process

1. Update `static/version.txt` with new version tag (e.g., `v1.9.4`)
2. Push to `main` — GitHub Actions (`.github/workflows/auto-release.yml`) reads the version, generates `update_files.json`, and creates a GitHub Release
3. Running instances download and apply patches via `auto_updater.py`

## Architecture

```
Start.py (bootstrap)
  ├── CookieManager  (cookie_manager.py) — in-memory coordinator for all accounts
  ├── reply_server.py (FastAPI) — REST API + static frontend, runs in background thread
  │     └── SSE endpoints consume from OrderEventHub
  ├── XianyuLive × N (XianyuAutoAsync.py) — one asyncio.Task per enabled account
  │     ├── WebSocket to wss://wss-goofish.dingtalk.com/
  │     ├── Protobuf message parsing via blackboxprotobuf
  │     ├── Reply chain: specific-item → item-keywords → general-keywords → default → AI
  │     └── Integrates AIReplyEngine, FileLogCollector, auto-delivery, token refresh
  └── db_manager.py — SQLite layer with Fernet encryption for sensitive fields
        └── Key stored in data/.secret_encryption.key
```

### Core Modules

| Module | Role |
|--------|------|
| `XianyuAutoAsync.py` (~15K lines) | WebSocket engine: message parsing, auto-reply, auto-delivery, heartbeat, CAPTCHA recovery |
| `reply_server.py` (~11K lines) | FastAPI app: REST API, SSE streaming, static file serving, auth |
| `db_manager.py` (~9K lines) | SQLite data layer with multi-user isolation (`user_id` FK on all tables) |
| `cookie_manager.py` | Holds all account cookies, tasks, keywords, live instances in memory |
| `order_event_hub.py` | In-process pub/sub (threading + queue.Queue) for order state changes |
| `order_status_handler.py` | State machine enforcing valid order state transitions |
| `ai_reply_engine.py` | AI reply via OpenAI/Gemini/Anthropic/Azure/Ollama/DashScope |
| `config.py` | Singleton YAML config loader with dot-notation key access |

### Key Patterns

- **Singleton config**: `Config()` in `config.py` loads `global_config.yml` once
- **CookieManager**: central in-memory state for all accounts; loaded from SQLite on startup, reloadable via `reload_from_db()`
- **Multi-user isolation**: all DB tables keyed by `user_id`; JWT Bearer Token auth
- **Order event bus**: `OrderEventHub` publishes to per-user `queue.Queue` instances consumed by SSE endpoints
- **Hot updates**: `auto_updater.py` downloads changed files from GitHub Releases
- **Browser automation**: Playwright (slider CAPTCHA, QR login, order scraping) + DrissionPage (CAPTCHA refresh); Xvfb in Docker with optional VNC
- **Obfuscated modules**: `secure_item_polish_ultra.py` uses hex reversal + base64 + zlib + exec()

## Testing

No automated test suite exists. There are no test files or test configuration.

## Code Conventions

- Comments and UI text are in Chinese (zh-CN)
- Logging uses `loguru` throughout
- Large monolithic files are the norm — `XianyuAutoAsync.py`, `reply_server.py`, and `db_manager.py` are each 9K–15K lines
- Module-level singletons: `db_manager = DatabaseManager()`, `order_event_hub = OrderEventHub()`
- Frontend is a single-page app in `static/index.html` with `static/js/app.js`
