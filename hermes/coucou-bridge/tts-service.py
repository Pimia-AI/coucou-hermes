#!/usr/bin/env python3
"""Coucou TTS sidecar — speaks with the same voice Hermes uses.

Hermes' gateway exposes no audio routes: its voice lives inside the Hermes
process, not in the HTTP API Coucou talks to. Rather than patch Hermes (an
update would overwrite it), this reuses the engine and the configured voice.

    POST /speak  {"text": "..."}  ->  audio/mpeg

The voice is read from ~/.hermes/config.yaml on every request, so changing it
in Hermes (`hermes config set tts.edge.voice ...`) changes Coucou's voice with
no restart.

Loopback only, no auth: it holds no secrets and returns audio of text the
caller already has. It does reach Microsoft's Edge endpoint to synthesize, so
the text leaves the machine exactly as it does for Hermes' own voice mode.

Run with Hermes' venv python, which already has edge_tts and aiohttp:
    ~/.hermes/hermes-agent/venv/bin/python3 ~/.hermes/coucou-bridge/tts-service.py
"""
import asyncio
import io
import logging
import os
import re
from pathlib import Path

import edge_tts
from aiohttp import web

HOST = "127.0.0.1"
PORT = 8643
CONFIG = Path.home() / ".hermes/config.yaml"
DEFAULT_VOICE = "es-ES-ElviraNeural"
MAX_CHARS = 4000

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("coucou-tts")


def configured_voice() -> str:
    """Read tts.edge.voice without a YAML dependency — it is a fixed two-level path."""
    try:
        text = CONFIG.read_text(encoding="utf-8")
    except Exception:
        return DEFAULT_VOICE
    match = re.search(r"^tts:\s*$.*?^\s+edge:\s*$.*?^\s+voice:\s*(\S+)",
                      text, re.MULTILINE | re.DOTALL)
    return match.group(1).strip("\"'") if match else DEFAULT_VOICE


async def speak(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"error": "expected JSON"}, status=400)

    text = (body.get("text") or "").strip()
    if not text:
        return web.json_response({"error": "empty text"}, status=400)
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS]

    voice = body.get("voice") or configured_voice()
    buf = io.BytesIO()
    try:
        communicate = edge_tts.Communicate(text, voice)
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                buf.write(chunk["data"])
    except Exception as exc:
        log.warning("synthesis failed (%s): %s", voice, exc)
        return web.json_response({"error": str(exc)}, status=502)

    data = buf.getvalue()
    if not data:
        return web.json_response({"error": "no audio produced"}, status=502)
    log.info("spoke %d chars as %s -> %d bytes", len(text), voice, len(data))
    return web.Response(body=data, content_type="audio/mpeg")


async def health(request):
    return web.json_response({"status": "ok", "voice": configured_voice()})


def main():
    app = web.Application()
    app.router.add_post("/speak", speak)
    app.router.add_get("/health", health)
    log.info("Coucou TTS on http://%s:%d  voice=%s", HOST, PORT, configured_voice())
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()
