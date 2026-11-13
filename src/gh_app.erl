-module(gh_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    lists:foreach(fun pq_task:allow/1, application:get_env(genhub2, task_modules, [])),
    ok = gh_jobs:tables(),
    {ok, Sup} = gh_sup:start_link(),
    _ = case application:get_env(genhub2, http) of
            {ok, undefined} -> ok;
            _ -> {ok, _} = gh_web:start()
        end,
    {ok, Sup}.

stop(_State) ->
    _ = gh_web:stop(),
    ok.
