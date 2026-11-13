-module(gh_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    [pq_task:allow(M) || M <- application:get_env(genhub2, task_modules, [])],
    ok = gh_jobs:tables(),
    gh_sup:start_link().

stop(_State) -> ok.
