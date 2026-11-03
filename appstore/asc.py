#!/usr/bin/env python3
"""App Store Connect chores the listing upload does not cover: free price, availability, age rating, build
attached to the version, and a status report. Reads the API key from ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH.
The version is the checked-out branch's (app_version.py); builds are only ever that version's: BUILD_NUMBER when
given, else the newest processed one. Never submits anything for review."""
import json, os, sys, time
import jwt, requests
from app_version import BUNDLE, app_version

VERSION = app_version()
BUILD = os.environ.get("BUILD_NUMBER", "").strip()
API = "https://api.appstoreconnect.apple.com"


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


S = requests.Session()
S.headers["Authorization"] = "Bearer " + token()


def call(method, path, **kw):
    tries = 3 if method == "GET" else 1  # App Store Connect has passing failures; only a read is safe to repeat
    for attempt in range(1, tries + 1):
        try:
            r = S.request(method, API + path, timeout=60, **kw)
            if r.status_code < 500 or attempt == tries:
                break
        except (requests.ConnectionError, requests.Timeout, requests.exceptions.ChunkedEncodingError):
            if attempt == tries:
                raise
        time.sleep(10)
    if r.status_code >= 400:
        detail = ""
        try:
            detail = "; ".join(e.get("detail") or e.get("title", "") for e in r.json().get("errors", []))
        except Exception:
            detail = r.text[:300]
        raise RuntimeError(f"{method} {path} -> {r.status_code}: {detail}")
    return r.json() if r.content else {}


FAILED = []


def step(name, fn):
    try:
        fn()
    except Exception as e:  # report and go on: one chore failing must not hide the others; the run fails at the end
        print(f"  ! {name}: {e}")
        FAILED.append(name)


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


def versions():
    return call("GET", f"/v1/apps/{APP}/appStoreVersions", params={"filter[platform]": "IOS", "limit": 200})["data"]


def version():
    return next((x for x in versions() if x["attributes"]["versionString"] == VERSION), None)


# A version in an OPEN state takes a new listing and build. DONE ones are live or finished.
OPEN = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
DONE = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE",
        "DEVELOPER_REMOVED_FROM_SALE"}


def states(v):
    a = v["attributes"]
    return {a.get("appStoreState"), a.get("appVersionState")} - {None}


def preflight():
    """Run before deliver, which edits whichever version is open (waiting for review included) and renames it to the
    version it's given. Go on only if every other version is done, and this one is new, being prepared or rejected."""
    for v in versions():
        name, st = v["attributes"]["versionString"], states(v)
        if name != VERSION and not st & DONE:
            raise RuntimeError(f"version {name} is still {'/'.join(sorted(st)) or 'in an unknown state'}; "
                               f"it has to be live or finished before {VERSION} is uploaded")
        if name == VERSION and not st & OPEN:
            raise RuntimeError(f"version {VERSION} is {'/'.join(sorted(st)) or 'in an unknown state'}, "
                               "so its listing can't change now")
    print(f"  preflight: the upload goes to {VERSION}")


def pick_build():
    """The build the tasks act on: BUILD_NUMBER when given, else the newest processed build, always of VERSION."""
    params = {"filter[app]": APP, "filter[preReleaseVersion.version]": VERSION, "filter[processingState]": "VALID",
              "sort": "-uploadedDate", "limit": 1}
    if BUILD:
        params["filter[version]"] = BUILD
    b = call("GET", "/v1/builds", params=params)["data"]
    return b[0] if b else None


def no_build():
    return f"no processed build {BUILD} of {VERSION}" if BUILD else f"no processed build of {VERSION} yet"


def attach_build():
    branch = os.environ.get("GITHUB_REF_NAME", "")
    if not branch.startswith("release/"):
        print(f"  build: not attached; App Store builds come from a release branch, not {branch or 'this checkout'}")
        return
    v = version()
    if v is None:
        raise RuntimeError(f"version {VERSION} is not in App Store Connect")
    cur = call("GET", f"/v1/appStoreVersions/{v['id']}/build").get("data")
    if cur and not BUILD:  # the attached build was chosen and tested; only a named build replaces it
        print(f"  build: {cur['attributes']['version']} stays on {VERSION}; name a build number to replace it")
        return
    b = pick_build()
    if not b:
        raise RuntimeError(no_build())
    if cur and cur["id"] == b["id"]:
        print(f"  build: {b['attributes']['version']} already attached to {VERSION}")
        return
    if not states(v) & OPEN:
        raise RuntimeError(f"version {VERSION} is {'/'.join(sorted(states(v)))}, so its build can't change now")
    call("PATCH", f"/v1/appStoreVersions/{v['id']}/relationships/build", json={"data": {"type": "builds", "id": b["id"]}})
    print(f"  build: attached {b['attributes']['version']} to version {VERSION}")


