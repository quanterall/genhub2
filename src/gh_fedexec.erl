%% A federation executor for GenHub2's tasks (FS 4.5, plan section 8 item 2): the prototype of PQCF's, to move into
%% PQCF (pq_rexec) once its design is agreed. Tasks are PQCF tasks ({pq_task, Module, Args}); those whose module gives
%% a container form (Module:container(Args), e.g. gh_phylo's distance blocks and bootstrap replicates) go to the FVLLMP
%% node GenHub2 runs on (gh_fed), which runs each on itself or on a peer. The others run here, on PQCF's local
%% executor. Results come back in task order and are the same as the local executor's: the container writes the same
%% file, so the result has the same hash.
%%
%% Each provenance record is PQCF's (pq_task:run_traced/2), with node <<"federation:", Peer>> for where it ran and
%% the TES task's id and image.
-module(gh_fedexec).
-export([map/2, map_traced/2]).

-spec map([pq_task:task()], map()) -> [term()].
map(Tasks, Opts) -> [R || {R, _} <- map_traced(Tasks, Opts)].

%% Opts: slots (tasks at once on the node; the setting federation's slots, or 1), task_timeout (ms)
-spec map_traced([pq_task:task()], map()) -> [{term(), map()}].
map_traced(Tasks, Opts) ->
    Indexed = lists:enumerate(Tasks),
    {Remote, Local} = lists:partition(fun({_, T}) -> container(T) =/= none end, Indexed),
    Slots = maps:get(slots, Opts, maps:get(slots, gh_fed:config(), 1)),
    Timeout = maps:get(task_timeout, Opts, 3600000),
    Self = self(),
    LocalPid = spawn_link(fun() ->
                                  Rs = pq_rexec:map_traced([T || {_, T} <- Local], local, Opts),
                                  Self ! {local_done, self(), lists:zip([I || {I, _} <- Local], Rs)}
                          end),
    RemoteRs = pool(Remote, Slots, Timeout),
    LocalRs = receive {local_done, LocalPid, L} -> L end,
    [R || {_, R} <- lists:keysort(1, RemoteRs ++ LocalRs)].

container({pq_task, Mod, Args}) ->
    lists:member(Mod, pq_task:allowed()) orelse error({task_not_allowed, Mod}),
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, container, 1) of
        true -> Mod:container(Args);
        false -> none
    end;
container(_) -> none.

%% the remote tasks, at most Slots at a time: [{Index, {Result, Provenance}}]
pool(Tasks, Slots, Timeout) -> pool(Tasks, Slots, Timeout, #{}, []).

pool([], _, _, Running, Done) when map_size(Running) =:= 0 -> Done;
pool([{I, T} | Rest], Slots, Timeout, Running, Done) when map_size(Running) < Slots ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Self ! {fed_done, self(), one(T, Timeout)} end),
    pool(Rest, Slots, Timeout, Running#{Pid => {I, Ref}}, Done);
pool(Queue, Slots, Timeout, Running, Done) ->
    receive
        {fed_done, Pid, R} when is_map_key(Pid, Running) ->
            {{I, Ref}, Running2} = maps:take(Pid, Running),
            erlang:demonitor(Ref, [flush]),
            pool(Queue, Slots, Timeout, Running2, [{I, R} | Done]);
        {'DOWN', _, process, Pid, Reason} when is_map_key(Pid, Running), Reason =/= normal ->
            {{I, _}, Running2} = maps:take(Pid, Running),
            [exit(P, kill) || P <- maps:keys(Running2)],
            error({federation_task_failed, I, Reason})
    end.

one({pq_task, Mod, Args} = T, Timeout) ->
    Started = erlang:system_time(millisecond),
    TaskHash = hex(crypto:hash(sha256, term_to_binary(T, [deterministic]))),
    #{outputs := Outs, id := Id, ran_on := RanOn, seconds := Secs} =
        gh_fed:run((Mod:container(Args))#{tags => #{<<"genhub2_task">> => TaskHash}}, Timeout),
    #{image := Image} = gh_fed:config(),
    {Mod:result(Args, Outs),
     #{task => TaskHash, module => Mod,
       code => hex(Mod:module_info(md5)), describe => describe(Mod, Args),
       node => <<"federation:", RanOn/binary>>, tes_task => Id, image => list_to_binary(Image),
       started => Started, seconds => Secs}}.

describe(Mod, Args) ->
    case erlang:function_exported(Mod, describe, 1) of
        true -> Mod:describe(Args);
        false -> #{}
    end.

hex(B) -> binary:encode_hex(B, lowercase).
