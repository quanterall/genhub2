%% The structure viewer's link (gh_viewer): signed, short-lived, without sample or job names; the viewer's check.
-module(gh_viewer_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"0123456789abcdef0123456789abcdef-test">>).

viewer_test_() ->
    {setup,
     fun() ->
             F = filename:join("/tmp", "gh-viewer-" ++ os:getpid()),
             ok = file:write_file(F, ?SECRET),
             _ = application:load(genhub2),
             ok = application:set_env(genhub2, structure_viewer,
                                      #{url => "https://viewer.example/genhub2/open", secret_file => F,
                                        viruses => [<<"Betacoronavirus pandemicum">>]}),
             F
     end,
     fun(F) -> application:unset_env(genhub2, structure_viewer), file:delete(F) end,
     [fun link_and_verify/0, fun refusals/0]}.

job(Species) ->
    #{id => <<"job-secret-id">>,
      steps => #{classify => #{results => [[#{<<"query">> => <<"patient-17-sample">>,
                                              <<"call">> => #{<<"species">> => Species, <<"confidence">> => <<"high">>}}]]},
                 lineage => #{results => [[#{query => <<"patient-17-sample">>, dataset => <<"sars-cov-2">>, pango => <<"BA.2">>,
                                             clade => <<"21L">>, aa_substitutions => [<<"S:N501Y">>, <<"S:D614G">>],
                                             aa_deletions => [<<"S:H69-">>]}]]}}}.

link_and_verify() ->
    {ok, #{url := Url, mutations := Ms}} = gh_viewer:link(job(<<"Betacoronavirus pandemicum">>), <<"patient-17-sample">>, <<"site-a">>),
    ?assertEqual([<<"S:N501Y">>, <<"S:D614G">>, <<"S:H69-">>], Ms),
    #{query := Qs} = uri_string:parse(Url),
    #{<<"d">> := P, <<"s">> := S} = maps:from_list(uri_string:dissect_query(Qs)),
    {ok, M} = gh_viewer:verify(P, S, ?SECRET),
    ?assertMatch(#{<<"v">> := 1, <<"issuer">> := <<"site-a">>, <<"virus">> := <<"Betacoronavirus pandemicum">>,
                   <<"lineage">> := <<"BA.2">>, <<"mutations">> := [<<"S:N501Y">>, <<"S:D614G">>, <<"S:H69-">>]}, M),
    %% no sample or job names travel
    Json = base64:decode(P, #{mode => urlsafe, padding => false}),
    ?assertEqual(nomatch, binary:match(Json, [<<"patient">>, <<"job-">>])),
    %% a changed payload, a wrong secret: refused
    Changed = base64:encode(binary:replace(Json, <<"BA.2">>, <<"XX.9">>), #{mode => urlsafe, padding => false}),
    ?assertEqual({error, bad_signature}, gh_viewer:verify(Changed, S, ?SECRET)),
    ?assertEqual({error, bad_signature}, gh_viewer:verify(P, S, <<"another secret of 32 bytes or more!!">>)),
    %% expired
    Old = base64:encode(iolist_to_binary(json:encode((json:decode(Json))#{<<"expires">> => 1})), #{mode => urlsafe, padding => false}),
    OldSig = base64:encode(crypto:mac(hmac, sha256, ?SECRET, Old), #{mode => urlsafe, padding => false}),
    ?assertEqual({error, expired}, gh_viewer:verify(Old, OldSig, ?SECRET)),
    ?assertEqual({error, bad_signature}, gh_viewer:verify(<<"x">>, <<"y">>, ?SECRET)).

refusals() ->
    ?assertMatch({error, _}, gh_viewer:link(job(<<"Orthoflavivirus denguei">>), <<"patient-17-sample">>, <<"s">>)),
    ?assertMatch({error, _}, gh_viewer:link(job(<<"Betacoronavirus pandemicum">>), <<"another-genome">>, <<"s">>)),
    ?assertEqual(#{enabled => true, viruses => [<<"Betacoronavirus pandemicum">>]}, gh_viewer:config()),
    application:unset_env(genhub2, structure_viewer),
    ?assertEqual(#{enabled => false, viruses => []}, gh_viewer:config()),
    ?assertMatch({error, _}, gh_viewer:link(job(<<"Betacoronavirus pandemicum">>), <<"patient-17-sample">>, <<"s">>)).
