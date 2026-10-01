#!/usr/bin/env python3
"""hermes-coucou-hook.py — relays Hermes activity into the Coucou island.

Wire in : Hermes shell hook, stdin JSON
          {hook_event_name, tool_name, tool_input, session_id, cwd, profile, extra}
Wire out: Coucou Unix socket, newline-framed JSON, one connection per event.

Never blocks Hermes: short timeout, every failure swallowed, always exit 0.

Pills are keyed by child_session_id, NOT by child_subagent_id: subagent_start
carries both, but subagent_stop only carries the session id (see
tools/delegate_tool_results.py), so the subagent id cannot close what it opened.
Keying on the session id also means a child's own tool calls — which already
carry session_id == child_session_id — land on its pill with no bookkeeping.

Debug: HERMES_COUCOU_DEBUG=1 appends every raw payload to debug.jsonl.
"""
import json
import os
import socket
import sys
from pathlib import Path

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/NotchBuddy/nb.sock")
DEBUG_LOG = Path(__file__).resolve().parent / "debug.jsonl"
TIMEOUT = 0.3

EVENT_MAP = {
    "on_session_start":     "SessionStart",
    "pre_tool_call":        "PreToolUse",
    "post_tool_call":       "PostToolUse",
    "subagent_start":       "SubagentStart",
    "subagent_stop":        "SubagentStop",
    "on_session_finalize":  "SessionEnd",
    "agent_loop_stopped":   "StopFailure",
    "pre_approval_request": "Notification",
}


def debug(tag, obj):
    if os.environ.get("HERMES_COUCOU_DEBUG") != "1":
        return
    try:
        with DEBUG_LOG.open("a") as fh:
            fh.write(json.dumps({"tag": tag, "payload": obj}, default=str) + "\n")
    except Exception:
        pass


def send(payload):
    """Fire-and-forget one event. Coucou replies {"ok":true}; we don't wait."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(TIMEOUT)
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(payload) + "\n").encode())
        s.close()
    except Exception as exc:
        debug("send-failed", str(exc))


def base(src, event):
    """Coucou's common fields.

    term_program is NOT cosmetic: HookServer.processEvent hard-filters on
    term_program/bundle_id containing "vscode" and silently drops anything
    else, so without this line the whole bridge is a no-op.
    """
    return {
        "hook_event_name": event,
        "session_id": src.get("session_id") or "hermes",
        "cwd": src.get("cwd") or os.getcwd(),
        "term_program": "vscode",
        # Which Hermes bot this is. Coucou keeps one persistent pill per
        # profile, mirroring the desktop's BOTS list.
        "profile": src.get("profile") or "default",
    }


def decide_session_end(extra):
    """Hermes reports how a turn ended; Coucou animates each case differently."""
    if extra.get("failed"):
        return "StopFailure"
    if extra.get("interrupted"):
        return "SessionEnd"      # quiet teardown, no celebration, no error sound
    return "Stop"                 # the happy jump


def main():
    try:
        raw = sys.stdin.buffer.read()
        src = json.loads(raw) if raw else {}
    except Exception:
        return
    debug("in", src)

    hermes_event = src.get("hook_event_name", "")
    extra = src.get("extra") or {}

    if hermes_event == "on_session_end":
        coucou_event = decide_session_end(extra)
    else:
        coucou_event = EVENT_MAP.get(hermes_event)

    if not coucou_event:
        debug("unmapped", hermes_event)
        return

    evt = base(src, coucou_event)

    if coucou_event == "SubagentStart":
        child = extra.get("child_session_id")
        if not child:
            debug("subagent-start-no-session", extra)
            return          # no stable key: a pill we could never close
        evt["subagent_id"] = str(child)
        evt["goal"] = extra.get("child_goal") or ""
        evt["role"] = extra.get("child_role") or ""

    elif coucou_event == "SubagentStop":
        child = extra.get("child_session_id")
        if not child:
            debug("subagent-stop-no-session", extra)
            return
        evt["subagent_id"] = str(child)
        evt["summary"] = extra.get("child_summary") or ""
        evt["status"] = extra.get("child_status") or "completed"

    elif coucou_event in ("SessionStart", "SessionEnd", "Stop", "StopFailure"):
        # A subagent fires its own session lifecycle. Stamp it so Coucou can tell
        # a child's start from the main one and skip the sound + island expand.
        if src.get("session_id"):
            evt["subagent_id"] = str(src["session_id"])

    elif coucou_event in ("PreToolUse", "PostToolUse"):
        evt["tool_name"] = src.get("tool_name") or "Tool"
        ti = src.get("tool_input")
        evt["tool_input"] = ti if isinstance(ti, dict) else {}
        # Route to the child's pill when this call came from one. Coucou falls
        # back to the main pill when no pill with this id exists, so the parent
        # session's own calls need no special case.
        if src.get("session_id"):
            evt["subagent_id"] = str(src["session_id"])

    elif coucou_event == "Notification":
        # Coucou only shows the question state when the message ends in "?".
        cmd = extra.get("command") or extra.get("description") or "approval"
        evt["message"] = f"Hermes: {str(cmd)[:50]}?"

    # Stop carries no message on purpose: turn_exit_reason is an internal token
    # ("text_response(finish_reason=...)") that read as noise in the step list.
    # The finished animation already says the turn ended.

    send(evt)


main()
sys.exit(0)
