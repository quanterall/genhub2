%% The structure viewer's hand-off (gh_viewer), TechUPGRADE's external integration protocol v1: the payload's exact
%% fields, Ed25519 and HS256, and every refusal of the protocol's contract tests (EXT-56) that a payload can carry.
-module(gh_viewer_tests).
-include_lib("eunit/include/eunit.hrl").

-define(AUD, <<"https://twin.example/ext/open">>).

viewer_test_() ->
    {setup,
     fun() ->
             Dir = filename:join("/tmp", "gh-viewer-" ++ os:getpid()),
             ok = filelib:ensure_path(Dir),
             {Pub, Priv} = gh_viewer:new_key(),
             KeyFile = filename:join(Dir, "ed25519.key"),
             ok = file:write_file(KeyFile, base64:encode(Priv, #{mode => urlsafe, padding => false})),
             SecretFile = filename:join(Dir, "hs256.secret"),
             ok = file:write_file(SecretFile, <<"0123456789abcdef0123456789abcdef-test">>),
             _ = application:load(genhub2),
             ok = application:set_env(genhub2, structure_viewer,
                                      #{base => "https://twin.example", mode => direct, iss => <<"lab17.example">>,
                                        active => <<"lab17-2026a">>,
                                        keys => #{<<"lab17-2026a">> => #{alg => 'Ed25519', key_file => KeyFile},
                                                  <<"lab17-test">> => #{alg => 'HS256', key_file => SecretFile}}}),
             #{dir => Dir, pub => Pub, key_file => KeyFile}
     end,
     fun(#{dir := Dir}) -> application:unset_env(genhub2, structure_viewer), file:del_dir_r(Dir) end,
     fun(S) -> [fun() -> link_and_verify(S) end, fun() -> refusals(S) end, fun() -> datasets() end,
                fun() -> hs256() end, fun() -> no_plain_http() end] end}.

job(Species, Dataset) ->
    #{id => <<"job-secret-id">>,
      steps => #{classify => #{results => [[#{<<"query">> => <<"patient-17-sample">>,
                                              <<"call">> => #{<<"species">> => Species, <<"confidence">> => <<"high">>}}]]},
                 lineage => #{results => [[#{query => <<"patient-17-sample">>, dataset => Dataset, pango => <<"BA.2">>,
                                             clade => <<"21L">>, aa_substitutions => [<<"S:N501Y">>, <<"S:D614G">>],
                                             aa_deletions => [<<"S:H69-">>]}]]}}}.

parts(Url) ->
    #{query := Qs} = uri_string:parse(Url),
    #{<<"k">> := _, <<"d">> := P, <<"s">> := S} = maps:from_list(uri_string:dissect_query(Qs)),
    {P, S}.

