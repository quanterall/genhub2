%% Phase A's gateway and MQTT check: GenHub2 as a lab would use it, through its HTTP API, its WebSocket and the site's
%% EMQX broker (FS 3.1, 4.2-4.4).
%%
%%   1. the page is served;
%%   2. a genome (NC_045512.2) uploaded and analysed through the API; its results read back;
%%   3. the job followed live on the WebSocket and on MQTT: the specification's topics carry its messages;
%%   4. a job requested on MQTT (genhub/sequences/new, as a sequencer's integration would) runs;
%%   5. the exports: CSV, PDF and JSON of a job; a tree job of both jobs' genomes, as SVG and Newick;
%%   6. monitoring: the site's counts, and an alert for the first species and lineage, only for the first job;
%%   7. requests the gateway must refuse: a job for a file not in the store, an upload over 100 MB, a tree of one
%%      sequence.
%%
%% Needs the reference bundles of the phase A acceptance test, and EMQX on 127.0.0.1:21883 (run_gateway.sh); the
%% gateway listens on 127.0.0.1:28090.
-module(gh_gateway_check).
-export([main/1]).

-define(URL, "http://127.0.0.1:28090").
-define(MQTT_PORT, 21883).

-spec main([string()]) -> no_return().
main([Out]) ->
    ok = application:load(genhub2),
    ok = application:set_env(genhub2, mqtt, #{host => "127.0.0.1", port => ?MQTT_PORT}),
    ok = application:set_env(genhub2, http, #{ip => {127, 0, 0, 1}, port => 28090}),
    {ok, _} = application:ensure_all_started([genhub2, gun]),
    T0 = erlang:monotonic_time(millisecond),
    Mqtt = mqtt_listener(),
    Ws = ws_listener(),
    wait_mqtt_bridge(50),
    Page = page(),
    {Upload, Job} = genome_job(),
    timer:sleep(1000),
    MqttMsgs = collected(Mqtt),
    WsMsgs = collected(Ws),
    Viamqtt = mqtt_job(maps:get(hash, Upload)),
    Exports = exports(maps:get(id, Job)),
    Tree = tree([maps:get(id, Job), maps:get(id, Viamqtt)]),
    {200, _, Sum} = http(get, "/api/summary", none),
    Summary = json:decode(Sum),
    Alerts = [M || {<<"genhub/alerts">>, M} <- collected(Mqtt)],
    Refused = refused(maps:get(id, Job)),
    Checks = checks(Page, Job, MqttMsgs, WsMsgs, Viamqtt, Refused)
        ++ more_checks(Job, Viamqtt, Exports, Tree, Summary, Alerts),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), emqx => <<"emqx/emqx:5.8.9">>,
          upload => Upload, job_seconds => maps:get(seconds, Job), job_state => maps:get(state, Job),
          mqtt_topics => count([T || {T, _} <- MqttMsgs]), websocket_topics => count([T || {T, _} <- WsMsgs]),
          job_from_mqtt => Viamqtt, exports => Exports, tree => maps:remove(svg, Tree), summary => Summary,
          alerts => Alerts, refused => Refused, checks => Checks,
          seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(gh_json:term(R))),
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    io:format("written ~s~n", [Out]),
    halt(case [C || #{ok := false} = C <- Checks] of [] -> 0; _ -> 1 end).

%%% listeners: processes collecting what arrives, returned by collected/1

mqtt_listener() ->
    spawn_link(fun() ->
        {ok, C} = emqtt:start_link([{host, "127.0.0.1"}, {port, ?MQTT_PORT}, {clientid, <<"gh-gateway-check">>},
                                    {proto_ver, v5}]),
        {ok, _} = emqtt:connect(C),
        {ok, _, _} = emqtt:subscribe(C, #{}, [{<<"genhub/#">>, [{qos, 1}]}]),
        collect([], C)
    end).

ws_listener() ->
    spawn_link(fun() ->
        {ok, P} = gun:open("127.0.0.1", 28090),
        {ok, _} = gun:await_up(P, 5000),
        S = gun:ws_upgrade(P, "/ws"),
        receive {gun_upgrade, P, S, [<<"websocket">>], _} -> ok after 5000 -> error(ws_upgrade) end,
        collect([], P)
    end).

collect(Acc, Conn) ->
    receive
        {publish, #{topic := T, payload := Pl}} -> collect([{T, json:decode(Pl)} | Acc], Conn);
        {gun_ws, _, _, {text, Txt}} ->
            #{<<"topic">> := T, <<"message">> := M} = json:decode(Txt),
            collect([{T, M} | Acc], Conn);
        {give, From} -> From ! {collected, lists:reverse(Acc)}, collect(Acc, Conn);
        _ -> collect(Acc, Conn)
    end.

collected(Pid) ->
    Pid ! {give, self()},
    receive {collected, L} -> L after 5000 -> [] end.

wait_mqtt_bridge(0) -> error(mqtt_bridge_not_connected);
wait_mqtt_bridge(N) ->
    case sys:get_state(gh_mqtt) of
        #{client := C} when is_pid(C) -> ok;
        _ -> timer:sleep(200), wait_mqtt_bridge(N - 1)
    end.

%%% HTTP

http(Method, Path, Body) ->
    Req = case Body of
              none -> {?URL ++ Path, []};
              {Type, B} -> {?URL ++ Path, [], Type, B}
          end,
    {ok, {{_, Status, _}, Headers, RespBody}} = httpc:request(Method, Req, [{timeout, 600000}], [{body_format, binary}]),
    {Status, proplists:get_value("content-type", Headers), RespBody}.

page() ->
    {S, Type, Body} = http(get, "/", none),
    {S2, _, Js} = http(get, "/static/app.js", none),
    #{status => S, type => list_to_binary(Type), has_title => binary:match(Body, <<"<title>GenHub2</title>">>) =/= nomatch,
      script_status => S2, script_bytes => byte_size(Js)}.

genome_job() ->
    Refs = maps:get(refs, gh_config:params()),
    Fasta = gh_store:with_tmp(fun(Dir) ->
                                      F = filename:join(Dir, "g.fa"),
                                      gh_mutations:reference(Refs, <<"NC_045512.2">>, node(), F),
                                      {ok, B} = file:read_file(F),
                                      B
                              end),
    {201, _, U} = http(post, "/api/uploads", {"application/octet-stream", Fasta}),
    #{<<"hash">> := Hash, <<"bytes">> := Bytes} = json:decode(U),
    T0 = erlang:monotonic_time(millisecond),
    {201, _, J} = http(post, "/api/jobs", {"application/json", json:encode(#{kind => genome, inputs => [Hash]})}),
    #{<<"id">> := Id} = json:decode(J),
    Job = poll(Id, 600),
    Secs = (erlang:monotonic_time(millisecond) - T0) / 1000,
    {200, _, Listing} = http(get, "/api/jobs", none),
    {FileStatus, _, File} = http(get, "/api/files/" ++ binary_to_list(Hash), none),
    {#{hash => Hash, bytes => Bytes},
     #{id => Id, seconds => Secs, state => maps:get(<<"state">>, Job), job => Job,
       listed => lists:member(Id, [maps:get(<<"id">>, X) || X <- json:decode(Listing)]),
       file_back => FileStatus =:= 200 andalso File =:= Fasta}}.

poll(Id, 0) -> error({timeout, Id});
poll(Id, N) ->
    {200, _, B} = http(get, "/api/jobs/" ++ binary_to_list(Id), none),
    case json:decode(B) of
        #{<<"state">> := S} = J when S =:= <<"done">>; S =:= <<"failed">> -> J;
        _ -> timer:sleep(500), poll(Id, N - 1)
    end.

%% a job requested on MQTT: the newest job afterwards is a new one for the same file, and it finishes
mqtt_job(Hash) ->
    Before = [maps:get(<<"id">>, X) || X <- list_jobs()],
    {ok, C} = emqtt:start_link([{host, "127.0.0.1"}, {port, ?MQTT_PORT}, {clientid, <<"gh-sequencer">>}, {proto_ver, v5}]),
    {ok, _} = emqtt:connect(C),
    {ok, _} = emqtt:publish(C, <<"genhub/sequences/new">>, json:encode(#{kind => genome, inputs => [Hash]}), [{qos, 1}]),
    ok = emqtt:disconnect(C),
    New = wait_new(Before, 50),
    case New of
        none -> #{started => false};
        Id ->
            J = poll(Id, 600),
            #{started => true, id => Id, state => maps:get(<<"state">>, J), inputs => maps:get(<<"inputs">>, J)}
    end.

list_jobs() ->
    {200, _, L} = http(get, "/api/jobs", none),
    json:decode(L).

wait_new(_, 0) -> none;
wait_new(Before, N) ->
    case [maps:get(<<"id">>, X) || X <- list_jobs()] -- Before of
        [Id | _] -> Id;
        [] -> timer:sleep(200), wait_new(Before, N - 1)
    end.

exports(Id) ->
    Get = fun(E) -> http(get, "/api/jobs/" ++ binary_to_list(Id) ++ "/" ++ E, none) end,
    {S1, T1, Csv} = Get("report.csv"),
    {S2, T2, Pdf} = Get("report.pdf"),
    {S3, _, Json} = Get("job.json"),
    #{csv => #{status => S1, type => list_to_binary(T1), species => binary:match(Csv, <<"Betacoronavirus pandemicum">>) =/= nomatch},
      pdf => #{status => S2, type => list_to_binary(T2), bytes => byte_size(Pdf), magic => binary:part(Pdf, 0, 8)},
      json => #{status => S3, id => maps:get(<<"id">>, json:decode(Json))}}.

tree(Ids) ->
    {201, _, B} = http(post, "/api/trees", {"application/json", json:encode(#{jobs => Ids, method => nj})}),
    #{<<"id">> := Id, <<"reference">> := Ref} = json:decode(B),
    J = poll(Id, 600),
    {S1, T1, Svg} = http(get, "/api/jobs/" ++ binary_to_list(Id) ++ "/tree.svg", none),
    {S2, _, Nwk} = http(get, "/api/jobs/" ++ binary_to_list(Id) ++ "/tree.nwk", none),
    Leaves = case re:run(Nwk, "[(,]([^(),:;]+):", [global, {capture, [1], binary}]) of
                 {match, L} -> lists:sort([X || [X] <- L]);
                 nomatch -> []
             end,
    #{id => Id, state => maps:get(<<"state">>, J), reference => Ref, svg_status => S1, svg_type => list_to_binary(T1),
      svg => Svg, svg_ok => binary:match(Svg, <<"<svg ">>) =/= nomatch, newick_status => S2, leaves => Leaves}.

more_checks(Job, ViaMqtt, Exports, Tree, Summary, Alerts) ->
    [J1, J2] = [maps:get(id, Job), maps:get(id, ViaMqtt)],
    Sp = [N || #{<<"name">> := <<"Betacoronavirus pandemicum">>, <<"count">> := N} <- maps:get(<<"species">>, Summary)],
    Lin = [N || #{<<"name">> := <<"B">>, <<"count">> := N, <<"first_job">> := F} <- maps:get(<<"lineages">>, Summary), F =:= J1],
    [check(<<"exports: CSV names the species, PDF is a PDF, JSON is the job">>,
           Exports =:= #{csv => #{status => 200, type => <<"text/csv; charset=utf-8">>, species => true},
                         pdf => (maps:get(pdf, Exports))#{status => 200, type => <<"application/pdf">>, magic => <<"%PDF-1.4">>},
                         json => #{status => 200, id => J1}}, Exports),
     check(<<"tree job of both genomes: done, SVG drawn, the reference and both genomes as leaves">>,
           maps:get(state, Tree) =:= <<"done">> andalso maps:get(svg_ok, Tree) andalso maps:get(svg_status, Tree) =:= 200
           andalso maps:get(leaves, Tree) =:= lists:sort([<<"NC_045512.2">>, <<J1/binary, "/NC_045512.2">>,
                                                          <<J2/binary, "/NC_045512.2">>]),
           maps:remove(svg, Tree)),
     check(<<"monitoring: two SARS-CoV-2 analyses, lineage B first seen in the first job">>, {Sp, Lin} =:= {[2], [2]},
           Summary),
     check(<<"alerts: first species and first lineage, for the first job only">>,
           lists:sort([{maps:get(<<"type">>, A), maps:get(<<"job">>, A)} || A <- Alerts])
           =:= [{<<"new_pango">>, J1}, {<<"new_species">>, J1}], Alerts)].

refused(Job) ->
    {S1, _, _} = http(post, "/api/jobs", {"application/json", json:encode(#{kind => genome, inputs => [binary:copy(<<"0">>, 64)]})}),
    {S2, _, _} = http(post, "/api/jobs", {"application/json", <<"{\"kind\": \"protein\"}">>}),
    {S3, _, _} = http(post, "/api/uploads", {"application/octet-stream", binary:copy(<<"A">>, 100000001)}),
    {S4, _, _} = http(get, "/api/jobs/job-none", none),
    {S5, _, _} = http(post, "/api/trees", {"application/json", json:encode(#{jobs => [Job], method => nj})}),
    #{unknown_file => S1, bad_kind => S2, too_large => S3, no_such_job => S4, tree_of_one => S5}.

%%% checks

checks(Page, Job, Mqtt, Ws, ViaMqtt, Refused) ->
    J = maps:get(job, Job),
    [[Call]] = maps:get(<<"results">>, maps:get(<<"classify">>, maps:get(<<"steps">>, J))),
    Species = maps:get(<<"species">>, maps:get(<<"call">>, Call)),
    MTopics = lists:usort([T || {T, _} <- Mqtt]),
    WTopics = lists:usort([T || {T, _} <- Ws]),
    Wanted = [<<"genhub/sequences/new">>, <<"genhub/tasks/status">>, <<"genhub/results/classification">>,
              <<"genhub/results/mutations">>, <<"genhub/results/knowledge">>],
    Id = maps:get(id, Job),
    MqttClass = [M || {<<"genhub/results/classification">>, #{<<"job">> := I} = M} <- Mqtt, I =:= Id],
    [check(<<"page and script served">>, maps:get(status, Page) =:= 200 andalso maps:get(has_title, Page)
                                         andalso maps:get(script_status, Page) =:= 200, Page),
     check(<<"genome job through the API: done">>, maps:get(state, Job) =:= <<"done">>, maps:get(state, Job)),
     check(<<"genome job: SARS-CoV-2 species">>, Species =:= <<"Betacoronavirus pandemicum">>, Species),
     check(<<"job listed; uploaded file served back unchanged">>, maps:get(listed, Job) andalso maps:get(file_back, Job),
           maps:with([listed, file_back], Job)),
     check(<<"MQTT: the specification's topics for the job">>, Wanted -- MTopics =:= [], MTopics),
     check(<<"MQTT: the classification message names the species">>,
           [S || #{<<"result">> := [#{<<"call">> := #{<<"species">> := S}}]} <- MqttClass] =:= [Species], MqttClass),
     check(<<"WebSocket: the same topics">>, Wanted -- WTopics =:= [], WTopics),
     check(<<"job requested on MQTT: started and done">>, maps:get(state, ViaMqtt, none) =:= <<"done">>, ViaMqtt),
     check(<<"refused: unknown file 400, bad kind 400, over 100 MB 413, unknown job 404, tree of one sequence 400">>,
           Refused =:= #{unknown_file => 400, bad_kind => 400, too_large => 413, no_such_job => 404, tree_of_one => 400},
           Refused)].

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => iolist_to_binary(io_lib:format("~0P", [Value, 40]))}.

count(L) -> lists:foldl(fun(X, M) -> maps:update_with(X, fun(C) -> C + 1 end, 1, M) end, #{}, L).
