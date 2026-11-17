%% The FVLLMP federation's task interface (FS 4.5), as GenHub2 uses it: GA4GH TES 1.1 (a subset) and content-addressed
%% data, on the FVLLMP node GenHub2 runs on and only there. The node decides whether a task runs on it or on a peer
%% that accepts its tasks, under its owner's policy; GenHub2 sees the same task either way, and downloads the results
%% from its own node. Data on the node is named by SHA-256, as in GenHub2's store (gh_store), so a stored file's hash
%% is its name on the federation too, and every download is checked against it.
%%
%% Setting {federation, #{node := "http://127.0.0.1:18100", token_file := Path, image := "name@sha256:..."}}: the
%% token is read from its file for each request and never written to logs or results.
-module(gh_fed).
-export([config/0, service_info/0, usage/0, has/1, upload/1, download/1, submit/1, task/1, wait/2, cancel/1,
         run/2]).

-define(TERMINAL, [<<"COMPLETE">>, <<"EXECUTOR_ERROR">>, <<"SYSTEM_ERROR">>, <<"CANCELED">>]).

-spec config() -> map().
config() ->
    case application:get_env(genhub2, federation) of
        {ok, #{node := _, token_file := _} = C} -> C;
        _ -> error(no_federation_configured)
    end.

%% what this node lets GenHub2 do, and its room now
-spec service_info() -> map().
service_info() ->
    {200, I} = json(get, "/ga4gh/tes/v1/service-info", none),
    I.

-spec usage() -> map().
usage() ->
    {200, U} = json(get, "/fed/usage", none),
    U.

-spec has(gh_store:hash()) -> boolean().
has(Hash) ->
    case call(head, "/fed/data/sha256/" ++ binary_to_list(Hash), none) of
        {200, _} -> true;
        {404, _} -> false
    end.

%% a file of GenHub2's store onto the node, unless the node holds it already
-spec upload(gh_store:hash()) -> ok.
upload(Hash) ->
    case has(Hash) of
        true -> ok;
        false ->
            {ok, Bin} = file:read_file(gh_store:path(Hash)),
            case call(put, "/fed/data/sha256/" ++ binary_to_list(Hash), {"application/octet-stream", Bin}) of
                {C, _} when C =:= 200; C =:= 201 -> ok;
                {C, Body} -> error({upload_refused, Hash, C, Body})
            end
    end.

%% a file from the node into GenHub2's store, checked against its hash
-spec download(gh_store:hash()) -> gh_store:hash().
download(Hash) ->
    case gh_store:has(Hash) of
        true -> Hash;
        false ->
            {200, Bin} = call(get, "/fed/data/sha256/" ++ binary_to_list(Hash), none),
            Hash = gh_store:put_binary(Bin)
    end.

-spec submit(map()) -> binary().
submit(Task) ->
    case json(post, "/ga4gh/tes/v1/tasks", Task) of
        {200, #{<<"id">> := Id}} -> Id;
        {C, Body} -> error({task_refused, C, Body})
    end.

-spec task(binary()) -> map().
task(Id) ->
    {200, T} = json(get, "/ga4gh/tes/v1/tasks/" ++ binary_to_list(Id) ++ "?view=FULL", none),
    T.

%% the task once in a terminal state; QUEUED may last while the node looks for room or a peer
-spec wait(binary(), timeout()) -> map().
wait(Id, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Id, Deadline, 200).

wait_loop(Id, Deadline, Sleep) ->
    T = task(Id),
    case lists:member(maps:get(<<"state">>, T), ?TERMINAL) of
        true -> T;
        false ->
            erlang:monotonic_time(millisecond) > Deadline andalso error({task_timeout, Id}),
            receive after Sleep -> wait_loop(Id, Deadline, min(Sleep * 2, 3000)) end
    end.

-spec cancel(binary()) -> ok.
cancel(Id) ->
    {200, _} = call(post, "/ga4gh/tes/v1/tasks/" ++ binary_to_list(Id) ++ ":cancel", {"application/json", <<"{}">>}),
    ok.

%% A task described as a container command (gh_phylo:container/1): its inputs uploaded by hash, the task run where
%% the node places it, its outputs downloaded into the store and checked. #{outputs => #{Path => Hash}, id, ran_on,
%% state, seconds}, or error({task_failed, State, Logs}).
-spec run(map(), timeout()) -> map().
run(#{name := Name, description := Desc, inputs := Inputs, outputs := Outputs, command := Cmd,
      resources := #{cpu := Cpu, ram_gb := Ram, disk_gb := Disk}} = Spec, Timeout) ->
    #{image := Image} = config(),
    [ok = upload(H) || {_, H} <- Inputs],
    Task = #{<<"name">> => Name, <<"description">> => Desc,
             <<"inputs">> => [#{<<"path">> => P, <<"url">> => <<"sha256:", H/binary>>} || {P, H} <- Inputs],
             <<"outputs">> => [#{<<"path">> => P} || P <- Outputs],
             <<"resources">> => #{<<"cpu_cores">> => Cpu, <<"ram_gb">> => Ram, <<"disk_gb">> => Disk},
             <<"executors">> => [#{<<"image">> => list_to_binary(Image), <<"command">> => Cmd, <<"workdir">> => <<"/work">>,
                                   <<"env">> => #{<<"GH2K_THREADS">> => integer_to_binary(Cpu)}}],
             %% tags find a task again after a restart (GET /tasks): e.g. the PQCF task's hash
             <<"tags">> => maps:get(tags, Spec, #{})},
    T0 = erlang:monotonic_time(millisecond),
    Id = submit(Task),
    Final = wait(Id, Timeout),
    Secs = (erlang:monotonic_time(millisecond) - T0) / 1000,
    RanOn = case maps:get(<<"usage">>, Final, #{}) of #{<<"ran_on">> := P} -> P; _ -> <<"local">> end,
    case {maps:get(<<"state">>, Final), maps:get(<<"logs">>, Final, [])} of
        {<<"COMPLETE">>, [#{<<"outputs">> := Outs} | _]} ->
            Got = maps:from_list([{P, download(H)} || #{<<"path">> := P, <<"url">> := <<"sha256:", H/binary>>} <- Outs]),
            [is_map_key(P, Got) orelse error({missing_output, Id, P}) || P <- Outputs],
            #{outputs => Got, id => Id, ran_on => RanOn, state => complete, seconds => Secs};
        {State, Logs} ->
            error({task_failed, Id, State, Logs})
    end.

%%% HTTP to this node, with GenHub2's token

json(Method, Path, none) ->
    {C, B} = call(Method, Path, none),
    {C, decode(B)};
json(Method, Path, Map) ->
    {C, B} = call(Method, Path, {"application/json", iolist_to_binary(json:encode(Map))}),
    {C, decode(B)}.

decode(<<>>) -> #{};
decode(B) -> try json:decode(B) catch _:_ -> #{<<"body">> => B} end.

call(Method, Path, Body) ->
    #{node := Node, token_file := TF} = config(),
    {ok, Tok} = file:read_file(TF),
    Hdrs = [{"authorization", "Bearer " ++ binary_to_list(string:trim(Tok))}],
    Req = case Body of
              none -> {Node ++ Path, Hdrs};
              {Type, Bin} -> {Node ++ Path, Hdrs, Type, Bin}
          end,
    _ = application:ensure_all_started(inets),
    case httpc:request(Method, Req, [{timeout, 600000}, {connect_timeout, 10000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Resp}} -> {Code, Resp};
        {error, R} -> error({federation_node_unreachable, Node, R})
    end.
