#!/usr/bin/env python3
"""Fire one real ApprovalRequest at the Coucou transport and print the decision.

Run with the Hermes venv python. The island will open with Allow / Always /
Deny — click one. Nothing is executed either way; this only exercises the
transport round trip.
"""
import sys, os, time
sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
sys.path.insert(0, os.path.expanduser("~/.hermes/plugins/coucou-approval"))

from hermes_cli.approval_transport import ApprovalRequest
import importlib.util
spec = importlib.util.spec_from_file_location(
    "coucou_approval", os.path.expanduser("~/.hermes/plugins/coucou-approval/__init__.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

req = ApprovalRequest.create(
    command="rm -rf /Volumes/data512/psqlBackup",
    description="Delete the Postgres backup directory",
    pattern_key="rm_rf", pattern_keys=("rm_rf",),
    session_key="roundtrip-test", surface="transport:coucou",
    allow_session=True, allow_permanent=True, timeout_seconds=90,
)
print(f"→ presentando en la muesca: {req.command}")
print(f"  opciones permitidas: {req.allowed_choices}")
t0 = time.monotonic()
try:
    decision = mod._present(req)
    dt = time.monotonic() - t0
    ok = decision.request_id == req.request_id and decision.request_digest == req.digest
    print(f"\n✅ DECISIÓN: {decision.choice!r}  (en {dt:.1f}s)")
    print(f"   correlación id+digest correcta: {ok}")
except mod.CoucouUnavailable as e:
    print(f"\n⚠ sin decisión: {e}")
    print("   → Hermes caería al prompt del terminal (transport_fallback: builtin)")
except Exception as e:
    print(f"\n✗ error inesperado: {type(e).__name__}: {e}")
