-module(gh_app).
-behaviour(application).
-export([start/2, stop/1]).

%% role site (the default): the site's services, jobs and gateway. role worker: one of the lab's further nodes, which
%% only runs the tasks the site's executor sends it (gh_jobs, executor {nodes, ...}), with its own store and
%% reference copies under data_dir.
start(_Type, _Args) ->
    ok = gh_storage:enforce(),
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
    ok = gh_share:tables(),
    ok = gh_settings:tables(),
    {ok, Sup} = gh_sup:start_link(),
    _ = case gh_storage:status() of
            off -> gh_audit:log(<<"system">>, storage_check, <<>>, ok, #{mode => off});
            St -> [gh_audit:log(<<"system">>, storage_check, D, case R of {encrypted, _} -> ok; _ -> failed end,
                                #{result => element(1, R), device => element(2, R)}) || {D, R} <- maps:to_list(St)]
        end,
    _ = case application:get_env(genhub2, http) of
            {ok, undefined} -> ok;
            _ -> {ok, _} = gh_web:start()
        end,
    {ok, Sup}.

stop(_State) ->
    _ = gh_web:stop(),
    ok.
