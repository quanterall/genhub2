# genhub2.quanterall.com

GenHub2's public page and a live GenHub2 site, run on the build host (10.55.66.2). TLS ends at the edge server
(65.108.62.183 = 10.55.66.1), which proxies to this host over the VPN, as for quanterall.com.

| path | what |
|---|---|
| `/` | the public page ([`www/`](www/)) |
| `/app/` | the GenHub2 site: login with a password and a one-time code; accounts by invitation |
| `/api/`, `/ws`, `/static/`, `/beacon/`, `/ga4gh/` | the GenHub2 node |
| `/metrics` | not served |

The site holds **public genomes only**. It is not for patients' data: a lab runs GenHub2 on its own nodes, on
encrypted volumes. This host's disk is not encrypted, so the site runs with `storage_encryption` set to `warn`.

## On the build host

```sh
git clone https://github.com/quanterall/genhub2 ~/genhub2-site/src && cd ~/genhub2-site/src
sh deploy/genhub2.quanterall.com/setup.sh ~/genhub2-site/data ~/genhub2-dev/data   # settings; bundles hard-linked
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" -e HOME="$PWD/.cache-home" genhub2-dev rebar3 compile
# the first admin, with the site stopped: prints the one-time secret for the authenticator app, once
GENHUB2_DATA=$HOME/genhub2-site/data sh scripts/genhub2-admin.sh ~/genhub2-site/data/mnesia add_user NAME admin
docker compose -f deploy/genhub2.quanterall.com/compose.yml up -d
curl -s -o /dev/null -w '%{http_code}\n' http://10.55.66.2:8130/app/                 # 200
```

The admin then adds the other users on the page (Users). To update: `git pull`, then
`docker compose -f deploy/genhub2.quanterall.com/compose.yml restart genhub2` (the node compiles at start).

## On the edge server

[`edge-nginx.conf`](edge-nginx.conf): the server block for `genhub2.quanterall.com`, then the certificate with
`sudo certbot --nginx --non-interactive --agree-tos --no-redirect -d genhub2.quanterall.com`. HTTP goes to HTTPS on
the build host (on `X-Forwarded-Proto`), so certbot's challenge on port 80 is answered at the edge.

## Later

- **The structure view:** off here. This site needs its own key (`scripts/genhub2-admin.sh ... viewer_key`),
  registered on TechUPGRADE's production installation, and a joint test with it, before `structure_viewer` is set
  in `site.config`. The test key `genhub2-test-2026a` is not for this site.
- **Metrics:** set `metrics_token` in `site.config` and scrape the node from inside the site's network; nginx does
  not serve `/metrics`.
