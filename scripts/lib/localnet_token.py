#!/usr/bin/env python3
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Mint the HS256 bearer token Splice's localnet participants accept.

Splice's localnet runs with the `auth-on` profiles, so each participant's
Ledger API is configured (in the vendored tree, e.g.
`conf/canton/app-provider/app-auth.conf`) as:

    canton.participants.app-provider.ledger-api.auth-services = [{
      type = unsafe-jwt-hmac-256
      target-audience = ${AUTH_APP_PROVIDER_AUDIENCE}
      secret = "unsafe"
    }]
    ... user-management-service.additional-admin-user-id = ${AUTH_APP_PROVIDER_VALIDATOR_USER_NAME}

`target-audience` selects Canton's audience-based token format, so a valid
token is an HS256 JWT whose payload is `{"aud": <audience>, "sub": <user>,
"exp": <unix>}`, signed with that secret. `additional-admin-user-id` makes the
named user a participant admin, which is what lets us upload DARs and let Daml
Script allocate parties.

Everything except the expiry is READ OUT OF THE VENDORED SPLICE TREE rather
than hardcoded here, so the answer to "which user and secret, and where do they
come from" is the files themselves:

  * user     <- env/<node>-auth-on.env, AUTH_<NODE>_VALIDATOR_USER_NAME
  * audience <- env/<node>-auth-on.env, AUTH_<NODE>_AUDIENCE default
                (overridable by the same-named environment variable)
  * secret   <- conf/canton/<node>/app-auth.conf, the auth-services `secret`

The token is printed to stdout and nowhere else. It is never logged, never
placed in argv by the callers, and never written into evidence.

There is a second credential, `--admin`. Daml Script allocates its own parties
at runtime, and Canton grants act-as rights only to the user named in an
AllocateParty request's `userId` field, which Daml Script does not set; Canton
3.5.16 has no CanActAsAnyParty right to pre-grant either. So a user token can
never act as the parties a script just allocated. Canton's own answer is the
participant admin token, pinned for the app-provider participant by
localnet-overrides/conditional-lock.compose.yaml, and read back out of that
file here. It is unsafe and public by design, like the HS256 secret above, and
is only ever valid against this local throwaway participant.

Usage:
  python3 scripts/lib/localnet_token.py [--node app-provider|app-user|sv] [--admin]
                                        [--localnet-dir <dir>] [--user <id>]
                                        [--ttl <seconds>] [--describe]
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sys
import time

ROOT = Path(__file__).resolve().parent.parent.parent

NODES = ("app-provider", "app-user", "sv")


def env_prefix(node):
    """app-provider -> APP_PROVIDER, sv -> SV."""
    return node.replace("-", "_").upper()


def default_localnet_dir():
    """The LOCALNET_DIR the driver would use, derived from .env.localnet.example."""
    for candidate in (ROOT / ".env.localnet", ROOT / ".env.localnet.example"):
        if not candidate.exists():
            continue
        text = candidate.read_text()
        match = re.search(r"^\s*LOCALNET_DIR\s*=\s*(\S+)\s*$", text, re.M)
        if match:
            value = match.group(1).strip('"').strip("'")
            return (ROOT / value).resolve() if not value.startswith("/") else Path(value)
        match = re.search(r"^\s*IMAGE_TAG\s*=\s*(\S+)\s*$", text, re.M)
        if match:
            return ROOT / "localnet-overrides" / f"splice-{match.group(1)}"
    raise SystemExit(
        "localnet_token: cannot locate the vendored Splice localnet tree; "
        "pass --localnet-dir or create .env.localnet"
    )


def read_env_default(path, key):
    """Read `KEY=${KEY:-default}` or `KEY=value` out of a Splice env file."""
    if not path.exists():
        raise SystemExit(f"localnet_token: missing {path}; is the localnet tree synced?")
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        if name.strip() != key:
            continue
        value = value.strip().strip('"').strip("'")
        shell_default = re.fullmatch(r"\$\{" + re.escape(key) + r":?-(.*)\}", value)
        if shell_default:
            return shell_default.group(1)
        return value
    return None


