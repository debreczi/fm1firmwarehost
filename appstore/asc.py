#!/usr/bin/env python3
"""App Store Connect chores the listing upload does not cover: free price, availability, age rating, build
attached to the version, and a status report. Reads the API key from ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH.
Never submits anything for review."""
import json, os, sys, time
import jwt, requests

BUNDLE = "com.debreczi.fm1hub"
VERSION = os.environ.get("APP_VERSION", "1.0")
API = "https://api.appstoreconnect.apple.com"


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


S = requests.Session()
S.headers["Authorization"] = "Bearer " + token()


def call(method, path, **kw):
    r = S.request(method, API + path, timeout=60, **kw)
    if r.status_code >= 400:
        detail = ""
        try:
            detail = "; ".join(e.get("detail") or e.get("title", "") for e in r.json().get("errors", []))
        except Exception:
            detail = r.text[:300]
        raise RuntimeError(f"{method} {path} -> {r.status_code}: {detail}")
    return r.json() if r.content else {}


def step(name, fn):
    try:
        fn()
    except Exception as e:  # report and go on: one chore failing must not hide the others
        print(f"  ! {name}: {e}")


app = call("GET", "/v1/apps", params={"filter[bundleId]": BUNDLE})["data"][0]
APP = app["id"]
print(f"App {app['attributes']['name']} ({BUNDLE}), id {APP}")


def price():
    try:
        sched = call("GET", f"/v1/apps/{APP}/appPriceSchedule")["data"]
        prices = call("GET", f"/v1/appPriceSchedules/{sched['id']}/manualPrices", params={"limit": 5}).get("data")
        if prices:
            print("  price: already set")
            return
    except RuntimeError as e:
        if "404" not in str(e):
            raise
    pts = call("GET", f"/v1/apps/{APP}/appPricePoints", params={"filter[territory]": "USA", "limit": 200})["data"]
    free = next(p for p in pts if float(p["attributes"]["customerPrice"]) == 0)
    call("POST", "/v1/appPriceSchedules", json={
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": APP}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${p0}"}]}}},
        "included": [{"type": "appPrices", "id": "${p0}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    print("  price: set to free")


def availability():
    try:
        call("GET", f"/v1/apps/{APP}/appAvailabilityV2")
        print("  availability: already set")
        return
    except RuntimeError as e:
        if "404" not in str(e):
            raise
    terr = call("GET", "/v1/territories", params={"limit": 200})["data"]
    ids = [t["id"] for t in terr]
    call("POST", "/v2/appAvailabilities", json={
        "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True}, "relationships": {
            "app": {"data": {"type": "apps", "id": APP}},
            "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in ids]}}},
        "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                      "relationships": {"territory": {"data": {"type": "territories", "id": t}}}} for t in ids]})
    print(f"  availability: all {len(ids)} territories")


BOOL_KEYS = {"gambling", "unrestrictedWebAccess", "lootBox", "messagingAndChat", "parentalControls", "ageAssurance",
             "userGeneratedContent", "healthOrWellnessTopics", "advertising", "seventeenPlus", "kidsAgeBand"}


def age_rating():
    infos = call("GET", f"/v1/apps/{APP}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("state") not in ("READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO")), infos[0])
    decl = call("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    attrs = {}
    for k, v in decl["attributes"].items():
        # only the questions: overrides, regional classifications and links stay as Apple has them
        if v is not None or k == "kidsAgeBand" or any(w in k for w in ("Override", "Classification", "Url", "Number")):
            continue
        attrs[k] = False if k in BOOL_KEYS or k.startswith("is") else "NONE"
    if not attrs:
        print("  age rating: already filled")
        return
    call("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}",
         json={"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": attrs}})
    print(f"  age rating: {len(attrs)} answers set (none / no for every question)")


def version():
    vs = call("GET", f"/v1/apps/{APP}/appStoreVersions", params={"filter[platform]": "IOS", "limit": 10})["data"]
    v = next((x for x in vs if x["attributes"]["versionString"] == VERSION), None)
    if v is None:
        print(f"  version {VERSION}: not found")
        return None
    return v


def attach_build():
    v = version()
    if v is None:
        return
    cur = call("GET", f"/v1/appStoreVersions/{v['id']}/build").get("data")
    builds = call("GET", "/v1/builds", params={"filter[app]": APP, "filter[processingState]": "VALID",
                                                "sort": "-uploadedDate", "limit": 1})["data"]
    if not builds:
        print("  build: no processed build yet")
        return
    b = builds[0]
    if cur and cur["id"] == b["id"]:
        print(f"  build: {b['attributes']['version']} already attached to {VERSION}")
        return
    call("PATCH", f"/v1/appStoreVersions/{v['id']}/relationships/build", json={"data": {"type": "builds", "id": b["id"]}})
    print(f"  build: attached {b['attributes']['version']} to version {VERSION}")


def report():
    print("\nBuilds (newest first):")
    builds = call("GET", "/v1/builds", params={"filter[app]": APP, "sort": "-uploadedDate", "limit": 6,
                                                "include": "buildBetaDetail"})
    det = {d["id"]: d["attributes"] for d in builds.get("included", []) if d["type"] == "buildBetaDetails"}
    for b in builds["data"]:
        a = b["attributes"]
        bd = det.get((b["relationships"].get("buildBetaDetail", {}).get("data") or {}).get("id"), {})
        print(f"  {a['version']:<14} uploaded {a['uploadedDate'][:16]}  processing {a['processingState']:<10}"
              f" TestFlight internal {bd.get('internalBuildState', '?')}")
    print("\nApp Store versions:")
    for x in call("GET", f"/v1/apps/{APP}/appStoreVersions", params={"limit": 10})["data"]:
        a = x["attributes"]
        print(f"  {a['platform']} {a['versionString']}: {a.get('appVersionState') or a.get('appStoreState')}")


print("Chores:")
for name, fn in [("price", price), ("availability", availability), ("age rating", age_rating), ("build", attach_build)]:
    step(name, fn)
step("report", report)
