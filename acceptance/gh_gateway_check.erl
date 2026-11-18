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
%%      sequence;
%%   8. accounts and the audit log (FS 3.1, 3.4): a login needs the password and a one-time code; each role reaches
%%      only its endpoints; without a session, nothing but the page and the login; an admin creates and disables
%%      users; the audit log holds the logins, uploads, jobs (also MQTT's), alerts and refusals, and its chain is
%%      whole;
%%   9. aggregates (phase D, inside the site): the genome job's sample metadata counted by week, region and lineage;
%%      bad metadata refused; another site's aggregate imported by an admin (not by an analyst); the alerts of both
%%      merged name the other site's new lineage; a researcher reads the aggregates;
%%  10. sharing (phase C, inside the site): an admin approves a dataset of the two genome jobs with DUO consent; a
%%      researcher reads it through GA4GH DRS, anonymised (genomes renamed, the week instead of the date), checked by
%%      hash; files outside approved datasets are not served; a withdrawn dataset is gone;
%%  11. metrics, behind their scrape token;
%%  12. Beacon v2 over approved datasets: a genome with A23403G (D614G) shared; a researcher finds the mutation and the
%%      lineage, yes or no only; an analyst gets counts; a withdrawn dataset is not searched; bad queries refused;
%%  13. alert thresholds and notifications: only an admin changes them, checked and audited; each new lineage of the
%%      merged counts published once on genhub/alerts, as it appears;
%%  14. one's own account: sessions listed, the others ended; a password change (refused with a wrong code); an
%%      admin's reset ends the user's sessions and gives a new secret.
%% Parts 1-7 run as an analyst who logged in through the API.
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
    ok = application:set_env(genhub2, metrics_token, binary:encode_hex(crypto:strong_rand_bytes(24), lowercase)),
    {ok, _} = application:ensure_all_started([genhub2, gun]),
    T0 = erlang:monotonic_time(millisecond),
    %% the site's SARS-CoV-2 tree, from phase A's 1,000 public genomes, so genome jobs place their genomes in it
    #{refs := Refs0, nextclade := Next0} = gh_config:params(),
    #{fasta := Sars} = gh_acceptance:sars_cov_2(),
    UsherTree = gh_refdb:usher_sars_cov_2(Sars, Refs0, Next0),
    Users = maps:from_list([{R, begin
                                    N = <<"check-", (atom_to_binary(R))/binary>>,
                                    {ok, S} = gh_accounts:create(N, R, <<"a password for the check">>),
                                    {N, S}
                                end} || R <- gh_accounts:roles()]),
    {AName, ASecret} = maps:get(analyst, Users),
    {200, _} = login(AName, ASecret),
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
    %% the site's own first-seen alerts (the merged counts' alerts carry source merged: part 13)
    Alerts = [M || {<<"genhub/alerts">>, M} <- collected(Mqtt), not is_map_key(<<"source">>, M)],
    Refused = refused(maps:get(id, Job)),
    Accounts = accounts(Users),
    Aggregates = aggregates(Users),
    Sharing = sharing(Users, [maps:get(id, Job), maps:get(id, Viamqtt)], maps:get(hash, Upload), Tree),
    Metrics = metrics(),
    Beacon = beacon(Users, maps:get(id, Job), maps:get(id, Sharing)),
    Settings = settings(Users, Mqtt),
    Account = account(Users),
    Checks = checks(Page, Job, MqttMsgs, WsMsgs, Viamqtt, Refused)
        ++ more_checks(Job, Viamqtt, Exports, Tree, Summary, Alerts) ++ accounts_checks(Accounts)
        ++ aggregates_checks(Aggregates) ++ sharing_checks(Sharing, [maps:get(id, Job), maps:get(id, Viamqtt)])
        ++ metrics_checks(Metrics) ++ beacon_checks(Beacon, maps:get(id, Sharing)) ++ settings_checks(Settings) ++ account_checks(Account),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), emqx => <<"emqx/emqx:5.8.9">>,
          upload => Upload, job_seconds => maps:get(seconds, Job), job_state => maps:get(state, Job),
          mqtt_topics => count([T || {T, _} <- MqttMsgs]), websocket_topics => count([T || {T, _} <- WsMsgs]),
          job_from_mqtt => Viamqtt, exports => Exports, tree => maps:remove(svg, Tree), summary => Summary,
          alerts => Alerts, refused => Refused, accounts => Accounts, aggregates => Aggregates, sharing => Sharing,
          metrics => Metrics, beacon => Beacon, settings => Settings, account => Account,
          usher_tree => UsherTree,
          checks => Checks,
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
        S = gun:ws_upgrade(P, "/ws", [{<<"cookie">>, cookie()}]),
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

%% with the current session's cookie (login/2), and on changing requests the gateway's header
http(Method, Path, Body) ->
    {S, H, B} = http_h(Method, Path, Body, [{"x-genhub2", "1"}]),
    {S, proplists:get_value("content-type", H), B}.

