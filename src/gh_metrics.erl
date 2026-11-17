%% The site's metrics for Prometheus (FS 6.1: each site's own monitoring), in its text exposition format
%% (https://prometheus.io/docs/instrumenting/exposition_formats/). Served by the gateway at /metrics only when the
%% setting metrics_token is set, and then only to a request with Authorization: Bearer <token>. Counts only: no job
%% ids, users' names, file hashes or results.
-module(gh_metrics).
-export([render/0]).

-spec render() -> iodata().
render() ->
    Jobs = count([{K, S} || {gh_job, _, K, _, _, S, _, _, _} <- mnesia:dirty_match_object({gh_job, '_', '_', '_', '_', '_', '_', '_', '_'})]),
    Steps = lists:foldl(fun({gh_step, {_, Step}, _, Secs}, M) when is_number(Secs) ->
                                maps:update_with(Step, fun({N, T}) -> {N + 1, T + Secs} end, {1, Secs}, M);
                           (_, M) -> M
                        end, #{}, mnesia:dirty_match_object({gh_step, '_', '_', '_'})),
    Users = count([R || #{role := R, disabled := false} <- gh_accounts:users()]),
    Datasets = count([S || #{state := S} <- gh_share:list()]),
    [metric(<<"genhub2_jobs">>, gauge, <<"Jobs by kind and state">>,
            [{[{kind, K}, {state, S}], N} || {{K, S}, N} <- lists:sort(maps:to_list(Jobs))]),
     metric(<<"genhub2_step_runs_total">>, counter, <<"Analysis steps run, by step">>,
            [{[{step, S}], N} || {S, {N, _}} <- lists:sort(maps:to_list(Steps))]),
     metric(<<"genhub2_step_seconds_total">>, counter, <<"Time spent in analysis steps, by step">>,
            [{[{step, S}], T} || {S, {_, T}} <- lists:sort(maps:to_list(Steps))]),
     metric(<<"genhub2_users">>, gauge, <<"Active users by role">>,
            [{[{role, R}], N} || {R, N} <- lists:sort(maps:to_list(Users))]),
     metric(<<"genhub2_sessions">>, gauge, <<"Open sessions">>, [{[], mnesia:table_info(gh_session, size)}]),
     metric(<<"genhub2_audit_records">>, gauge, <<"Records in the audit log">>, [{[], mnesia:table_info(gh_audit, size)}]),
     metric(<<"genhub2_datasets">>, gauge, <<"Shared datasets by state">>,
            [{[{state, S}], N} || {S, N} <- lists:sort(maps:to_list(Datasets))]),
     metric(<<"genhub2_aggregate_imports">>, gauge, <<"Other sites' aggregates held">>, [{[], length(gh_monitor:imported())}]),
     metric(<<"genhub2_erlang_processes">>, gauge, <<"Erlang processes">>, [{[], erlang:system_info(process_count)}]),
     metric(<<"genhub2_erlang_memory_bytes">>, gauge, <<"Memory the Erlang VM uses">>, [{[], erlang:memory(total)}])].

metric(Name, Type, Help, Samples) ->
    [<<"# HELP ">>, Name, $\s, Help, $\n, <<"# TYPE ">>, Name, $\s, atom_to_binary(Type), $\n,
     [[Name, labels(Ls), $\s, num(V), $\n] || {Ls, V} <- Samples]].

labels([]) -> <<>>;
labels(Ls) -> [${, lists:join($,, [[atom_to_binary(K), "=\"", value(V), $"] || {K, V} <- Ls]), $}].

value(V) when is_atom(V) -> atom_to_binary(V);
value(V) when is_binary(V) -> V.

num(V) when is_integer(V) -> integer_to_binary(V);
num(V) when is_float(V) -> float_to_binary(V, [short]).

count(L) -> lists:foldl(fun(X, M) -> maps:update_with(X, fun(N) -> N + 1 end, 1, M) end, #{}, L).
