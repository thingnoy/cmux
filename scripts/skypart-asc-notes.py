#!/usr/bin/env python3
"""TestFlight helper for Skypart's "cmux connect" (com.skypart.cmux).

    skypart-asc-notes.py --list                 # builds + processing state
    skypart-asc-notes.py <build> "<whatsNew>"   # wait for processing, set What to Test

Stdlib only — openssl signs the ES256 JWT (pattern from TokenBar/tools/asc-builds.py).
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

KEY_ID = "L6J8JSWQQ3"
APP_ID = "6802386288"  # cmux connect
KEY = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
ISSUER_FILE = os.path.expanduser("~/.appstoreconnect/issuer-id")
API = "https://api.appstoreconnect.apple.com"


def token():
    issuer = os.environ.get("ASC_ISSUER_ID") or open(ISSUER_FILE).read().strip()
    b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
    now = int(time.time())
    head = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 900,
                           "aud": "appstoreconnect-v1"}).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY],
                         input=f"{head}.{body}".encode(),
                         capture_output=True, check=True).stdout
    i = 2 if der[1] < 0x80 else 3

    def read_int(i):
        n = der[i + 1]
        return int.from_bytes(der[i + 2:i + 2 + n], "big"), i + 2 + n

    r, i = read_int(i)
    s, _ = read_int(i)
    return f"{head}.{body}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def req(method, path, payload=None):
    r = urllib.request.Request(API + path, method=method,
                               headers={"Authorization": "Bearer " + token(),
                                        "Content-Type": "application/json"},
                               data=json.dumps(payload).encode() if payload else None)
    with urllib.request.urlopen(r) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def builds():
    return req("GET", f"/v1/builds?filter[app]={APP_ID}&sort=-uploadedDate&limit=10"
                      "&fields[builds]=version,processingState,expired,uploadedDate")["data"]


def main():
    if sys.argv[1:2] == ["--list"]:
        for b in builds():
            a = b["attributes"]
            print(a["version"], a["processingState"], a["uploadedDate"],
                  "expired" if a["expired"] else "")
        return

    build_num, notes = sys.argv[1], sys.argv[2]
    build = None
    for _ in range(60):  # up to 60 min — ASC processing is slow
        build = next((b for b in builds() if b["attributes"]["version"] == build_num), None)
        state = build and build["attributes"]["processingState"]
        print("processing:", state or "not visible yet", flush=True)
        if state == "VALID":
            break
        if state in ("INVALID", "FAILED"):
            sys.exit(f"build {build_num} rejected: {state}")
        time.sleep(60)
    else:
        sys.exit("timed out waiting for processing")

    loc = req("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
    if loc:
        req("PATCH", f"/v1/betaBuildLocalizations/{loc[0]['id']}",
            {"data": {"type": "betaBuildLocalizations", "id": loc[0]["id"],
                      "attributes": {"whatsNew": notes}}})
    else:
        req("POST", "/v1/betaBuildLocalizations",
            {"data": {"type": "betaBuildLocalizations",
                      "attributes": {"whatsNew": notes, "locale": "en-US"},
                      "relationships": {"build": {"data": {"type": "builds",
                                                           "id": build["id"]}}}}})
    print(f"build {build_num} VALID, What to Test set")


if __name__ == "__main__":
    main()
