"""The film's helpers: the site's address, the film accounts (~/genhub2-film/users.txt, outside the repository: name,
password and authenticator secret per line), one-time codes (RFC 6238) and API calls as one of them."""
import base64, hashlib, hmac, json, os, struct, time, urllib.request

SITE = os.environ.get("GENHUB2_FILM_SITE", "https://genhub2.quanterall.com")
FILM = os.path.expanduser("~/genhub2-film")
USERS = {l.split()[0]: l.split()[1:] for l in open(os.path.join(FILM, "users.txt")) if l.strip()}
USED = os.path.join(FILM, "totp-used.json")                # the steps already used, across runs


def _used():
    try:
        return json.load(open(USED))
    except (OSError, ValueError):
        return {}


def code(user):
    """the code of the next unused 30-second step: the site accepts each code once, and at most the next step"""
    secret = base64.b32decode(USERS[user][1] + "=" * (-len(USERS[user][1]) % 8))
    while True:
        used = _used()
        now = int(time.time()) // 30
        step = max(now, used.get(user, -1) + 1)
        if step <= now + 1:
            break
        time.sleep(5)
    used[user] = step
    json.dump(used, open(USED, "w"))
    h = hmac.new(secret, struct.pack(">Q", step), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7fffffff) % 1000000)


class Api:
    def __init__(self, user):
        self.cookie = ""
        r = self.call("POST", "/api/login", {"user": user, "password": USERS[user][0], "code": code(user)})
        assert r["role"], r

    def call(self, method, path, body=None, raw=None, ctype="application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(SITE + path, data=data, method=method,
                                     headers={"x-genhub2": "1", "cookie": self.cookie, "content-type": ctype})
        with urllib.request.urlopen(req, timeout=600) as resp:
            for k, v in resp.headers.items():
                if k.lower() == "set-cookie" and v.startswith("gh2_session"):
                    self.cookie = v.split(";")[0]
            out = resp.read()
            return json.loads(out) if out else None
