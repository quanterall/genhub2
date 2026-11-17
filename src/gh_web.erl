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
%%   GET  /api/audit?from=N&limit=M, GET /api/audit/verify    the audit log (gh_audit); whether its chain is whole
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
                         {"/api/jobs/:id/:export", gh_web_api, export},
                         {"/api/trees", gh_web_api, trees},
                         {"/api/summary", gh_web_api, summary},
                         {"/api/files/:hash", gh_web_api, file},
                         {"/api/login", gh_web_api, login},
                         {"/api/logout", gh_web_api, logout},
                         {"/api/me", gh_web_api, me},
                         {"/api/users", gh_web_api, users},
                         {"/api/users/:name/disable", gh_web_api, user_disable},
                         {"/api/audit", gh_web_api, audit},
                         {"/api/audit/verify", gh_web_api, audit_verify},
                         {"/ws", gh_web_ws, []}]}]),
    cowboy:start_clear(gh_http, [{ip, Ip}, {port, Port}], #{env => #{dispatch => Dispatch}}).

-spec stop() -> ok | {error, not_found}.
stop() -> cowboy:stop_listener(gh_http).
