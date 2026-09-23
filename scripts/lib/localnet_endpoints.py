#!/usr/bin/env python3
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""The one derivation of every localnet endpoint from the app-provider JSON
Ledger API URL.

Splice's localnet assigns every service a port of the form <node><suffix>:
the leading digit selects the node (3 = app-provider, 2 = app-user, 4 = sv)
and the three-digit suffix selects the service (901 = gRPC ledger API,
902 = admin API, 975 = JSON Ledger API, 903 = validator admin API). This file
is the only place that rule is written down; every other script or module in
this repository that needs a localnet endpoint spawns this one rather than
re-deriving it, so the rule cannot drift into a second, differently-wrong copy.

Scan is the one exception: it is served by nginx on the SV UI port, not by
the <node><suffix> rule, so it is not derived from the ledger port at all.
The documented default SV UI port is 4000; set SV_UI_PORT to override it.

Usage:
  python3 scripts/lib/localnet_endpoints.py --ledger-json-api http://localhost:3975
  python3 scripts/lib/localnet_endpoints.py --ledger-json-api http://localhost:3975 --get scan
"""
import argparse
import json
import os
import re
import sys
from urllib.parse import urlparse, urlunparse

PORT_RE = re.compile(r"^([234])(\d{3})$")
SUFFIX = "975"

NODE_DIGITS = {"provider": "3", "user": "2", "sv": "4"}


def _host(parsed) -> str:
    """The bare host, bracketed if it is IPv6, and never the userinfo:
    callers rebuild netloc from this rather than splitting parsed.netloc,
    which is not IPv6-safe (it has more than one ':') and would otherwise
    carry a leaked username:password through to the rebuilt URL.
    """
    host = parsed.hostname or "localhost"
    return f"[{host}]" if ":" in host else host


def _replace_port(parsed, new_port: str):
    return urlunparse(parsed._replace(netloc=f"{_host(parsed)}:{new_port}"))


def derive(ledger_json_api: str) -> dict:
    parsed = urlparse(ledger_json_api)

    if parsed.username is not None or parsed.password is not None:
        redacted = f"{parsed.scheme}://***@{parsed.hostname}:{parsed.port}"
        raise SystemExit(
            f"localnet_endpoints: {redacted} carries credentials, which this script "
            "must reject: derive() copies the ledger JSON API endpoint verbatim into "
            "five derived endpoints, which then reach process arguments (visible via "
            "`ps -ww -ax`), thrown error messages, and readiness log lines. The "
            "localnet's own credentials come from scripts/lib/localnet_token.py "
            "reading them out of the environment, not from this URL; pass a bare "
            "--ledger-json-api with no userinfo."
        )

    # A query or fragment rides through urlunparse untouched and would be
    # appended after the paths we build, for the same reason a path would.
    if parsed.query or parsed.fragment:
        raise SystemExit(
            f"localnet_endpoints: {ledger_json_api!r} carries a query or fragment, which the "
            "Splice localnet's JSON Ledger API base URL never does; it would be carried into "
            "every derived endpoint, so it is rejected rather than silently producing a "
            "nonsense URL."
        )

    if parsed.path not in ("", "/"):
        raise SystemExit(
            f"localnet_endpoints: {ledger_json_api!r} has a path ({parsed.path!r}), which "
            "the Splice localnet's JSON Ledger API base URL never carries; a path here "
            "would be copied into every derived endpoint (e.g. .../api/validator would "
            "become .../foo/api/validator), so it is rejected rather than silently "
            "producing a nonsense URL."
        )

    port = parsed.port
    port_str = str(port) if port is not None else None
    match = PORT_RE.match(port_str) if port_str else None
    if not match or match.group(2) != SUFFIX:
        raise SystemExit(
            f"localnet_endpoints: {ledger_json_api!r} has port {port_str!r}, which does not "
            f"match the Splice localnet's <node><suffix> port pattern (leading digit 2/3/4, "
            f"suffix {SUFFIX}). Every other localnet endpoint is derived from that pattern, so "
            "a non-conforming ledger JSON API endpoint cannot be resolved; set the endpoints "
            "explicitly (PROVIDER_VALIDATOR, USER_VALIDATOR, APP_USER_JSON_API, SCAN_API) "
            "instead of relying on derivation."
        )

    provider_json_api = ledger_json_api.rstrip("/")
    user_json_api = _replace_port(parsed, f"{NODE_DIGITS['user']}{SUFFIX}").rstrip("/")
    sv_json_api = _replace_port(parsed, f"{NODE_DIGITS['sv']}{SUFFIX}").rstrip("/")
    provider_validator = _replace_port(parsed, f"{NODE_DIGITS['provider']}903").rstrip("/") + "/api/validator"
    user_validator = _replace_port(parsed, f"{NODE_DIGITS['user']}903").rstrip("/") + "/api/validator"

    # gRPC Ledger API is host:port, not a URL: `dpm script --ledger-host/--ledger-port`
    # and Canton's own console take it in that form. _host() brackets IPv6
    # hosts so the result is a valid host:port rather than an ambiguous
    # triple-colon string.
    host = _host(parsed)
    provider_ledger = f"{host}:{NODE_DIGITS['provider']}901"
    user_ledger = f"{host}:{NODE_DIGITS['user']}901"
    sv_ledger = f"{host}:{NODE_DIGITS['sv']}901"

    # The web UIs are served by nginx on per-node UI ports, which are Splice's
    # own env variables rather than the <node><suffix> rule. Defaults are the
    # ones env/common.env documents.
    sv_ui_port = os.environ.get("SV_UI_PORT", "4000")
    provider_ui_port = os.environ.get("APP_PROVIDER_UI_PORT", "3000")
    user_ui_port = os.environ.get("APP_USER_UI_PORT", "2000")
    scan = f"http://scan.localhost:{sv_ui_port}"

    return {
        "provider_json_api": provider_json_api,
        "user_json_api": user_json_api,
        "sv_json_api": sv_json_api,
        "provider_validator": provider_validator,
        "user_validator": user_validator,
        "provider_ledger": provider_ledger,
        "user_ledger": user_ledger,
        "sv_ledger": sv_ledger,
        "provider_wallet_ui": f"http://wallet.localhost:{provider_ui_port}",
        "user_wallet_ui": f"http://wallet.localhost:{user_ui_port}",
        "scan": scan,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ledger-json-api", required=True, help="the app-provider JSON Ledger API URL")
    parser.add_argument("--get", help="print only this key's value, not the full JSON object")
    args = parser.parse_args()

    endpoints = derive(args.ledger_json_api)

    if args.get:
        if args.get not in endpoints:
            raise SystemExit(f"localnet_endpoints: no such key {args.get!r}; keys are {list(endpoints)}")
        sys.stdout.write(endpoints[args.get] + "\n")
        return 0

    json.dump(endpoints, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