keys(#{pub := Pub}) -> #{keys => #{<<"lab17-2026a">> => {'Ed25519', Pub}}, aud => ?AUD}.

link_and_verify(St) ->
    {ok, #{url := Url, mutations := Ms, ref := Ref}} = gh_viewer:link(job(<<"Betacoronavirus pandemicum">>, <<"sars-cov-2">>), <<"patient-17-sample">>, <<>>),
    ?assertEqual([<<"S:N501Y">>, <<"S:D614G">>, <<"S:H69-">>], Ms),
    {P, S} = parts(Url),
    ?assertMatch(#{<<"k">> := <<"lab17-2026a">>}, maps:from_list(uri_string:dissect_query(maps:get(query, uri_string:parse(Url))))),
    {ok, M} = gh_viewer:verify(<<"lab17-2026a">>, P, S, keys(St)),
    ?assertEqual([<<"alg">>, <<"aud">>, <<"exp">>, <<"iat">>, <<"iss">>, <<"jti">>, <<"kid">>, <<"params">>, <<"ref">>,
                  <<"v">>, <<"view">>], lists:sort(maps:keys(M))),
    ?assertMatch(#{<<"v">> := 1, <<"alg">> := <<"Ed25519">>, <<"kid">> := <<"lab17-2026a">>, <<"iss">> := <<"lab17.example">>,
                   <<"aud">> := ?AUD, <<"view">> := <<"genhub2.structures">>, <<"ref">> := Ref,
                   <<"params">> := #{<<"dataset">> := <<"sars-cov-2">>, <<"lineage">> := <<"BA.2">>,
                                     <<"mutations">> := [<<"S:N501Y">>, <<"S:D614G">>, <<"S:H69-">>]}}, M),
    ?assertEqual(600000, maps:get(<<"exp">>, M) - maps:get(<<"iat">>, M)),
    %% no sample or job names; the public key's file holds no secret the viewer needs
    ?assertEqual(nomatch, binary:match(base64:decode(P, #{mode => urlsafe, padding => false}), [<<"patient">>, <<"job-">>])),
    ?assertEqual(gh_viewer:public_key(maps:get(key_file, St)), base64:encode(maps:get(pub, St), #{mode => urlsafe, padding => false})),
    %% each link is unique
    {ok, #{url := Url2}} = gh_viewer:link(job(<<"Betacoronavirus pandemicum">>, <<"sars-cov-2">>), <<"patient-17-sample">>, <<>>),
    ?assertNotEqual(Url, Url2).

%% re-signed with the right key, so each refusal is for its own reason, not the signature
resigned(Fun) ->
    {Pub, Priv} = gh_viewer:new_key(),
    Now = erlang:system_time(millisecond),
    M0 = #{<<"v">> => 1, <<"alg">> => <<"Ed25519">>, <<"kid">> => <<"k">>, <<"iss">> => <<"lab17.example">>, <<"aud">> => ?AUD,
           <<"jti">> => <<"j1">>, <<"iat">> => Now, <<"exp">> => Now + 600000, <<"view">> => <<"genhub2.structures">>,
           <<"ref">> => <<"r-1">>, <<"params">> => #{<<"dataset">> => <<"sars-cov-2">>, <<"mutations">> => [<<"S:D614G">>]}},
    P = base64:encode(iolist_to_binary(json:encode(Fun(M0))), #{mode => urlsafe, padding => false}),
    {gh_viewer:verify(<<"k">>, P, gh_viewer:sign(P, 'Ed25519', Priv), #{keys => #{<<"k">> => {'Ed25519', Pub}}, aud => ?AUD,
                                                              seen => fun(J) -> J =:= <<"seen">> end}), P, Pub}.

refusals(St) ->
    {ok, #{url := Url}} = gh_viewer:link(job(<<"Betacoronavirus pandemicum">>, <<"sars-cov-2">>), <<"patient-17-sample">>, <<>>),
    {P, S} = parts(Url),
    Text = base64:decode(P, #{mode => urlsafe, padding => false}),
    Tampered = base64:encode(binary:replace(Text, <<"S:D614G">>, <<"S:D614N">>), #{mode => urlsafe, padding => false}),
    ?assertEqual({error, bad_signature}, gh_viewer:verify(<<"lab17-2026a">>, Tampered, S, keys(St))),
    {Other, _} = gh_viewer:new_key(),
    ?assertEqual({error, bad_signature}, gh_viewer:verify(<<"lab17-2026a">>, P, S, #{keys => #{<<"lab17-2026a">> => {'Ed25519', Other}}, aud => ?AUD})),
    ?assertEqual({error, unknown_kid}, gh_viewer:verify(<<"lab17-2026a">>, P, S, #{keys => #{}, aud => ?AUD})), % unknown or withdrawn
    %% EXT-14: the outer kid chooses the key; the inner one must equal it once the signature holds
    ?assertEqual({error, kid_mismatch}, gh_viewer:verify(<<"lab17-test">>, P, S,
                                                         #{keys => #{<<"lab17-test">> => {'Ed25519', maps:get(pub, St)}}, aud => ?AUD})),
    ?assertEqual({error, wrong_aud}, gh_viewer:verify(<<"lab17-2026a">>, P, S, (keys(St))#{aud => <<"https://another-lab.example/ext/open">>})),
    Now = erlang:system_time(millisecond),
    [?assertMatch({{error, Why}, _, _}, resigned(F)) || {Why, F} <-
        [{expired, fun(M) -> M#{<<"iat">> => Now - 700000, <<"exp">> => Now - 100000} end},
         {issued_in_the_future, fun(M) -> M#{<<"iat">> => Now + 120000, <<"exp">> => Now + 300000} end},
         {lifetime_over_the_cap, fun(M) -> M#{<<"exp">> => Now + 3600000} end},
         {replayed, fun(M) -> M#{<<"jti">> => <<"seen">>} end},
         {unknown_version, fun(M) -> M#{<<"v">> => 2} end},
         {unknown_or_missing_field, fun(M) -> M#{<<"patient">> => <<"x">>} end},
         {unregistered_view, fun(M) -> M#{<<"view">> => <<"plants.motion">>} end},
         {unknown_dataset, fun(M) -> M#{<<"params">> => #{<<"dataset">> => <<"measles">>, <<"mutations">> => []}} end},
         {unknown_parameter, fun(M) -> M#{<<"params">> => #{<<"dataset">> => <<"sars-cov-2">>, <<"mutations">> => [],
                                                           <<"sample">> => <<"x">>}} end}]],
    {{ok, _}, _, _} = resigned(fun(M) -> M end),
    Big = binary:copy(<<"A">>, 20000),
    ?assertEqual({error, oversized}, gh_viewer:verify(<<"lab17-2026a">>, Big, S, keys(St))).

datasets() ->
    ?assertEqual(<<"sars-cov-2">>, gh_viewer:dataset(<<"Betacoronavirus pandemicum">>, <<"any">>)),
    ?assertEqual(<<"rsv-a">>, gh_viewer:dataset(<<"Orthopneumovirus hominis">>, <<"nextstrain/rsv/a/EPI_ISL_412866">>)),
    ?assertEqual(<<"rsv-b">>, gh_viewer:dataset(<<"Orthopneumovirus hominis">>, <<"nextstrain/rsv/b/EPI_ISL_1653999">>)),
    ?assertEqual(none, gh_viewer:dataset(<<"Orthopneumovirus hominis">>, <<"unknown">>)),
    {ok, #{url := Url}} = gh_viewer:link(job(<<"Orthopneumovirus hominis">>, <<"nextstrain/rsv/b/x">>), <<"patient-17-sample">>, <<>>),
    {P, _} = parts(Url),
    ?assertMatch(#{<<"params">> := #{<<"dataset">> := <<"rsv-b">>}},
                 json:decode(base64:decode(P, #{mode => urlsafe, padding => false}))),
    %% a site may switch a dataset off
    {ok, C} = application:get_env(genhub2, structure_viewer),
    ok = application:set_env(genhub2, structure_viewer, C#{datasets => [<<"sars-cov-2">>, <<"rsv-a">>]}),
    ?assertMatch({error, _}, gh_viewer:link(job(<<"Orthopneumovirus hominis">>, <<"nextstrain/rsv/b/x">>), <<"patient-17-sample">>, <<>>)),
    ok = application:set_env(genhub2, structure_viewer, C),
    ?assertMatch({error, _}, gh_viewer:link(job(<<"Orthoflavivirus denguei">>, <<"dengue">>), <<"patient-17-sample">>, <<>>)).

hs256() ->
    {ok, C} = application:get_env(genhub2, structure_viewer),
    ok = application:set_env(genhub2, structure_viewer, C#{active => <<"lab17-test">>}),
    {ok, #{url := Url}} = gh_viewer:link(job(<<"Betacoronavirus pandemicum">>, <<"sars-cov-2">>), <<"patient-17-sample">>, <<>>),
    {P, S} = parts(Url),
    ?assertMatch({ok, #{<<"alg">> := <<"HS256">>}},
                 gh_viewer:verify(<<"lab17-test">>, P, S, #{keys => #{<<"lab17-test">> => {'HS256', <<"0123456789abcdef0123456789abcdef-test">>}}, aud => ?AUD})),
    ok = application:set_env(genhub2, structure_viewer, C).

%% EXT-27: push mode never goes to a plain-HTTP address
no_plain_http() ->
    {ok, C} = application:get_env(genhub2, structure_viewer),
    ok = application:set_env(genhub2, structure_viewer, C#{base => "http://twin.example", mode => push}),
    ?assertError(structure_viewer_base_must_be_https,
                 gh_viewer:link(job(<<"Betacoronavirus pandemicum">>, <<"sars-cov-2">>), <<"patient-17-sample">>, <<>>)),
    ok = application:set_env(genhub2, structure_viewer, C).
