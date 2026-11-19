%% The joint test with TechUPGRADE (their EXT-57; their plan docs/integration/joint-test-genhub2.md): GenHub2's side.
%% A GenHub2 test site with the published test key genhub2-test-2026a (iss test.genhub2.quanterall.com) analyses four
%% public genomes and opens the structure view genhub2.structures for each:
%%
%%   1. d614g       the reference Wuhan-Hu-1 (NC_045512.2) with A23403G: one change, S:D614G (sars-cov-2)
%%   2. ON544943    a BA.2 genome, many changes across several proteins (sars-cov-2)
%%   3. PP_0030E57  an RSV-A genome, clade A.D.3.11 (rsv-a)
%%   4. PP_002XZ5U  an RSV-B genome, clade B.D.E.1, with F:S211N (rsv-b)
%%
%% Genomes 2-4 are example sequences of Nextclade's datasets at pinned tags (run_joint.sh fetches them).
%%
%% Mode dry (no network): direct-mode links, each checked here as the viewer checks it, with the public key only:
%% the signature, the fields, the dataset, and that the mutations signed are the ones the result shows; no sample or
%% job names. A tampered link and an expired one are refused (bad_signature, expired).
%% Mode push (the joint test): the same, then each genome's hand-off pushed to <base>/ext/push; the handle that comes
%% back opens the view, for a person to check against the mutations listed here. A tampered payload and an expired
%% one, each signed with the test key, are pushed too and must be refused (400 {"error": "refused"}).
%%
%%   main([Out, Mode, Base, KeyFile, GenomeDir])
-module(gh_joint_check).
-export([main/1]).

-define(URL, "http://127.0.0.1:28090").
-define(MQTT_PORT, 21883).
-define(KID, <<"genhub2-test-2026a">>).
-define(ISS, <<"test.genhub2.quanterall.com">>).
-define(GENOMES, [{<<"d614g">>, <<"sars-cov-2">>}, {<<"ON544943">>, <<"sars-cov-2">>}, {<<"PP_0030E57">>, <<"rsv-a">>},
                  {<<"PP_002XZ5U">>, <<"rsv-b">>}]).

