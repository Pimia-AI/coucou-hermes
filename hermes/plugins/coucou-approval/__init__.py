"""Coucou approval transport — answer Hermes approval prompts from the notch.

Hermes asks a selected transport to present a dangerous-command approval and
return a correlated decision; policy, scope and persistence stay host-owned
(hermes_cli/approval_transport.py). This transport presents the request on
Coucou's island and waits for the Allow / Always / Deny click.

Selected by, in ~/.hermes/config.yaml:

    security:
      approval:
        transport: coucou
        transport_fallback: builtin

``transport_fallback: builtin`` is not optional in practice. Any transport
failure is normalised to a DENIAL by the host; only the explicit builtin
fallback turns a failure back into the ordinary terminal prompt. Without it,
quitting Coucou would hard-deny every dangerous command with a message telling
the model the user refused consent.

Unlike the shell-hook bridge this runs in-process, so there is no per-event
subprocess, and the host gives it proper human-wait accounting: time spent
waiting for the click is excluded from the concurrent tool batch deadline.
"""

import json
import logging
import os
import socket

logger = logging.getLogger("coucou-approval")

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/NotchBuddy/nb.sock")

# Coucou gives up on its own pending approval after 115s and answers "ask".
# Stay just inside that so we observe its timeout rather than being cut off.
MAX_WAIT = 118.0

# Coucou's decision -> Hermes ApprovalChoice, best first. "ask" is deliberately
# absent: it is not a decision, and is handled as a failure (see _present).
CHOICE_MAP = {
    "allow":  ("once",),
    "always": ("always", "session", "once"),
    "deny":   ("deny",),
}


class CoucouUnavailable(RuntimeError):
    """Raised so the host falls back to the builtin prompt instead of denying."""


def _ask_coucou(payload, timeout):
    """Send one PermissionRequest and block for Coucou's reply."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(payload) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
    finally:
        s.close()
    raw = b"".join(chunks).decode().strip()
    if not raw:
        raise CoucouUnavailable("empty reply")
    return json.loads(raw).get("permissionDecision", "")


def _present(request):
    """Present one approval on the island and return the correlated decision."""
    payload = {
        "hook_event_name": "PermissionRequest",
        "session_id": request.request_id[:8],
        "cwd": os.getcwd(),
        # Not cosmetic: HookServer filters on term_program/bundle_id containing
        # "vscode" and answers "ask" to everything else.
        "term_program": "vscode",
        "tool_name": request.pattern_key or "Hermes",
        "tool_input": {"command": request.command or request.description},
    }

    wait = min(float(request.timeout_seconds or MAX_WAIT), MAX_WAIT)
    # Tell Coucou how long this request is actually good for. Without it the
    # island keeps the dialog up for its own 115s default, so a click after the
    # host already gave up looks accepted but decides nothing.
    payload["timeout_seconds"] = wait
    try:
        decision = _ask_coucou(payload, wait)
    except CoucouUnavailable:
        raise
    except Exception as exc:
        # Not running, socket stale, malformed reply: let the terminal ask.
        raise CoucouUnavailable(f"coucou unreachable: {exc}") from exc

    # "ask" means Coucou timed out, or a newer approval displaced this one —
    # it only shows one at a time. Either way nobody decided, so fall back.
    if decision == "ask" or decision not in CHOICE_MAP:
        raise CoucouUnavailable(f"no decision ({decision or 'none'})")

    allowed = set(request.allowed_choices)
    for candidate in CHOICE_MAP[decision]:
        if candidate in allowed:
            return request.respond(candidate)

    # Coucou offered a scope this request does not permit (e.g. "always" on a
    # request that forbids permanent grants) and nothing weaker was allowed.
    raise CoucouUnavailable(f"choice {decision!r} not in {sorted(allowed)}")


def register(ctx):
    ctx.register_approval_transport("coucou", _present)
