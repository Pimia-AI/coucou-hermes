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
import sys
from pathlib import Path

import edge_tts
from aiohttp import web

# Hermes' own deterministic Markdown-to-speech cleanup. Without it the raw reply
# is read literally: code blocks character by character, URLs slash by slash,
# "##" as a heading marker. That was doing as much damage to the narration as
# the choice of voice.
sys.path.insert(0, str(Path.home() / ".hermes/hermes-agent"))
try:
    from tools.tts_text_normalize import prepare_spoken_text
except Exception:  # never let a missing import stop speech
    prepare_spoken_text = None

HOST = "127.0.0.1"
PORT = 8643
CONFIG = Path.home() / ".hermes/config.yaml"
DEFAULT_VOICE = "es-ES-XimenaNeural"
MAX_CHARS = 4000
# Edge reads a touch fast for a notch assistant; a small slowdown is the single
# cheapest gain in how natural it sounds. Override per request, or in
# ~/.hermes/config.yaml under tts.edge.rate / tts.edge.pitch.
DEFAULT_RATE = "-5%"
DEFAULT_PITCH = "+0Hz"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("coucou-tts")


# A path is read slash by slash and its leading components carry no meaning out
# loud: "/Volumes/data512/coucou-hermes/NotchBuddy/Sources/App/HookServer.swift"
# is nine spoken fragments to say one file name. Hermes\' normalizer leaves the
# path intact (and renders "/" as "per", which is not even Spanish), so trim to
# the last component here.
_PATH_RE = re.compile(r"(?<![\w.])(~?/[\w.\-]+(?:/[\w.\-]+){2,})")


def shorten_paths(text: str) -> str:
    """Speak only the last component of a long path, keeping short ones intact."""
    def last(match: "re.Match[str]") -> str:
        return match.group(1).rstrip("/").rsplit("/", 1)[-1] or match.group(1)
    return _PATH_RE.sub(last, text)


def configured(key: str, fallback: str) -> str:
    """Read tts.edge.<key> without a YAML dependency — it is a fixed two-level path."""
    try:
        text = CONFIG.read_text(encoding="utf-8")
    except Exception:
        return fallback
    match = re.search(r"^tts:\s*$.*?^\s+edge:\s*$.*?^\s+" + key + r":\s*(\S+)",
                      text, re.MULTILINE | re.DOTALL)
    return match.group(1).strip("\"'") if match else fallback


def configured_voice() -> str:
    return configured("voice", DEFAULT_VOICE)


async def speak(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"error": "expected JSON"}, status=400)

    raw = (body.get("text") or "").strip()
    if not raw:
        return web.json_response({"error": "empty text"}, status=400)

    # Paths are trimmed BEFORE Hermes' normalizer runs: it rewrites "/" as "per"
    # and splits the extension off, leaving nothing a path regex can match.
    text = shorten_paths(raw)
    text = prepare_spoken_text(text, max_chars=MAX_CHARS) if prepare_spoken_text else text[:MAX_CHARS]
    if not text.strip():
        # Everything was code or links: nothing worth reading aloud.
        return web.json_response({"error": "nothing speakable"}, status=204)

    voice = body.get("voice") or configured_voice()
    rate = body.get("rate") or configured("rate", DEFAULT_RATE)
    pitch = body.get("pitch") or configured("pitch", DEFAULT_PITCH)
    buf = io.BytesIO()
    try:
        communicate = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch)
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                buf.write(chunk["data"])
    except Exception as exc:
        log.warning("synthesis failed (%s): %s", voice, exc)
        return web.json_response({"error": str(exc)}, status=502)

    data = buf.getvalue()
    if not data:
        return web.json_response({"error": "no audio produced"}, status=502)
    log.info("spoke %d chars (from %d raw) as %s rate=%s -> %d bytes",
             len(text), len(raw), voice, rate, len(data))
    return web.Response(body=data, content_type="audio/mpeg")


async def health(request):
    return web.json_response({"status": "ok", "voice": configured_voice(),
                              "rate": configured("rate", DEFAULT_RATE),
                              "normalizer": prepare_spoken_text is not None})


def main():
    app = web.Application()
    app.router.add_post("/speak", speak)
    app.router.add_get("/health", health)
    log.info("Coucou TTS on http://%s:%d voice=%s rate=%s normalizer=%s", HOST, PORT,
             configured_voice(), configured("rate", DEFAULT_RATE), prepare_spoken_text is not None)
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()