-spec main([string()]) -> no_return().
main([Out, Mode0, Base, KeyFile, GenomeDir]) ->
    Mode = list_to_atom(Mode0),
    true = lists:member(Mode, [dry, push]),
    ok = application:load(genhub2),
    ok = application:set_env(genhub2, mqtt, #{host => "127.0.0.1", port => ?MQTT_PORT}),
    ok = application:set_env(genhub2, http, #{ip => {127, 0, 0, 1}, port => 28090}),
    Viewer = #{base => Base, mode => direct, iss => ?ISS, active => ?KID,
               keys => #{?KID => #{alg => 'Ed25519', key_file => KeyFile}}},
    ok = application:set_env(genhub2, structure_viewer, Viewer),
    {ok, _} = application:ensure_all_started([genhub2, inets, ssl]),
    T0 = erlang:monotonic_time(millisecond),
    Pub = base64:decode(gh_viewer:public_key(KeyFile), #{mode => urlsafe, padding => false}),
    {ok, Secret} = gh_accounts:create(<<"joint-analyst">>, analyst, <<"a password for the check">>),
    {200, <<"analyst">>} = login(<<"joint-analyst">>, Secret),
    Jobs = [genome(Name, Ds, GenomeDir) || {Name, Ds} <- ?GENOMES],
    %% direct mode, checked here
    Direct = [direct(J, Base, Pub) || J <- Jobs],
    Refusals = local_refusals(Base, KeyFile, Pub),
    Pushed = case Mode of
                 dry -> [];
                 push ->
                     ok = application:set_env(genhub2, structure_viewer, Viewer#{mode => push}),
                     [pushed(J, Direct) || J <- Jobs]
             end,
    Remote = case Mode of
                 dry -> #{};
                 push -> remote_refusals(Base, KeyFile)
             end,
    Checks = checks(Mode, Jobs, Direct, Refusals, Pushed, Remote),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), mode => Mode, base => list_to_binary(Base), kid => ?KID,
          iss => ?ISS, public_key => gh_viewer:public_key(KeyFile),
          genomes => [maps:without([job], J) || J <- Jobs], direct => Direct, local_refusals => Refusals,
          pushed => Pushed, remote_refusals => Remote, checks => Checks,
          seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(gh_json:term(R))),
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    [io:format("~nopen before ~s: ~s~n  ~s ~s, ~s; expect: ~s~n",
               [stamp(E), U, N, Ds, L, lists:join(", ", Ms)])
     || #{name := N, dataset := Ds, lineage := L, mutations := Ms, open := U, expires := E} <- Pushed],
    io:format("written ~s~n", [Out]),
    halt(case [C || #{ok := false} = C <- Checks] of [] -> 0; _ -> 1 end).

%%% the four genomes

genome(Name, Ds, Dir) ->
    Fasta = case Name of
                <<"d614g">> -> d614g();
                _ -> {ok, B} = file:read_file(filename:join(Dir, binary_to_list(Name) ++ ".fa")), B
            end,
    {201, _, U} = http(post, "/api/uploads", {"application/octet-stream", Fasta}),
    #{<<"hash">> := Hash} = json:decode(U),
    {201, _, J} = http(post, "/api/jobs", {"application/json", json:encode(#{kind => genome, inputs => [Hash]})}),
    #{<<"id">> := Id} = json:decode(J),
    Job = poll(Id, 1200),
    #{name => Name, dataset => Ds, sha256 => Hash, id => Id, state => maps:get(<<"state">>, Job), job => Job}.

%% the reference with one substitution, A23403G (spike D614G)
d614g() ->
    Refs = maps:get(refs, gh_config:params()),
    Ref = gh_store:with_tmp(fun(Dir) ->
                                    F = filename:join(Dir, "r.fa"),
                                    gh_mutations:reference(Refs, <<"NC_045512.2">>, node(), F),
                                    {ok, B} = file:read_file(F),
                                    [_ | Ls] = binary:split(B, <<"\n">>, [global]),
                                    iolist_to_binary(Ls)
                            end),
    <<Pre:23402/binary, $A, Post/binary>> = Ref,
    <<">d614g\n", Pre/binary, $G, Post/binary, "\n">>.

%%% direct mode, checked here as the viewer checks it

direct(#{name := Name, id := Id}, Base, Pub) ->
    {S, _, B} = http(get, "/api/jobs/" ++ binary_to_list(Id) ++ "/structure-view?query=" ++ binary_to_list(Name), none),
    case S of
        200 ->
            #{<<"url">> := Url, <<"mutations">> := Ms} = json:decode(B),
            #{<<"k">> := K, <<"d">> := P, <<"s">> := Sig} = query(Url),
            Text = base64:decode(P, #{mode => urlsafe, padding => false}),
            V = gh_viewer:verify(K, P, Sig, #{keys => #{?KID => {'Ed25519', Pub}}, aud => list_to_binary(Base ++ "/ext/open")}),
            #{name => Name, status => S, kid => K, mutations => Ms,
              verified => case V of {ok, M} -> maps:with([<<"iss">>, <<"aud">>, <<"view">>, <<"params">>], M); E -> E end,
              names_in_payload => [N || N <- [Name, Id], binary:match(Text, N) =/= nomatch]};
        _ -> #{name => Name, status => S, error => B}
    end.

local_refusals(Base, KeyFile, Pub) ->
    {P, S} = signed(Base ++ "/ext/open", KeyFile, erlang:system_time(millisecond)),
    {PE, SE} = signed(Base ++ "/ext/open", KeyFile, erlang:system_time(millisecond) - 1200000),
    Opts = #{keys => #{?KID => {'Ed25519', Pub}}, aud => list_to_binary(Base ++ "/ext/open")},
    #{valid => element(1, gh_viewer:verify(?KID, P, S, Opts)),
      tampered => gh_viewer:verify(?KID, tamper(P), S, Opts),
      expired => gh_viewer:verify(?KID, PE, SE, Opts)}.

%%% push mode: the joint test

pushed(#{name := Name, id := Id, dataset := Ds}, Direct) ->
    {S, _, B} = http(get, "/api/jobs/" ++ binary_to_list(Id) ++ "/structure-view?query=" ++ binary_to_list(Name), none),
    case S of
        200 ->
            #{<<"url">> := Url, <<"mutations">> := Ms, <<"expires">> := E} = json:decode(B),
            #{name => Name, dataset => Ds, status => S, open => Url, expires => E, mutations => Ms,
              lineage => lineage(Name, Direct), handle => is_map_key(<<"h">>, query(Url))};
        _ -> #{name => Name, dataset => Ds, status => S, error => B}
    end.

%% a tampered payload and an expired one, each signed with the test key, pushed; the viewer must refuse both, with
%% the same body
remote_refusals(Base, KeyFile) ->
    {P, S} = signed(Base ++ "/ext/push", KeyFile, erlang:system_time(millisecond)),
    {PE, SE} = signed(Base ++ "/ext/push", KeyFile, erlang:system_time(millisecond) - 1200000),
    #{tampered => gh_viewer:push(Base, ?KID, tamper(P), S, #{}),
      expired => gh_viewer:push(Base, ?KID, PE, SE, #{})}.

%% a D614G payload as GenHub2 signs it, at time Now
signed(Aud, KeyFile, Now) ->
    {ok, B} = file:read_file(KeyFile),
    Priv = base64:decode(string:trim(B), #{mode => urlsafe, padding => false}),
    P = gh_viewer:payload(#{alg => 'Ed25519', kid => ?KID, iss => ?ISS, aud => list_to_binary(Aud), now => Now,
                            ref => <<"r-joint-test">>},
                          <<"sars-cov-2">>, [<<"S:D614G">>], #{pango => <<"B">>, clade => <<"19A">>}),
    {P, gh_viewer:sign(P, 'Ed25519', Priv)}.

tamper(P) ->
    T = base64:decode(P, #{mode => urlsafe, padding => false}),
    base64:encode(binary:replace(T, <<"S:D614G">>, <<"S:D614N">>), #{mode => urlsafe, padding => false}).

%%% the checks

checks(Mode, Jobs, Direct, Refusals, Pushed, Remote) ->
    Expected = maps:from_list(?GENOMES),
    [check(<<"the four genomes analysed (d614g, BA.2, RSV-A, RSV-B)">>,
           [S || #{state := S} <- Jobs] =:= [<<"done">> || _ <- Jobs], [{N, S} || #{name := N, state := S} <- Jobs])]
    ++ [check(<<"direct link for ", N/binary, ": signed with the test key, aud /ext/open, dataset ",
                (maps:get(N, Expected))/binary, ", the result's mutations exactly, no names">>,
              S =:= 200 andalso K =:= ?KID andalso is_map(V) andalso Names =:= []
              andalso maps:get(<<"dataset">>, maps:get(<<"params">>, V)) =:= maps:get(N, Expected)
              andalso maps:get(<<"mutations">>, maps:get(<<"params">>, V)) =:= Ms andalso Ms =/= [],
              {S, K, length(Ms), Names, case V of #{<<"params">> := Pa} -> maps:without([<<"mutations">>], Pa); _ -> V end})
        || #{name := N, status := S} = D <- Direct,
           {K, V, Ms, Names} <- [{maps:get(kid, D, none), maps:get(verified, D, none), maps:get(mutations, D, none),
                                  maps:get(names_in_payload, D, none)}]]
    ++ [check(<<"d614g carries exactly S:D614G">>,
              [Ms || #{name := <<"d614g">>, mutations := Ms} <- Direct] =:= [[<<"S:D614G">>]],
              [Ms || #{name := <<"d614g">>, mutations := Ms} <- Direct]),
        check(<<"ON544943 is BA.2">>,
              [maps:get(<<"lineage">>, maps:get(<<"params">>, V)) || #{name := <<"ON544943">>, verified := V} <- Direct, is_map(V)]
              =:= [<<"BA.2">>], lineage(<<"ON544943">>, Direct)),
        check(<<"here, as the viewer checks it: a valid link holds; a tampered one and an expired one are refused">>,
              Refusals =:= #{valid => ok, tampered => {error, bad_signature}, expired => {error, expired}}, Refusals)]
    ++ case Mode of
           dry -> [];
           push ->
               [check(<<"pushed to the viewer: ", N/binary, " (", Ds/binary, ") gets a handle that opens the view">>,
                      maps:get(status, X) =:= 200 andalso maps:get(handle, X, false), X)
                || #{name := N, dataset := Ds} = X <- Pushed]
               ++ [check(<<"pushed to the viewer: a tampered payload and an expired one refused, 400 {\"error\": \"refused\"}">>,
                         Remote =:= #{tampered => {error, {refused, 400, <<"{\"error\":\"refused\"}">>}},
                                      expired => {error, {refused, 400, <<"{\"error\":\"refused\"}">>}}}, Remote)]
       end.

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => iolist_to_binary(io_lib:format("~0P", [Value, 40]))}.

%%% helpers

%% the lineage (or for RSV the clade) the direct link carried for the genome
lineage(Name, Direct) ->
    case [maps:get(<<"params">>, V) || #{name := N, verified := V} <- Direct, N =:= Name, is_map(V)] of
        [#{<<"lineage">> := L} | _] when L =/= <<>> -> L;
        [#{<<"clade">> := C} | _] -> C;
        _ -> <<>>
    end.

query(Url) ->
    #{query := Qs} = uri_string:parse(Url),
    maps:from_list(uri_string:dissect_query(Qs)).

stamp(Ms) -> calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}]).

poll(Id, 0) -> error({timeout, Id});
poll(Id, N) ->
    {200, _, B} = http(get, "/api/jobs/" ++ binary_to_list(Id), none),
    case json:decode(B) of
        #{<<"state">> := S} = J when S =:= <<"done">>; S =:= <<"failed">> -> J;
        _ -> timer:sleep(500), poll(Id, N - 1)
    end.

%% with the current session's cookie (login/2), and the gateway's header
http(Method, Path, Body) ->
    Hdrs = [{"cookie", binary_to_list(persistent_term:get({?MODULE, cookie}, <<>>))}, {"x-genhub2", "1"}],
    Req = case Body of
              none -> {?URL ++ Path, Hdrs};
              {Type, B} -> {?URL ++ Path, Hdrs, Type, B}
          end,
    {ok, {{_, Status, _}, Headers, RespBody}} = httpc:request(Method, Req, [{timeout, 600000}], [{body_format, binary}]),
    {Status, proplists:get_value("content-type", Headers), RespBody}.

login(Name, Secret) ->
    Code = gh_totp:code(Secret, gh_totp:step(erlang:system_time(second))),
    {ok, {{_, S, _}, H, B}} =
        httpc:request(post, {?URL ++ "/api/login", [{"x-genhub2", "1"}], "application/json",
                             json:encode(#{user => Name, password => <<"a password for the check">>, code => Code})},
                      [], [{body_format, binary}]),
    200 = S,
    [C | _] = [hd(string:split(V, ";")) || {"set-cookie", V} <- H],
    persistent_term:put({?MODULE, cookie}, list_to_binary(C)),
    {200, maps:get(<<"role">>, json:decode(B))}.