def report():
    print("\nBuilds (newest first):")
    builds = call("GET", "/v1/builds", params={"filter[app]": APP, "sort": "-uploadedDate", "limit": 6,
                                                "include": "buildBetaDetail,preReleaseVersion"})
    inc = {(d["type"], d["id"]): d["attributes"] for d in builds.get("included", [])}

    def related(b, rel, kind):
        return inc.get((kind, (b["relationships"].get(rel, {}).get("data") or {}).get("id")), {})

    for b in builds["data"]:
        a = b["attributes"]
        bd = related(b, "buildBetaDetail", "buildBetaDetails")
        pv = related(b, "preReleaseVersion", "preReleaseVersions")
        print(f"  {pv.get('version', '?'):<6} {a['version']:<14} uploaded {a['uploadedDate'][:16]}"
              f"  processing {a['processingState']:<10} TestFlight internal {bd.get('internalBuildState', '?')}")
    vs = versions()
    v = next((x for x in vs if x["attributes"]["versionString"] == VERSION), None)
    cur = call("GET", f"/v1/appStoreVersions/{v['id']}/build").get("data") if v else None
    b = pick_build()
    found = no_build() if not b else (f"named build {BUILD} is one of its processed builds" if BUILD
                                      else f"its newest processed build is {b['attributes']['version']}")
    print(f"\nThis branch is version {VERSION}" + (f", with build {cur['attributes']['version']} attached" if cur else "")
          + f"; {found}")
    print("\nApp Store versions:")
    for x in vs:
        a = x["attributes"]
        print(f"  {a['platform']} {a['versionString']}: {a.get('appVersionState') or a.get('appStoreState')}, release {a.get('releaseType')}")


def beta(group_name=os.environ.get("BETA_GROUP", "Public Beta")):
    """This version's build (pick_build) to an external TestFlight group, with its beta review submitted."""
    b = pick_build()
    if not b:
        raise RuntimeError(no_build())
    ver = b["attributes"]["version"]
    groups = call("GET", "/v1/betaGroups", params={"filter[app]": APP, "limit": 50})["data"]
    g = next((x for x in groups if x["attributes"]["name"] == group_name), None)
    if not g:
        raise RuntimeError(f"no group named {group_name!r} (groups: {', '.join(x['attributes']['name'] for x in groups)})")
    # what to test, shown to testers
    notes = os.environ.get("WHAT_TO_TEST", "").strip()
    if notes:
        locs = call("GET", f"/v1/builds/{b['id']}/betaBuildLocalizations")["data"]
        loc = next((l for l in locs if l["attributes"]["locale"] == "en-US"), None)
        if loc:
            call("PATCH", f"/v1/betaBuildLocalizations/{loc['id']}",
                 json={"data": {"type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}})
        else:
            call("POST", "/v1/betaBuildLocalizations", json={"data": {"type": "betaBuildLocalizations",
                 "attributes": {"locale": "en-US", "whatsNew": notes},
                 "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})
        print("  beta: 'What to Test' set")
    have = {x["id"] for x in call("GET", f"/v1/betaGroups/{g['id']}/builds", params={"limit": 50})["data"]}
    if b["id"] in have:
        print(f"  beta: {ver} already in {group_name}")
    else:
        call("POST", f"/v1/betaGroups/{g['id']}/relationships/builds", json={"data": [{"type": "builds", "id": b["id"]}]})
        print(f"  beta: added {ver} to {group_name}")
    detail = call("GET", f"/v1/builds/{b['id']}/buildBetaDetail")["data"]["attributes"]
    state = detail.get("externalBuildState")
    if state in ("READY_FOR_BETA_SUBMISSION", "MISSING_EXPORT_COMPLIANCE", None):
        call("POST", "/v1/betaAppReviewSubmissions",
             json={"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})
        print(f"  beta: {ver} submitted for beta review")
    else:
        print(f"  beta: {ver} external state {state}")


def manual_release():
    v = version()
    if v is None:  # main's next version has none until its release branch is cut
        print(f"  release: version {VERSION} is not in App Store Connect yet")
        return
    if v["attributes"].get("releaseType") == "MANUAL":
        print(f"  release: {VERSION} already manual")
        return
    call("PATCH", f"/v1/appStoreVersions/{v['id']}",
         json={"data": {"type": "appStoreVersions", "id": v["id"], "attributes": {"releaseType": "MANUAL"}}})
    print(f"  release: {VERSION} set to manual release")


TASKS = [t.strip() for t in os.environ.get("ASC_TASKS", "chores").split(",") if t.strip()]
print("Tasks:", ", ".join(TASKS))
unknown = set(TASKS) - {"preflight", "chores", "beta", "manual", "status"}
if unknown:
    sys.exit(f"Unknown task: {', '.join(sorted(unknown))}. Known: preflight, chores, beta, manual, status")
if "preflight" in TASKS:
    step("preflight", preflight)
if "chores" in TASKS:
    for name, fn in [("price", price), ("availability", availability), ("age rating", age_rating), ("build", attach_build)]:
        step(name, fn)
if "beta" in TASKS:
    step("beta", beta)
if "manual" in TASKS:
    step("manual release", manual_release)
if "preflight" not in TASKS:  # the preflight runs before the upload, and the report after it
    step("report", report)
if FAILED:
    sys.exit(f"\nFailed: {', '.join(FAILED)}")
