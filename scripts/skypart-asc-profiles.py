#!/usr/bin/env python3
"""App Store provisioning profiles for Skypart's "cmux connect" targets.

    skypart-asc-profiles.py --show          # bundle ids, capabilities, certs
    skypart-asc-profiles.py <out.plist>     # ensure ids + capabilities, mint a
                                            # fresh App Store profile per target,
                                            # install them, write the export
                                            # options' provisioningProfiles dict

Exists because the ASC key has no cloud-signing permission, so automatic
export signing fails with "Cloud signing permission error".
"""
import base64
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error

spec = importlib.util.spec_from_file_location(
    "asc", os.path.join(os.path.dirname(__file__), "skypart-asc-notes.py"))
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)
req = asc.req

APP = "com.skypart.cmux"
# Capabilities each target's entitlements need on its App ID.
TARGETS = {
    APP: ["PUSH_NOTIFICATIONS", "USERNOTIFICATIONS_TIMESENSITIVE",
          "APPLE_ID_AUTH", "NETWORK_EXTENSIONS"],
    APP + ".NotificationService": [],
    APP + ".CloudVPN": ["NETWORK_EXTENSIONS"],
}
CERT_NAME = "Apple Distribution: Supasai haplakhon (W3NAH8A3G5)"
PROFILE_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")


def bundle_id(identifier):
    data = req("GET", f"/v1/bundleIds?filter[identifier]={identifier}"
                      "&include=bundleIdCapabilities&limit=5")
    # filter[identifier] also matches prefixes, so take this id's own capabilities.
    match = [b for b in data["data"] if b["attributes"]["identifier"] == identifier]
    if not match:
        return None, []
    own = {c["id"] for c in match[0]["relationships"]["bundleIdCapabilities"]["data"]}
    caps = [c["attributes"]["capabilityType"] for c in data.get("included", [])
            if c["id"] in own]
    return match[0], caps


def distribution_cert():
    certs = req("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION"
                       "&limit=50")["data"]
    local = subprocess.run(["security", "find-certificate", "-c", CERT_NAME, "-a", "-Z"],
                           capture_output=True, text=True).stdout
    for c in certs:
        der = base64.b64decode(c["attributes"]["certificateContent"])
        sha1 = subprocess.run(["openssl", "dgst", "-sha1"], input=der,
                              capture_output=True).stdout.decode().split()[-1].upper()
        if sha1 in local:
            return c
    sys.exit("no ASC distribution certificate matches the local keychain identity")


def show():
    for ident in TARGETS:
        b, caps = bundle_id(ident)
        print(ident, "->", b["id"] if b else "NOT REGISTERED", sorted(caps))
    c = distribution_cert()
    print("cert", c["id"], c["attributes"]["name"], c["attributes"]["expirationDate"])


def ensure(ident, wanted):
    b, caps = bundle_id(ident)
    if not b:
        name = "cmux " + (ident.rsplit(".", 1)[-1] if ident != APP else "connect")
        b = req("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": ident, "name": name, "platform": "IOS"}}})["data"]
        caps = []
        print("registered", ident)
    for cap in wanted:
        if cap in caps:
            continue
        req("POST", "/v1/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities", "attributes": {"capabilityType": cap},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": b["id"]}}}}})
        print("enabled", cap, "on", ident)
    return b


def main():
    if sys.argv[1:2] == ["--show"]:
        return show()
    out = sys.argv[1]
    cert = distribution_cert()
    mapping = {}
    stamp = time.strftime("%Y%m%d%H%M%S")
    for ident, wanted in TARGETS.items():
        b = ensure(ident, wanted)
        name = f"cmux skypart appstore {ident.rsplit('.', 1)[-1]} {stamp}"
        try:
            p = req("POST", "/v1/profiles", {"data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": b["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})
        except urllib.error.HTTPError as e:
            sys.exit(f"profile for {ident} failed: {e.code} {e.read().decode()[:400]}")
        attrs = p["data"]["attributes"]
        os.makedirs(PROFILE_DIR, exist_ok=True)
        with open(os.path.join(PROFILE_DIR, attrs["uuid"] + ".mobileprovision"), "wb") as f:
            f.write(base64.b64decode(attrs["profileContent"]))
        mapping[ident] = name
        print("profile", name, attrs["uuid"])
    with open(out, "wb") as f:
        plistlib.dump(mapping, f)


if __name__ == "__main__":
    main()