http_h(Method, Path, Body, Extra) ->
    Hdrs = [{"cookie", binary_to_list(cookie())} | Extra],
    Req = case Body of
              none -> {?URL ++ Path, Hdrs};
              {Type, B} -> {?URL ++ Path, Hdrs, Type, B}
          end,
    {ok, {{_, Status, _}, Headers, RespBody}} = httpc:request(Method, Req, [{timeout, 600000}], [{body_format, binary}]),
    {Status, Headers, RespBody}.

cookie() -> persistent_term:get({?MODULE, cookie}, <<>>).

%% logs in through the API with the check's password and a one-time code (given, or the next one of a secret); on
%% success the session's cookie is the one later requests send. {Status, Role}
login(Name, Code) when is_binary(Code), byte_size(Code) =:= 6 ->
    persistent_term:put({?MODULE, cookie}, <<>>),
    {S, H, B} = http_h(post, "/api/login", {"application/json", json:encode(#{user => Name, password => <<"a password for the check">>,
                                                                            code => Code})}, [{"x-genhub2", "1"}]),
    case S of
        200 ->
            [C | _] = [hd(string:split(V, ";")) || {"set-cookie", V} <- H],
            persistent_term:put({?MODULE, cookie}, list_to_binary(C)),
            {200, maps:get(<<"role">>, json:decode(B))};
        _ -> {S, none}
    end;
login(Name, Secret) -> login(Name, code(Secret)).

%% the code for the next unused time step: each login uses a new step (a code is accepted once); the gateway accepts
%% at most the next step, so when that is used too, wait for the clock
code(Secret) ->
    Now = gh_totp:step(erlang:system_time(second)),
    Step = max(Now, persistent_term:get({?MODULE, step, Secret}, -1) + 1),
    case Step > Now + 1 of
        true -> timer:sleep(5000), code(Secret);
        false -> persistent_term:put({?MODULE, step, Secret}, Step), gh_totp:code(Secret, Step)
    end.

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
    {201, _, J} = http(post, "/api/jobs", {"application/json", json:encode(#{kind => genome, inputs => [Hash],
                                                                             metadata => #{region => <<"BG-22">>,
                                                                                           collection_date => <<"2026-11-10">>}})}),
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

%%% 8. accounts and the audit log

accounts(Users) ->
    {AdName, AdSecret} = maps:get(admin, Users),
    {ReName, ReSecret} = maps:get(researcher, Users),
    {AnName, AnSecret} = maps:get(analyst, Users),
    %% without a session: the page, the login; nothing else, the WebSocket neither
    persistent_term:put({?MODULE, cookie}, <<>>),
    {NoPage, _, _} = http(get, "/", none),
    NoSession = [element(1, http(get, P, none)) || P <- ["/api/jobs", "/api/summary", "/api/me", "/api/audit"]],
    NoWs = ws_status(),
    %% wrong code, missing header
    {WrongCode, _} = login(AnName, <<"000000">>),
    {200, <<"analyst">>} = login(AnName, AnSecret),
    {NoHeader, _, _} = http_h(post, "/api/jobs", {"application/json", <<"{}">>}, []),
    AnalystAdmin = [element(1, http(get, P, none)) || P <- ["/api/users", "/api/audit"]],
    %% a researcher: the counts only
    {200, <<"researcher">>} = login(ReName, ReSecret),
    Researcher = #{summary => element(1, http(get, "/api/summary", none)), jobs => element(1, http(get, "/api/jobs", none)),
                   uploads => element(1, http(post, "/api/uploads", {"application/octet-stream", <<">x\nACGT\n">>})),
                   ws => ws_status()},
    {ResLogout, _, _} = http(post, "/api/logout", {"application/json", <<"{}">>}),
    {AfterLogout, _, _} = http(get, "/api/summary", none),
    %% an admin: creates a user, who logs in with the secret shown once; disables them, which ends their session
    {200, <<"admin">>} = login(AdName, AdSecret),
    {Created, _, CB} = http(post, "/api/users", {"application/json", json:encode(#{user => <<"check-new">>, role => analyst,
                                                                                  password => <<"a password for the check">>})}),
    NewSecret = gh_totp:unbase32(maps:get(<<"totp_secret">>, json:decode(CB))),
    AdminCookie = cookie(),
    {NewLogin, _} = login(<<"check-new">>, NewSecret),
    NewCookie = cookie(),
    {NewMe, _, _} = http(get, "/api/me", none),
    persistent_term:put({?MODULE, cookie}, AdminCookie),
    {Disabled, _, _} = http(post, "/api/users/check-new/disable", {"application/json", <<"{}">>}),
    persistent_term:put({?MODULE, cookie}, NewCookie),
    {DisabledMe, _, _} = http(get, "/api/me", none),
    persistent_term:put({?MODULE, cookie}, AdminCookie),
    {200, _, Ver} = http(get, "/api/audit/verify", none),
    {200, _, Log} = http(get, "/api/audit?from=1&limit=10000", none),
    Recs = json:decode(Log),
    Seen = lists:usort([{maps:get(<<"actor">>, R), maps:get(<<"action">>, R), maps:get(<<"outcome">>, R)} || R <- Recs]),
    #{page_without_session => NoPage, without_session => NoSession, ws_without_session => NoWs, wrong_code => WrongCode,
      missing_header => NoHeader, analyst_on_admin => AnalystAdmin, researcher => Researcher, logout => ResLogout,
      after_logout => AfterLogout, user_created => Created, new_user_login => NewLogin, new_user_me => NewMe,
      disabled => Disabled, disabled_me => DisabledMe, audit_verify => json:decode(Ver), audit_records => length(Recs),
      audit_seen => [iolist_to_binary([A, " ", Ac, " ", O]) || {A, Ac, O} <- Seen]}.

