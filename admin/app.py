"""RTMP admin: dashboard, stream-key management, and publish authorization for nginx-rtmp.

Runs in the rtmp container's network namespace, so nginx reaches it at 127.0.0.1:8000
and it reaches nginx's stat/control endpoints at 127.0.0.1:8080. Standard library only.
"""
import collections
import json
import os
import re
import secrets
import string
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("DATA_DIR", "/data")
KEYS_FILE = os.path.join(DATA, "keys.json")
SETTINGS_FILE = os.path.join(DATA, "settings.json")
EVENTS_FILE = os.path.join(DATA, "events.jsonl")
NGINX = "http://127.0.0.1:8080"
APP = "live"
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
KEY_RE = re.compile(r"^[A-Za-z0-9_-]{3,64}$")

lock = threading.Lock()
events = collections.deque(maxlen=300)


# ---------- storage ----------
def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)


os.makedirs(DATA, exist_ok=True)
keys = load(KEYS_FILE, [])
settings = load(SETTINGS_FILE, {"server_url": "rtmp://YOUR-PUBLIC-ADDRESS:1935/live"})
try:
    with open(EVENTS_FILE) as f:
        for line in f.readlines()[-300:]:
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
except OSError:
    pass


def find_key(k):
    return next((x for x in keys if x["key"] == k), None)


def log_event(kind, key, detail=""):
    """kind: live | ended | rejected | disabled | kicked | added | removed | changed"""
    now = time.time()
    with lock:
        last = events[-1] if events else None
        # collapse repeats (e.g. an encoder retrying a bad key every 15 s)
        if last and last["kind"] == kind and last["key"] == key and now - last["t"] < 300:
            last["count"] = last.get("count", 1) + 1
            last["t"] = now
            return
        ev = {"t": now, "kind": kind, "key": key, "detail": detail, "count": 1}
        events.append(ev)
        try:
            with open(EVENTS_FILE, "a") as f:
                f.write(json.dumps(ev) + "\n")
            # keep the file from growing forever
            if os.path.getsize(EVENTS_FILE) > 2_000_000:
                with open(EVENTS_FILE, "w") as f:
                    f.writelines(json.dumps(e) + "\n" for e in events)
        except OSError:
            pass


# ---------- nginx ----------
def nginx_get(path):
    with urllib.request.urlopen(NGINX + path, timeout=3) as r:
        return r.read()


def kick(key):
    try:
        nginx_get("/control/drop/publisher?" + urllib.parse.urlencode({"app": APP, "name": key}))
        return True
    except Exception:
        return False


def txt(el, path, default=None):
    x = el.find(path)
    return x.text if x is not None and x.text is not None else default


def num(el, path):
    try:
        return float(txt(el, path, 0))
    except ValueError:
        return 0.0


def status():
    try:
        root = ET.fromstring(nginx_get("/stat"))
    except Exception as e:
        return {"online": False, "error": str(e)}
    streams = []
    for app in root.iterfind("./server/application"):
        if txt(app, "name") != APP:
            continue
        for s in app.iterfind("./live/stream"):
            clients = s.findall("client")
            pub = next((c for c in clients if c.find("publishing") is not None), None)
            name = txt(s, "name", "")
            k = find_key(name)
            streams.append({
                "name": name,
                "label": k["label"] if k else None,
                "known": k is not None,
                "live": pub is not None,
                "bw_in": num(s, "bw_in"),
                "bw_video": num(s, "bw_video"),
                "bw_audio": num(s, "bw_audio"),
                "bytes_in": num(s, "bytes_in"),
                "time_ms": num(pub, "time") if pub is not None else num(s, "time"),
                "width": txt(s, "meta/video/width"),
                "height": txt(s, "meta/video/height"),
                "fps": txt(s, "meta/video/frame_rate"),
                "vcodec": txt(s, "meta/video/codec"),
                "acodec": txt(s, "meta/audio/codec"),
                "sample_rate": txt(s, "meta/audio/sample_rate"),
                "channels": txt(s, "meta/audio/channels"),
                "encoder": txt(pub, "flashver") if pub is not None else None,
                "dropped": num(pub, "dropped") if pub is not None else 0,
                "viewers": sum(1 for c in clients if c.find("publishing") is None),
            })
    return {
        "online": True,
        "uptime": num(root, "uptime"),
        "bw_in": num(root, "bw_in"),
        "bw_out": num(root, "bw_out"),
        "connections": int(num(root, "server/application/live/nclients") or 0),
        "streams": streams,
    }


def new_key(label):
    slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:24] or "performer"
    alphabet = string.ascii_lowercase + string.digits
    while True:
        k = slug + "-" + "".join(secrets.choice(alphabet) for _ in range(8))
        if not find_key(k):
            return k