def read_conf_secret(path):
    """Read the auth-services `secret = "..."` out of a Canton app-auth.conf."""
    if not path.exists():
        raise SystemExit(f"localnet_token: missing {path}; is the localnet tree synced?")
    match = re.search(r'^\s*secret\s*=\s*"([^"]+)"', path.read_text(), re.M)
    if not match:
        raise SystemExit(
            f"localnet_token: no auth-services secret found in {path}; the localnet's "
            "auth configuration has changed shape and this helper needs updating"
        )
    return match.group(1)


def resolve(node, localnet_dir, user_override=None):
    prefix = env_prefix(node)
    auth_env = Path(localnet_dir) / "env" / f"{node}-auth-on.env"
    auth_conf = Path(localnet_dir) / "conf" / "canton" / node / "app-auth.conf"

    user = user_override or os.environ.get(f"AUTH_{prefix}_VALIDATOR_USER_NAME") \
        or read_env_default(auth_env, f"AUTH_{prefix}_VALIDATOR_USER_NAME")
    if not user:
        raise SystemExit(f"localnet_token: AUTH_{prefix}_VALIDATOR_USER_NAME not found in {auth_env}")

    audience = os.environ.get(f"AUTH_{prefix}_AUDIENCE") \
        or read_env_default(auth_env, f"AUTH_{prefix}_AUDIENCE")
    if not audience:
        raise SystemExit(f"localnet_token: AUTH_{prefix}_AUDIENCE not found in {auth_env}")

    secret = read_conf_secret(auth_conf)
    return {
        "node": node,
        "user": user,
        "audience": audience,
        "user_source": str(auth_env.relative_to(ROOT)) if str(auth_env).startswith(str(ROOT)) else str(auth_env),
        "secret_source": str(auth_conf.relative_to(ROOT)) if str(auth_conf).startswith(str(ROOT)) else str(auth_conf),
        "algorithm": "HS256",
    }, secret


ADMIN_LAYER = ROOT / "localnet-overrides" / "conditional-lock.compose.yaml"


def read_fixed_admin_token(node):
    """Read the pinned participant admin token out of our compose layer."""
    if not ADMIN_LAYER.exists():
        raise SystemExit(f"localnet_token: missing {ADMIN_LAYER}; the localnet compose layer is gone")
    text = ADMIN_LAYER.read_text()
    block = re.search(
        r"canton\.participants\." + re.escape(node)
        + r"\.ledger-api\.admin-token-config\s*\{(.*?)\}", text, re.S)
    if not block:
        raise SystemExit(
            f"localnet_token: {ADMIN_LAYER.name} pins no admin token for participant {node!r}; "
            "--admin is wired for the app-provider participant only"
        )
    token = re.search(r'fixed-admin-token\s*=\s*"([^"]+)"', block.group(1))
    if not token:
        raise SystemExit(f"localnet_token: no fixed-admin-token in {ADMIN_LAYER.name} for {node!r}")
    return token.group(1)


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def mint(user, audience, secret, ttl):
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"sub": user, "aud": audience, "exp": int(time.time()) + int(ttl)}
    signing_input = b".".join(
        b64url(json.dumps(part, separators=(",", ":"), sort_keys=True).encode())
        for part in (header, payload)
    )
    signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return (signing_input + b"." + b64url(signature)).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--node", default="app-provider", choices=NODES)
    parser.add_argument("--localnet-dir")
    parser.add_argument("--user")
    parser.add_argument("--ttl", type=int, default=3600)
    parser.add_argument("--admin", action="store_true",
                        help="print the participant admin token (act-as-any-party) instead of "
                             "minting a user token; needed by anything that runs Daml Script")
    parser.add_argument("--describe", action="store_true",
                        help="print the user/audience/sources as JSON and mint nothing")
    args = parser.parse_args()

    localnet_dir = Path(args.localnet_dir) if args.localnet_dir else default_localnet_dir()

    if args.admin:
        token = read_fixed_admin_token(args.node)
        if args.describe:
            json.dump({
                "node": args.node,
                "kind": "participant admin token (fixed)",
                "claims": "admin + act-as-any-party, from admin-token-config",
                "token_source": str(ADMIN_LAYER.relative_to(ROOT)),
            }, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        sys.stdout.write(token + "\n")
        return 0

    described, secret = resolve(args.node, localnet_dir, args.user)

    if args.describe:
        # Deliberately does not include the secret's value, only where it came from.
        json.dump(described, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    sys.stdout.write(mint(described["user"], described["audience"], secret, args.ttl))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