%% the WebSocket upgrade's HTTP status with the current cookie (101 when allowed)
ws_status() ->
    {ok, P} = gun:open("127.0.0.1", 28090),
    {ok, _} = gun:await_up(P, 5000),
    S = gun:ws_upgrade(P, "/ws", [{<<"cookie">>, cookie()}]),
    Status = receive
                 {gun_upgrade, P, S, _, _} -> 101;
                 {gun_response, P, S, _, Code, _} -> Code
             after 5000 -> timeout
             end,
    gun:close(P),
    Status.

accounts_checks(A) ->
    Seen = maps:get(audit_seen, A),
    Has = fun(X) -> lists:member(X, Seen) end,
    [check(<<"accounts: without a session the page is served, the API and the WebSocket refuse (401)">>,
           {maps:get(page_without_session, A), maps:get(without_session, A), maps:get(ws_without_session, A)}
           =:= {200, [401, 401, 401, 401], 401}, A),
     check(<<"accounts: a wrong code 401; a changing request without the header 403">>,
           {maps:get(wrong_code, A), maps:get(missing_header, A)} =:= {401, 403}, A),
     check(<<"accounts: an analyst cannot see users or the audit log (403)">>, maps:get(analyst_on_admin, A) =:= [403, 403], A),
     check(<<"accounts: a researcher sees the counts only">>,
           maps:get(researcher, A) =:= #{summary => 200, jobs => 403, uploads => 403, ws => 403}, maps:get(researcher, A)),
     check(<<"accounts: logout ends the session">>, {maps:get(logout, A), maps:get(after_logout, A)} =:= {200, 401}, A),
     check(<<"accounts: an admin creates a user, who logs in with the secret shown once; disabling ends their session">>,
           {maps:get(user_created, A), maps:get(new_user_login, A), maps:get(new_user_me, A), maps:get(disabled, A),
            maps:get(disabled_me, A)} =:= {201, 200, 200, 200, 401}, A),
     check(<<"audit: logins, uploads, jobs (also MQTT's), alerts, refusals and administration recorded">>,
           lists:all(Has, [<<"check-analyst login ok">>, <<"check-analyst login denied">>, <<"check-analyst upload ok">>,
                           <<"check-analyst job_submit ok">>, <<"mqtt job_submit ok">>, <<"system alert ok">>,
                           <<"check-analyst export ok">>, <<"check-analyst file_download ok">>,
                           <<"check-researcher denied_request denied">>, <<"check-admin user_create ok">>,
                           <<"check-admin user_disable ok">>, <<"check-researcher logout ok">>]), Seen),
     check(<<"audit: the chain is whole">>, maps:get(<<"whole">>, maps:get(audit_verify, A)) =:= true, maps:get(audit_verify, A))].

%%% 9. aggregates

aggregates(Users) ->
    {AnName, AnSecret} = maps:get(analyst, Users),
    {AdName, AdSecret} = maps:get(admin, Users),
    {ReName, ReSecret} = maps:get(researcher, Users),
    {200, <<"analyst">>} = login(AnName, AnSecret),
    {200, _, A} = http(get, "/api/aggregates", none),
    Own = json:decode(A),
    %% a file in the store, so the refusals below are the metadata's
    {201, _, U} = http(post, "/api/uploads", {"application/octet-stream", <<">x\nACGTACGT\n">>}),
    #{<<"hash">> := H} = json:decode(U),
    Refusal = fun(Meta) ->
                      {S, _, B} = http(post, "/api/jobs", {"application/json", json:encode(#{kind => genome, inputs => [H],
                                                                                            metadata => Meta})}),
                      {S, maps:get(<<"error">>, json:decode(B))}
              end,
    BadRegion = Refusal(#{region => <<"Sofia">>}),
    BadDate = Refusal(#{collection_date => <<"2099-01-01">>}),
    %% another site's counts: an earlier week with lineage B, and the week of the job with a lineage new to both
    Other = #{format => <<"genhub2-aggregates/1">>, site => <<"check-other-site">>, generated => 1,
              lineages => [#{week => <<"2026-W45">>, region => <<"BG-02">>, lineage => <<"B">>, n => 3},
                           #{week => <<"2026-W46">>, region => <<"BG-02">>, lineage => <<"Z.9">>, n => 2}],
              mutations => [], totals => [#{week => <<"2026-W45">>, region => <<"BG-02">>, n => 3},
                                          #{week => <<"2026-W46">>, region => <<"BG-02">>, n => 2}]},
    {AnalystImport, _, _} = http(post, "/api/aggregates", {"application/json", json:encode(Other)}),
    {200, <<"admin">>} = login(AdName, AdSecret),
    {Imported, _, _} = http(post, "/api/aggregates", {"application/json", json:encode(Other)}),
    {NotAgg, _, _} = http(post, "/api/aggregates", {"application/json", <<"{\"format\": \"other\"}">>}),
    {200, _, Al} = http(get, "/api/aggregates/alerts", none),
    {200, <<"researcher">>} = login(ReName, ReSecret),
    {ResAgg, _, _} = http(get, "/api/aggregates", none),
    {ResAlerts, _, _} = http(get, "/api/aggregates/alerts", none),
    #{own => maps:with([<<"site">>, <<"lineages">>, <<"totals">>, <<"not_counted">>], Own), bad_region => BadRegion,
      bad_date => BadDate, analyst_import => AnalystImport, admin_import => Imported, not_an_aggregate => NotAgg,
      alerts => json:decode(Al), researcher => #{aggregates => ResAgg, alerts => ResAlerts}}.

aggregates_checks(A) ->
    Own = maps:get(own, A),
    Al = maps:get(alerts, A),
    [check(<<"aggregates: the genome job counted by week, region and lineage (2026-W46, BG-22, B)">>,
           lists:member(#{<<"week">> => <<"2026-W46">>, <<"region">> => <<"BG-22">>, <<"lineage">> => <<"B">>, <<"n">> => 1},
                        maps:get(<<"lineages">>, Own)), Own),
     check(<<"aggregates: bad region 400, future collection date 400, each saying why">>,
           case {maps:get(bad_region, A), maps:get(bad_date, A)} of
               {{400, <<"region:", _/binary>>}, {400, <<"collection_date:", _/binary>>}} -> true;
               _ -> false
           end, {maps:get(bad_region, A), maps:get(bad_date, A)}),
     check(<<"aggregates: an admin imports another site's aggregate (201), an analyst cannot (403), a malformed one 400">>,
           {maps:get(admin_import, A), maps:get(analyst_import, A), maps:get(not_an_aggregate, A)} =:= {201, 403, 400}, A),
     check(<<"aggregates: the merged alerts name the other site's new lineage, Z.9, and both sites">>,
           [L || #{<<"type">> := <<"new_lineage">>, <<"lineage">> := L} <- maps:get(<<"alerts">>, Al)] =:= [<<"Z.9">>]
           andalso lists:member(<<"check-other-site">>, maps:get(<<"sites">>, Al)), Al),
     check(<<"aggregates: a researcher reads the aggregates and the alerts">>,
           maps:get(researcher, A) =:= #{aggregates => 200, alerts => 200}, maps:get(researcher, A))].

%%% 14. one's own account

account(Users) ->
    {AdName, AdSecret} = maps:get(admin, Users),
    Post = fun(Path, Body) -> element(1, http(post, Path, {"application/json", json:encode(Body)})) end,
    {200, <<"admin">>} = login(AdName, AdSecret),
    {201, _, CB} = http(post, "/api/users", {"application/json", json:encode(#{user => <<"check-profile">>, role => analyst,
                                                                             password => <<"a password for the check">>})}),
    Secret = gh_totp:unbase32(maps:get(<<"totp_secret">>, json:decode(CB))),
    AdminCookie = cookie(),
    {200, <<"analyst">>} = login(<<"check-profile">>, Secret),
    First = cookie(),
    {200, <<"analyst">>} = login(<<"check-profile">>, Secret),
    Second = cookie(),
    {200, _, SB} = http(get, "/api/me/sessions", none),
    Sessions = [maps:get(<<"current">>, X) || X <- json:decode(SB)],
    {EndOthers, _, _} = http(post, "/api/me/sessions/end-others", {"application/json", <<"{}">>}),
    persistent_term:put({?MODULE, cookie}, First),
    {FirstAfter, _, _} = http(get, "/api/me", none),
    persistent_term:put({?MODULE, cookie}, Second),
    WrongCode = Post("/api/me/password", #{password => <<"a password for the check">>, code => <<"000000">>,
                                           new_password => <<"another password for the check">>}),
    Changed = Post("/api/me/password", #{password => <<"a password for the check">>, code => code(Secret),
                                         new_password => <<"another password for the check">>}),
    {StillIn, _, _} = http(get, "/api/me", none),
    persistent_term:put({?MODULE, cookie}, AdminCookie),
    {Reset, _, RB} = http(post, "/api/users/check-profile/reset", {"application/json",
                                                                   json:encode(#{password => <<"a reset password for the check">>})}),
    NewSecret = gh_totp:unbase32(maps:get(<<"totp_secret">>, json:decode(RB))),
    {200, _, AuditB} = http(get, "/api/audit?from=1&limit=10000", none),
    Audited = lists:usort([maps:get(<<"action">>, X) || #{<<"action">> := A} = X <- json:decode(AuditB),
                                                     lists:member(A, [<<"password_change">>, <<"sessions_end_others">>, <<"user_reset">>])]),
    persistent_term:put({?MODULE, cookie}, Second),
    {AfterReset, _, _} = http(get, "/api/me", none),
    {S, _, _} = http_h(post, "/api/login", {"application/json", json:encode(#{user => <<"check-profile">>,
                                                                             password => <<"a reset password for the check">>,
                                                                             code => code(NewSecret)})}, [{"x-genhub2", "1"}]),
    #{sessions => lists:sort(Sessions), end_others => EndOthers, first_after => FirstAfter, wrong_code => WrongCode,
      changed => Changed, still_in => StillIn, reset => Reset, after_reset => AfterReset, new_login => S, audited => Audited}.

account_checks(A) ->
    [check(<<"account: two sessions listed, this one marked; the other ended (401 after)">>,
           {maps:get(sessions, A), maps:get(end_others, A), maps:get(first_after, A)} =:= {[false, true], 200, 401}, A),
     check(<<"account: a password change refused with a wrong code (401), done with the right one; this session stays">>,
           {maps:get(wrong_code, A), maps:get(changed, A), maps:get(still_in, A)} =:= {401, 200, 200}, A),
     check(<<"account: an admin's reset ends the user's session; the user logs in with the new password and secret; audited">>,
           {maps:get(reset, A), maps:get(after_reset, A), maps:get(new_login, A)} =:= {200, 401, 200}
           andalso maps:get(audited, A) =:= [<<"password_change">>, <<"sessions_end_others">>, <<"user_reset">>], A)].

%%% 13. alert thresholds and notifications

settings(Users, Mqtt) ->
    {AnName, AnSecret} = maps:get(analyst, Users),
    {AdName, AdSecret} = maps:get(admin, Users),
    {ReName, ReSecret} = maps:get(researcher, Users),
    Put = fun(Body) -> element(1, http(put, "/api/settings", {"application/json", json:encode(Body)})) end,
    {200, <<"analyst">>} = login(AnName, AnSecret),
    AnalystPut = Put(#{alert_thresholds => #{min_n => 3}}),
    {200, <<"admin">>} = login(AdName, AdSecret),
    Bad = [Put(B) || B <- [#{alert_thresholds => #{min_share => 2}}, #{alert_thresholds => #{colour => 1}},
                          #{notify => #{mqtt => <<"yes">>}}, #{volume => 11}]],
    {AdminPut, _, AB} = http(put, "/api/settings", {"application/json", json:encode(#{alert_thresholds => #{min_n => 3, ratio => 1.5}})}),
    {200, _, AuditB} = http(get, "/api/audit?from=1&limit=10000", none),
    Changes = [maps:get(<<"object">>, X) || #{<<"action">> := <<"settings_change">>} = X <- json:decode(AuditB)],
    {200, <<"researcher">>} = login(ReName, ReSecret),
    {ResGet, _, RB} = http(get, "/api/settings", none),
    timer:sleep(1000),
    Merged = [M || {<<"genhub/alerts">>, #{<<"source">> := <<"merged">>} = M} <- collected(Mqtt)],
    #{analyst_put => AnalystPut, bad => Bad, admin_put => AdminPut, saved => maps:get(<<"alert_thresholds">>, json:decode(AB)),
      audited => Changes, researcher_get => ResGet, researcher_sees => maps:get(<<"alert_thresholds">>, json:decode(RB)),
      merged_published => [maps:with([<<"type">>, <<"lineage">>, <<"week">>], M) || M <- Merged]}.

settings_checks(S) ->
    [check(<<"settings: an analyst cannot change them (403); bad values or names 400; an admin's change applied and audited">>,
           maps:get(analyst_put, S) =:= 403 andalso maps:get(bad, S) =:= [400, 400, 400, 400]
           andalso maps:get(admin_put, S) =:= 200
           andalso maps:with([<<"min_n">>, <<"ratio">>], maps:get(saved, S)) =:= #{<<"min_n">> => 3, <<"ratio">> => 1.5}
           andalso maps:get(audited, S) =:= [<<"alert_thresholds">>]
           andalso maps:get(researcher_get, S) =:= 200 andalso maps:get(researcher_sees, S) =:= maps:get(saved, S), S),
     %% B: new when the genome job with metadata is first counted (part 2); Z.9: new with the other site's import
     %% (part 9), when B is also seen in an earlier week there, and so is not announced again
     check(<<"notifications: each new lineage of the merged counts published once on genhub/alerts, as it appears (B, then Z.9)">>,
           maps:get(merged_published, S) =:= [#{<<"type">> => <<"new_lineage">>, <<"lineage">> => L, <<"week">> => <<"2026-W46">>}
                                              || L <- [<<"B">>, <<"Z.9">>]],
           maps:get(merged_published, S))].

%%% 12. Beacon

beacon(Users, Job1, Withdrawn) ->
    {AnName, AnSecret} = maps:get(analyst, Users),
    {AdName, AdSecret} = maps:get(admin, Users),
    {ReName, ReSecret} = maps:get(researcher, Users),
    %% the reference with one substitution, A23403G (spike D614G), analysed as a new genome job
    {200, <<"analyst">>} = login(AnName, AnSecret),
    Refs = maps:get(refs, gh_config:params()),
    Ref = gh_store:with_tmp(fun(Dir) ->
                                    F = filename:join(Dir, "r.fa"),
                                    gh_mutations:reference(Refs, <<"NC_045512.2">>, node(), F),
                                    {ok, B} = file:read_file(F),
                                    [_ | Ls] = binary:split(B, <<"\n">>, [global]),
                                    iolist_to_binary(Ls)
                            end),
    <<Pre:23402/binary, $A, Post/binary>> = Ref,
    Mutant = <<">mutant\n", Pre/binary, $G, Post/binary, "\n">>,
    {201, _, U} = http(post, "/api/uploads", {"application/octet-stream", Mutant}),
    #{<<"hash">> := H} = json:decode(U),
    {201, _, J} = http(post, "/api/jobs", {"application/json", json:encode(#{kind => genome, inputs => [H]})}),
    #{<<"id">> := MJob} = json:decode(J),
    #{<<"state">> := <<"done">>} = poll(MJob, 600),
    {200, <<"admin">>} = login(AdName, AdSecret),
    {201, _, D} = http(post, "/api/datasets", {"application/json", json:encode(#{title => <<"for the Beacon">>, consent => [<<"DUO:0000042">>],
                                                                                jobs => [Job1, MJob]})}),
    Ds = maps:get(<<"id">>, json:decode(D)),
    Q = fun(Qs) ->
                {S, _, B} = http(get, "/beacon/g_variants?" ++ Qs, none),
                {S, case S of 200 -> json:decode(B); _ -> B end}
        end,
    Summary = fun({200, R}) -> maps:get(<<"responseSummary">>, R);
                 ({S, _}) -> S
              end,
    Sets = fun({200, R}) -> [maps:with([<<"id">>, <<"exists">>, <<"resultsCount">>], X)
                             || X <- maps:get(<<"resultSets">>, maps:get(<<"response">>, R))] end,
    D614G = "referenceName=NC_045512.2&start=23402&referenceBases=A&alternateBases=G",
    {200, <<"researcher">>} = login(ReName, ReSecret),
    R1 = Q(D614G),
    R2 = Q("referenceName=NC_045512.2&start=23402&referenceBases=A&alternateBases=T"),
    R3 = Q("filters=lineage:B"),
    R4 = Q(D614G ++ "&requestedGranularity=count"),
    Bad = [element(1, Q(X)) || X <- ["", "referenceName=NC_045512.2&start=x&referenceBases=A&alternateBases=G",
                                     "referenceName=NC_045512.2&start=1&referenceBases=AT&alternateBases=G", "filters=clade:20A"]],
    {200, _, DsB} = http(get, "/beacon/datasets", none),
    {200, _, TB} = http(get, "/beacon/filtering_terms", none),
    {200, <<"analyst">>} = login(AnName, AnSecret),
    R5 = Q(D614G ++ "&requestedGranularity=count"),
    {200, <<"admin">>} = login(AdName, AdSecret),
    {200, _, AuditB} = http(get, "/api/audit?from=1&limit=10000", none),
    #{dataset => Ds, withdrawn => Withdrawn, mutant_job => MJob,
      d614g => {Summary(R1), Sets(R1)}, absent => Summary(R2), lineage_b => {Summary(R3), Sets(R3)},
      researcher_count => {Summary(R4), Sets(R4)}, analyst_count => {Summary(R5), Sets(R5)}, bad => Bad,
      datasets => [maps:get(<<"id">>, X) || X <- maps:get(<<"collections">>, maps:get(<<"response">>, json:decode(DsB)))],
      terms => [maps:get(<<"id">>, X) || X <- maps:get(<<"filteringTerms">>, maps:get(<<"response">>, json:decode(TB)))],
      audited => length([x || #{<<"action">> := <<"beacon_query">>} <- json:decode(AuditB)])}.

beacon_checks(B, Withdrawn) ->
    Ds = maps:get(dataset, B),
    [check(<<"beacon: a researcher finds A23403G in the approved dataset, and not a substitution nobody has">>,
           maps:get(d614g, B) =:= {#{<<"exists">> => true}, [#{<<"id">> => Ds, <<"exists">> => true}]}
           andalso maps:get(absent, B) =:= #{<<"exists">> => false}, maps:with([d614g, absent], B)),
     check(<<"beacon: lineage filter; the withdrawn dataset is not searched">>,
           element(1, maps:get(lineage_b, B)) =:= #{<<"exists">> => true}
           andalso [maps:get(<<"id">>, X) || X <- element(2, maps:get(lineage_b, B))] =:= [Ds]
           andalso not lists:member(Withdrawn, maps:get(datasets, B)), maps:get(lineage_b, B)),
     check(<<"beacon: a researcher who asks for counts gets yes or no only; an analyst gets the count (1)">>,
           maps:get(researcher_count, B) =:= {#{<<"exists">> => true}, [#{<<"id">> => Ds, <<"exists">> => true}]}
           andalso maps:get(analyst_count, B) =:= {#{<<"exists">> => true, <<"numTotalResults">> => 1},
                                                   [#{<<"id">> => Ds, <<"exists">> => true, <<"resultsCount">> => 1}]},
           maps:with([researcher_count, analyst_count], B)),
     check(<<"beacon: no query, a bad start, a bad base, an unknown filter: 400">>, maps:get(bad, B) =:= [400, 400, 400, 400],
           maps:get(bad, B)),
     check(<<"beacon: the approved datasets and the lineages as filtering terms listed; every query audited">>,
           maps:get(datasets, B) =:= [Ds] andalso lists:member(<<"lineage:B">>, maps:get(terms, B))
           andalso maps:get(audited, B) >= 5, maps:with([datasets, terms, audited], B))].

%%% 11. metrics: only with the scrape token; counts, no names

metrics() ->
    {ok, Token} = application:get_env(genhub2, metrics_token),
    Get = fun(Hdrs) ->
                  {ok, {{_, S, _}, _, B}} = httpc:request(get, {?URL ++ "/metrics", Hdrs}, [], [{body_format, binary}]),
                  {S, B}
          end,
    {NoToken, _} = Get([]),
    {Wrong, _} = Get([{"authorization", "Bearer " ++ lists:duplicate(48, $0)}]),
    {Ok, Body} = Get([{"authorization", "Bearer " ++ binary_to_list(Token)}]),
    Lines = binary:split(Body, <<"\n">>, [global, trim_all]),
    #{no_token => NoToken, wrong_token => Wrong, status => Ok,
      jobs_done => [L || L <- Lines, binary:match(L, <<"genhub2_jobs{kind=\"genome\",state=\"done\"}">>) =/= nomatch],
      names => [N || N <- [<<"check-">>, <<"job-">>, <<"NC_045512.2">>], binary:match(Body, N) =/= nomatch],
      families => lists:usort([hd(binary:split(L, [<<"{">>, <<" ">>])) || L <- Lines, binary:first(L) =/= $#])}.

metrics_checks(M) ->
    [check(<<"metrics: refused without the token or with a wrong one (401); served with it, counts only (no names)">>,
           {maps:get(no_token, M), maps:get(wrong_token, M), maps:get(status, M)} =:= {401, 401, 200}
           andalso maps:get(jobs_done, M) =/= [] andalso maps:get(names, M) =:= [], M)].

%%% 10. sharing

sharing(Users, Jobs, UploadHash, Tree) ->
    {AnName, AnSecret} = maps:get(analyst, Users),
    {AdName, AdSecret} = maps:get(admin, Users),
    {ReName, ReSecret} = maps:get(researcher, Users),
    Make = fun(Body) ->
                   {S, _, B} = http(post, "/api/datasets", {"application/json", json:encode(Body)}),
                   {S, json:decode(B)}
           end,
    Good = #{title => <<"SARS-CoV-2 genomes of the check">>, description => <<"two genomes">>,
             consent => [<<"DUO:0000042">>], jobs => Jobs},
    {200, <<"analyst">>} = login(AnName, AnSecret),
    {AnalystMake, _} = Make(Good),
    {200, <<"admin">>} = login(AdName, AdSecret),
    {BadDuo, _} = Make(Good#{consent => [<<"DUO:9999999">>]}),
    {TreeJob, _} = Make(Good#{jobs => [maps:get(id, Tree)]}),
    {Made, D} = Make(Good),
    Id = maps:get(<<"id">>, D),
    {200, <<"researcher">>} = login(ReName, ReSecret),
    {200, _, L} = http(get, "/api/datasets", none),
    Listed = [maps:get(<<"id">>, X) || X <- maps:get(<<"datasets">>, json:decode(L))],
    {200, _, Bu} = http(get, "/ga4gh/drs/v1/objects/" ++ binary_to_list(Id), none),
    Bundle = json:decode(Bu),
    Files = maps:from_list([{N, H} || #{<<"name">> := N, <<"id">> := H} <- maps:get(<<"contents">>, Bundle, [])]),
    Get = fun(H) ->
                  {200, _, O} = http(get, "/ga4gh/drs/v1/objects/" ++ binary_to_list(H), none),
                  Obj = json:decode(O),
                  [#{<<"access_url">> := #{<<"url">> := Url}}] = maps:get(<<"access_methods">>, Obj),
                  {DS, _, Data} = http(get, uri_string:normalize(maps:get(path, uri_string:parse(Url))), none),
                  #{object => Obj, status => DS, data => Data,
                    hash_ok => binary:encode_hex(crypto:hash(sha256, Data), lowercase) =:= H
                               andalso [maps:get(<<"checksum">>, C) || C <- maps:get(<<"checksums">>, Obj)] =:= [H]}
          end,
    G = Get(maps:get(<<"genomes.fasta">>, Files)),
    R = Get(maps:get(<<"results.json">>, Files)),
    Fasta = maps:get(data, G),
    Results = json:decode(maps:get(data, R)),
    {Outside, _, _} = http(get, "/ga4gh/drs/v1/objects/" ++ binary_to_list(UploadHash), none),
    {OutsideData, _, _} = http(get, "/ga4gh/drs/v1/objects/" ++ binary_to_list(UploadHash) ++ "/data", none),
    {200, <<"admin">>} = login(AdName, AdSecret),
    {Withdrawn, _, _} = http(post, "/api/datasets/" ++ binary_to_list(Id) ++ "/withdraw", {"application/json", <<"{}">>}),
    {200, _, AuditB} = http(get, "/api/audit?from=1&limit=10000", none),
    Audit = lists:usort([maps:get(<<"action">>, X) || X <- json:decode(AuditB)]),
    {200, <<"researcher">>} = login(ReName, ReSecret),
    {AfterBundle, _, _} = http(get, "/ga4gh/drs/v1/objects/" ++ binary_to_list(Id), none),
    {AfterFile, _, _} = http(get, "/ga4gh/drs/v1/objects/" ++ binary_to_list(maps:get(<<"genomes.fasta">>, Files)) ++ "/data", none),
    {AfterDataset, _, _} = http(get, "/api/datasets/" ++ binary_to_list(Id), none),
    #{analyst_make => AnalystMake, bad_duo => BadDuo, tree_job => TreeJob, made => Made, id => Id,
      metadata => maps:get(<<"metadata">>, D),
      listed => lists:member(Id, Listed), bundle_files => lists:sort(maps:keys(Files)),
      bundle_checksum => maps:get(<<"checksums">>, Bundle, []),
      genomes => #{status => maps:get(status, G), hash_ok => maps:get(hash_ok, G),
                   headers => [H || <<">", H/binary>> <- binary:split(Fasta, <<"\n">>, [global])],
                   names_jobs => [J || J <- [<<"job-">>, <<"NC_045512.2">>], binary:match(Fasta, J) =/= nomatch]},
      results => #{status => maps:get(status, R), hash_ok => maps:get(hash_ok, R), rows => Results,
                   has_date => binary:match(maps:get(data, R), <<"2026-11-10">>) =/= nomatch},
      outside => {Outside, OutsideData}, withdrawn => Withdrawn, after_withdraw => {AfterBundle, AfterFile, AfterDataset},
      audit_actions => [A || A <- Audit, lists:member(A, [<<"dataset_create">>, <<"dataset_withdraw">>, <<"drs_object">>,
                                                          <<"drs_download">>])]}.

sharing_checks(S, Jobs) ->
    Id = maps:get(id, S),
    [check(<<"sharing: an admin approves a dataset (201); an analyst cannot (403); an unknown DUO code or a tree job 400">>,
           {maps:get(made, S), maps:get(analyst_make, S), maps:get(bad_duo, S), maps:get(tree_job, S)} =:= {201, 403, 400, 400},
           maps:with([made, analyst_make, bad_duo, tree_job], S)),
     check(<<"sharing: a researcher lists it and reads it through DRS as a bundle of genomes.fasta and results.json">>,
           maps:get(listed, S) andalso maps:get(bundle_files, S) =:= [<<"genomes.fasta">>, <<"results.json">>],
           maps:with([listed, bundle_files, bundle_checksum], S)),
     check(<<"sharing: both files downloaded through DRS, each checked against its SHA-256 id and checksum">>,
           maps:get(hash_ok, maps:get(genomes, S)) andalso maps:get(hash_ok, maps:get(results, S)),
           {maps:get(genomes, S), maps:without([rows], maps:get(results, S))}),
     check(<<"sharing: anonymised: genomes renamed after the dataset, no job or sample names, the week and not the date">>,
           maps:get(headers, maps:get(genomes, S)) =:= [<<Id/binary, "-1">>, <<Id/binary, "-2">>]
           andalso maps:get(names_jobs, maps:get(genomes, S)) =:= []
           andalso not maps:get(has_date, maps:get(results, S))
           andalso lists:all(fun(#{<<"collection_week">> := W, <<"region">> := R}) -> {W, R} =:= {<<"2026-W46">>, <<"BG-22">>}
                                                                                     orelse {W, R} =:= {null, null} end,
                             maps:get(rows, maps:get(results, S))),
           {maps:get(genomes, S), maps:get(rows, maps:get(results, S)), length(Jobs)}),
     check(<<"sharing: the dataset says where and when its genomes come from: the site, 2 genomes, BG (BG-22), 2026-W46">>,
           maps:with([<<"genomes">>, <<"countries">>, <<"regions">>, <<"collection_weeks">>], maps:get(metadata, S))
           =:= #{<<"genomes">> => 2, <<"countries">> => [<<"BG">>], <<"regions">> => [<<"BG-22">>],
                 <<"collection_weeks">> => [<<"2026-W46">>, <<"2026-W46">>]}
           andalso is_binary(maps:get(<<"source">>, maps:get(metadata, S))), maps:get(metadata, S)),
     check(<<"sharing: a file outside approved datasets is not served through DRS (404)">>,
           maps:get(outside, S) =:= {404, 404}, maps:get(outside, S)),
     check(<<"sharing: withdrawn, the dataset and its files are gone for a researcher (404)">>,
           {maps:get(withdrawn, S), maps:get(after_withdraw, S)} =:= {200, {404, 404, 404}}, maps:get(after_withdraw, S)),
     check(<<"sharing: the dataset's creation and withdrawal, and every DRS access, in the audit log">>,
           maps:get(audit_actions, S) =:= [<<"dataset_create">>, <<"dataset_withdraw">>, <<"drs_download">>, <<"drs_object">>],
           maps:get(audit_actions, S))].

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
     check(<<"genome job: placed in the site's SARS-CoV-2 tree, with the lineage where it lands">>,
           case maps:get(<<"place">>, maps:get(<<"steps">>, J), none) of
               #{<<"results">> := [[#{<<"clade">> := C, <<"parsimony">> := P}]]} -> is_integer(P) andalso C =/= <<>>;
               _ -> false
           end, maps:get(<<"place">>, maps:get(<<"steps">>, J), none)),
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
