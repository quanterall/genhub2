%% The gateway (FS 3.1, 4.2): cowboy serving the web pages (priv/www) and the API.
%%   POST /api/uploads               the request body (FASTA/FASTQ, gzipped or not, up to 100 MB) into the store:
%%                                   {"hash", "bytes"}
%%   POST /api/jobs                  {"kind": "genome" | "reads", "inputs": [hash, ...]}: {"id"}
%%   GET  /api/jobs                  the jobs, newest first
%%   GET  /api/jobs/:id              a job with every step's results and provenance records
%%   GET  /api/files/:hash           a file from the store (a consensus genome, a tree)
%%   GET  /ws                        WebSocket: every event of the site (gh_events), as JSON
%% Phase A listens on this machine only; accounts, roles and MFA come with sharing (phase C).
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
                         {"/api/files/:hash", gh_web_api, file},
                         {"/ws", gh_web_ws, []}]}]),
    cowboy:start_clear(gh_http, [{ip, Ip}, {port, Port}], #{env => #{dispatch => Dispatch}}).

-spec stop() -> ok | {error, not_found}.
stop() -> cowboy:stop_listener(gh_http).
