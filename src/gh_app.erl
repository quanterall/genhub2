-module(gh_app).
-behaviour(application).
-export([start/2, stop/1]).

%% role site (the default): the site's services, jobs and gateway. role worker: one of the lab's further nodes, which
%% only runs the tasks the site's executor sends it (gh_jobs, executor {nodes, ...}), with its own store and
%% reference copies under data_dir.
start(_Type, _Args) ->
    lists:foreach(fun pq_task:allow/1, application:get_env(genhub2, task_modules, [])),
    case application:get_env(genhub2, role, site) of
        worker -> gh_sup:start_link(worker);
        site -> site()
    end.

site() ->
    ok = gh_jobs:tables(),
    ok = gh_accounts:tables(),
    ok = gh_audit:tables(),
    ok = gh_monitor:tables(),
    {ok, Sup} = gh_sup:start_link(),
    _ = case application:get_env(genhub2, http) of
            {ok, undefined} -> ok;
            _ -> {ok, _} = gh_web:start()
        end,
    {ok, Sup}.

stop(_State) ->
    _ = gh_web:stop(),
    ok.
