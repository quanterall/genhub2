%% The job service (FS 3.2, 4.2 orchestration): analyses submitted, run step by step through PQCF's executor, and kept
%% in Mnesia with every task's result and provenance record, so an interrupted analysis resumes after a restart and
%% every result can be audited (FS 3.4). Status changes are published as events (gh_events, topic
%% genhub/tasks/status).
%%
%% Tables (disc copies, this site only):
%%   gh_job   {gh_job, Id, Kind, Inputs, Params, State, Created, Updated, Error}  State: queued | running | done | failed
%%   gh_step  {gh_step, {Id, Step}, Results, Seconds}  Results: [{Result, Provenance}] in task order
-module(gh_jobs).
-compile({no_auto_import, [get/1]}).
-behaviour(gen_server).
-export([start_link/0, tables/0, submit/3, get/1, steps/1, view/1, wait/2, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(gh_job, {id, kind, inputs, params, state, created, updated, error}).
-record(gh_step, {key, results, seconds}).

-spec tables() -> ok.
tables() ->
    case mnesia:table_info(schema, storage_type) of
        disc_copies -> ok;
        ram_copies -> {atomic, ok} = mnesia:change_table_copy_type(schema, node(), disc_copies), ok
    end,
    [create(T, A) || {T, A} <- [{gh_job, record_info(fields, gh_job)}, {gh_step, record_info(fields, gh_step)}]],
    ok = mnesia:wait_for_tables([gh_job, gh_step], 60000).

create(T, Attrs) ->
    case mnesia:create_table(T, [{attributes, Attrs}, {disc_copies, [node()]}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, T}} -> ok
    end.

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A new job; its id.
-spec submit(genome | reads | tree, [gh_store:hash()], map()) -> binary().
submit(Kind, Inputs, Params) -> gen_server:call(?MODULE, {submit, Kind, Inputs, Params}).

-spec get(binary()) -> map() | undefined.
get(Id) ->
    case mnesia:dirty_read(gh_job, Id) of
        [J] -> to_map(J);
        [] -> undefined
    end.

-spec list() -> [map()].
list() ->
    [to_map(J) || J <- lists:reverse(lists:keysort(#gh_job.created, mnesia:dirty_match_object(#gh_job{_ = '_'})))].

%% Step => {[{Result, Provenance}], Seconds} of the steps done
-spec steps(binary()) -> #{atom() => {[{term(), map()}], float()}}.
steps(Id) ->
    maps:from_list([{S, {R, T}} || #gh_step{key = {_, S}, results = R, seconds = T}
                                       <- mnesia:dirty_match_object(#gh_step{key = {Id, '_'}, _ = '_'})]).

%% The job with its steps' results and provenance records, as the gateway and the exports show it; undefined if no
%% such job.
-spec view(binary()) -> map() | undefined.
view(Id) ->
    case get(Id) of
        undefined -> undefined;
        J ->
            Steps = maps:map(fun(_, {Results, Secs}) ->
                                     #{seconds => Secs, results => [R || {R, _} <- Results],
                                       provenance => [P || {_, P} <- Results]}
                             end, steps(Id)),
            J#{steps => Steps, order => gh_pipeline:steps(maps:get(kind, J))}
    end.

%% the job once done or failed, or timeout
-spec wait(binary(), timeout()) -> map() | timeout.
wait(Id, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Id, Deadline).

wait_loop(Id, Deadline) ->
    case get(Id) of
        #{state := S} = J when S =:= done; S =:= failed -> J;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> timeout;
                false -> receive after 100 -> wait_loop(Id, Deadline) end
            end
    end.

to_map(#gh_job{id = Id, kind = K, inputs = I, params = P, state = S, created = C, updated = U, error = E}) ->
    #{id => Id, kind => K, inputs => I, params => P, state => S, created => C, updated => U, error => E}.

%%% server: starts a runner per job; on start, resumes the jobs not finished

init([]) ->
    process_flag(trap_exit, true),
    Unfinished = [J || J <- mnesia:dirty_match_object(#gh_job{_ = '_'}), lists:member(J#gh_job.state, [queued, running])],
    {ok, lists:foldl(fun(J, Runs) -> start_run(J, Runs) end, #{}, Unfinished)}.

handle_call({submit, Kind, Inputs, Params}, _From, Runs) ->
    Now = erlang:system_time(millisecond),
    Id = iolist_to_binary(io_lib:format("job-~.36b-~.36b", [Now, erlang:unique_integer([positive])])),
    J = #gh_job{id = Id, kind = Kind, inputs = Inputs, params = Params, state = queued, created = Now, updated = Now},
    ok = mnesia:dirty_write(J),
    gh_events:publish(<<"genhub/tasks/status">>, #{job => Id, state => queued}),
    gh_events:publish(<<"genhub/sequences/new">>, #{job => Id, kind => Kind, inputs => Inputs}),
    {reply, Id, start_run(J, Runs)}.

handle_cast(_, Runs) -> {noreply, Runs}.

handle_info({'EXIT', Pid, Reason}, Runs) ->
    case maps:take(Pid, Runs) of
        {Id, Runs2} when Reason =/= normal -> finish(Id, failed, Reason), {noreply, Runs2};
        {_, Runs2} -> {noreply, Runs2};
        error -> {noreply, Runs}
    end;
handle_info(_, Runs) -> {noreply, Runs}.

start_run(#gh_job{id = Id} = J, Runs) ->
    Pid = spawn_link(fun() -> run(J) end),
    Runs#{Pid => Id}.

run(#gh_job{id = Id, kind = Kind} = J) ->
    update(Id, running, undefined),
    Job = to_map(J),
    Exec = application:get_env(genhub2, executor, local),
    _ = lists:foldl(
      fun(Step, Done) ->
              case mnesia:dirty_read(gh_step, {Id, Step}) of
                  [#gh_step{results = R}] -> Done#{Step => [Res || {Res, _} <- R]};
                  [] ->
                      T0 = erlang:monotonic_time(),
                      Tasks = gh_pipeline:tasks(Step, Job, Done),
                      R = pq_rexec:map_traced(Tasks, Exec, #{}),
                      Secs = erlang:convert_time_unit(erlang:monotonic_time() - T0, native, microsecond) / 1.0e6,
                      ok = mnesia:dirty_write(#gh_step{key = {Id, Step}, results = R, seconds = Secs}),
                      gh_events:publish(<<"genhub/tasks/status">>, #{job => Id, step => Step, seconds => Secs}),
                      [gh_events:publish(T, #{job => Id, step => Step, result => summary(Step, [Res || {Res, _} <- R])})
                       || T <- topics(Step)],
                      Done#{Step => [Res || {Res, _} <- R]}
              end
      end, #{}, gh_pipeline:steps(Kind)),
    finish(Id, done, undefined),
    gh_monitor:job_done(Id).

%% The specification's topics (FS 4.3) for a step's results. Messages carry the job, and results small enough to
%% travel: hashes for files, the classification calls, mutation counts, links.
topics(validate) -> [];
topics(consensus) -> [<<"genhub/sequences/processed">>];
topics(classify) -> [<<"genhub/results/classification">>];
topics(mutations) -> [<<"genhub/results/mutations">>];
topics(lineage) -> [<<"genhub/results/mutations">>];
topics(knowledge) -> [<<"genhub/results/knowledge">>];
topics(_) -> [].

summary(classify, [Calls]) ->
    [#{query => maps:get(<<"query">>, Q), call => maps:get(<<"call">>, Q)} || Q <- Calls];
summary(mutations, Rs) ->
    [#{query => maps:get(query, M), substitutions => length(maps:get(substitutions, M, [])),
       insertions => length(maps:get(insertions, M, [])), deletions => length(maps:get(deletions, M, []))}
     || M <- lists:append(Rs)];
summary(lineage, Rs) -> [maps:with([query, clade, pango, qc], L) || L <- lists:append(Rs)];
summary(consensus, [C]) -> maps:with([genome, reference, breadth, mean_depth], C);
summary(_, Rs) -> Rs.

finish(Id, State, Error) ->
    update(Id, State, Error),
    gh_events:publish(<<"genhub/tasks/status">>,
                      #{job => Id, state => State, error => case Error of undefined -> null; E -> fmt(E) end}).

fmt(E) -> iolist_to_binary(io_lib:format("~0P", [E, 30])).

update(Id, State, Error) ->
    [J] = mnesia:dirty_read(gh_job, Id),
    ok = mnesia:dirty_write(J#gh_job{state = State, error = Error, updated = erlang:system_time(millisecond)}).