# ---------- http ----------
class H(BaseHTTPRequestHandler):
    server_version = "rtmp-admin"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def host_ok(self):
        # block DNS-rebinding: UI is only meant to be opened as localhost
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
        return host in ("localhost", "127.0.0.1", "::1")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))

        # --- called by nginx-rtmp (from inside the container) ---
        if u.path == "/auth":
            name = q.get("name", "")
            with lock:
                k = find_key(name)
                ok = bool(k and k.get("enabled", True))
                if ok:
                    k["last_used"] = time.time()
                    save(KEYS_FILE, keys)
            if ok:
                log_event("live", name)
                return self.send(200, "ok", "text/plain")
            log_event("disabled" if k else "rejected", name, q.get("flashver", ""))
            return self.send(403, "forbidden", "text/plain")
        if u.path == "/done":
            name = q.get("name", "")
            if find_key(name):
                log_event("ended", name)
            return self.send(200, "ok", "text/plain")

        if not self.host_ok():
            return self.send(403, {"error": "open this page via http://localhost"})

        if u.path in ("/", "/index.html"):
            with open(os.path.join(STATIC, "index.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if u.path == "/api/status":
            return self.send(200, status())
        if u.path == "/api/keys":
            with lock:
                return self.send(200, keys)
        if u.path == "/api/events":
            with lock:
                return self.send(200, list(events)[::-1])
        if u.path == "/api/settings":
            return self.send(200, settings)
        self.send(404, {"error": "not found"})

    def do_POST(self):
        # custom header forces a CORS preflight, so other websites can't call this
        if not self.host_ok() or self.headers.get("X-Admin") != "1":
            return self.send(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.send(400, {"error": "bad json"})
        path = urllib.parse.urlparse(self.path).path

        if path == "/api/keys":
            label = (body.get("label") or "").strip()[:60]
            custom = (body.get("key") or "").strip()
            if not label:
                return self.send(400, {"error": "Enter a performer name."})
            with lock:
                if custom:
                    if not KEY_RE.match(custom):
                        return self.send(400, {"error": "Keys may use letters, numbers, - and _ (3–64 chars)."})
                    if find_key(custom):
                        return self.send(400, {"error": "That key already exists."})
                k = {"key": custom or new_key(label), "label": label, "enabled": True,
                     "created": time.time(), "last_used": None}
                keys.append(k)
                save(KEYS_FILE, keys)
            log_event("added", k["key"], label)
            return self.send(200, k)

        if path == "/api/keys/update":
            with lock:
                k = find_key(body.get("key", ""))
                if not k:
                    return self.send(404, {"error": "No such key."})
                if "label" in body:
                    k["label"] = str(body["label"]).strip()[:60] or k["label"]
                if "enabled" in body:
                    k["enabled"] = bool(body["enabled"])
                save(KEYS_FILE, keys)
            if body.get("enabled") is False:
                kick(k["key"])
            log_event("changed", k["key"], "enabled" if k["enabled"] else "disabled")
            return self.send(200, k)

        if path == "/api/keys/delete":
            name = body.get("key", "")
            with lock:
                k = find_key(name)
                if not k:
                    return self.send(404, {"error": "No such key."})
                keys.remove(k)
                save(KEYS_FILE, keys)
            kick(name)
            log_event("removed", name, k["label"])
            return self.send(200, {"ok": True})

        if path == "/api/kick":
            name = body.get("key", "")
            ok = kick(name)
            log_event("kicked", name)
            return self.send(200 if ok else 502, {"ok": ok})

        if path == "/api/kick-all":
            live = [s["name"] for s in status().get("streams", []) if s["live"]]
            for name in live:
                kick(name)
                log_event("kicked", name)
            return self.send(200, {"kicked": live})

        if path == "/api/settings":
            url = str(body.get("server_url", "")).strip()[:200]
            if url:
                settings["server_url"] = url
                save(SETTINGS_FILE, settings)
            return self.send(200, settings)

        self.send(404, {"error": "not found"})


def watchdog():
    """This container shares nginx's network. If nginx restarts on its own, that network is
    replaced and we can no longer reach it, so exit and let Docker restart us into the new one."""
    misses = 0
    while True:
        time.sleep(5)
        try:
            nginx_get("/stat")
            misses = 0
        except Exception:
            misses += 1
            if misses >= 4:
                print("nginx unreachable for 20 s; restarting to rejoin its network", flush=True)
                os._exit(1)


if __name__ == "__main__":
    print("rtmp-admin listening on :8000", flush=True)
    threading.Thread(target=watchdog, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
