%% The gateway (FS 3.1, 4.2): cowboy serving the web pages (priv/www) and the API.
%%   POST /api/uploads               the request body (FASTA/FASTQ, gzipped or not, up to 100 MB) into the store:
%%                                   {"hash", "bytes"}
%%   POST /api/jobs                  {"kind": "genome" | "reads", "inputs": [hash, ...], "primers": scheme (optional,
%%                                   for amplicon reads, e.g. "artic-v4.1")}: {"id"}
%%   GET  /api/jobs                  the jobs, newest first
%%   GET  /api/jobs/:id              a job with every step's results and provenance records
%%   GET  /api/jobs/:id/:export      report.csv, report.pdf, job.json; for a tree job tree.svg, tree.nwk
%%   POST /api/trees                 {"jobs": [id, ...], "method": "nj" | "fasttree"}: a tree job of their genomes
%%   GET  /api/summary               the site's monitoring counts (gh_monitor)
%%   GET  /api/files/:hash           a file from the store (a consensus genome, a tree)
%%   GET  /ws                        WebSocket: every event of the site (gh_events), as JSON
%%   POST /api/login                 {"user", "password", "code"}: a session cookie (gh_accounts: password and a
%%                                   one-time code, gh_totp)
%%   POST /api/logout, GET /api/me   the session's end; its user and role
%%   GET  /api/users, POST /api/users      the users; a new user {"user", "role", "password"}: its TOTP secret, once
%%   POST /api/users/:name/disable   a user disabled, their sessions ended
%%   POST /api/users/:name/reset     (admin) {"password"}: a new password and one-time secret, sessions ended
%%   POST /api/me/password           {"password", "code", "new_password"}: one's own; other sessions ended
%%   GET  /api/me/sessions, POST /api/me/sessions/end-others    one's open sessions; end all but this one
%%   GET  /api/audit?from=N&limit=M, GET /api/audit/verify    the audit log (gh_audit); whether its chain is whole
%%   GET  /api/aggregates            this site's aggregated counts (gh_agg, format genhub2-aggregates/1)
%%   POST /api/aggregates            another site's aggregates, imported (admin)
%%   GET  /api/aggregates/alerts     the alerts of this site's and the imported aggregates, merged
%%   GET  /api/viewer; GET /api/jobs/:id/structure-view?query=NAME   whether the structure viewer is on and for which
%%                                   viruses; a signed, short-lived link to it for one genome (gh_viewer), audited
%%   GET  /api/settings, PUT /api/settings (admin)   alert thresholds and notification settings (gh_settings)
%%   GET  /api/datasets, POST /api/datasets (admin)   shared datasets (gh_share): {"title", "description",
%%                                   "consent": [DUO codes], "jobs": [id, ...]}; GET /api/datasets/:id; POST
%%                                   /api/datasets/:id/withdraw (admin)
%%   GET  /ga4gh/drs/v1/service-info, /ga4gh/drs/v1/objects/:id[/access/:access_id], /ga4gh/drs/v1/objects/:id/data
%%                                   GA4GH DRS 1.4: the files of approved datasets (id = SHA-256), datasets as bundles
%%   GET  /beacon[/info], /beacon/datasets, /beacon/filtering_terms, /beacon/g_variants?referenceName=&start=
%%                                   &referenceBases=&alternateBases=&filters=lineage:X&requestedGranularity=
%%                                   GA4GH Beacon v2 over the approved shared datasets (gh_beacon)
%%   GET  /metrics                   the site's metrics for Prometheus (gh_metrics), with Authorization: Bearer
%%                                   <metrics_token>; off unless the setting metrics_token (32 bytes or more) is set
%%   (POST /api/jobs also takes "metadata": {"region", "collection_date", "sequences": {name: {...}}})
%% Every endpoint but login needs a session, and allows only some roles (gh_web_api:allowed/1); changing requests also
%% need the header x-genhub2: 1. The gateway listens on this machine by default; behind TLS, set secure_cookies.
-module(gh_web).
-export([start/0, stop/0]).

-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    #{ip := Ip, port := Port} = application:get_env(genhub2, http, #{ip => {127, 0, 0, 1}, port => 8480}),
    Www = filename:join(code:priv_dir(genhub2), "www"),
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/", cowboy_static, {file, filename:join(Www, "index.html")}},
                         {"/static/[...]", cowboy_static, {dir, Www}},
                         {"/api/uploads", gh_web_api, uploads},
                         {"/api/jobs", gh_web_api, jobs},
                         {"/api/jobs/:id", gh_web_api, job},
                         {"/api/jobs/:id/structure-view", gh_web_api, structure_view},
                         {"/api/jobs/:id/:export", gh_web_api, export},
                         {"/api/trees", gh_web_api, trees},
                         {"/api/summary", gh_web_api, summary},
                         {"/api/files/:hash", gh_web_api, file},
                         {"/api/aggregates", gh_web_api, aggregates},
                         {"/api/settings", gh_web_api, settings},
                         {"/api/viewer", gh_web_api, viewer},
                         {"/metrics", gh_web_api, metrics},
                         {"/beacon", gh_web_api, beacon_info},
                         {"/beacon/info", gh_web_api, beacon_info},
                         {"/beacon/datasets", gh_web_api, beacon_datasets},
                         {"/beacon/filtering_terms", gh_web_api, beacon_terms},
                         {"/beacon/g_variants", gh_web_api, beacon_variants},
                         {"/api/datasets", gh_web_api, datasets},
                         {"/api/datasets/:id", gh_web_api, dataset},
                         {"/api/datasets/:id/withdraw", gh_web_api, dataset_withdraw},
                         {"/ga4gh/drs/v1/service-info", gh_web_api, drs_info},
                         {"/ga4gh/drs/v1/objects/:id", gh_web_api, drs_object},
                         {"/ga4gh/drs/v1/objects/:id/access/:access_id", gh_web_api, drs_access},
                         {"/ga4gh/drs/v1/objects/:id/data", gh_web_api, drs_data},
                         {"/api/aggregates/alerts", gh_web_api, aggregate_alerts},
                         {"/api/login", gh_web_api, login},
                         {"/api/logout", gh_web_api, logout},
                         {"/api/me", gh_web_api, me},
                         {"/api/me/password", gh_web_api, me_password},
                         {"/api/me/sessions", gh_web_api, me_sessions},
                         {"/api/me/sessions/end-others", gh_web_api, me_end_sessions},
                         {"/api/users/:name/reset", gh_web_api, user_reset},
                         {"/api/users", gh_web_api, users},
                         {"/api/users/:name/disable", gh_web_api, user_disable},
                         {"/api/audit", gh_web_api, audit},
                         {"/api/audit/verify", gh_web_api, audit_verify},
                         {"/ws", gh_web_ws, []}]}]),
    cowboy:start_clear(gh_http, [{ip, Ip}, {port, Port}], #{env => #{dispatch => Dispatch}}).

-spec stop() -> ok | {error, not_found}.
stop() -> cowboy:stop_listener(gh_http).
