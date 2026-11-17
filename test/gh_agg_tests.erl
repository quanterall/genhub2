%% Aggregates (gh_agg): counting, merging, alerts and the exchange format.
-module(gh_agg_tests).
-include_lib("eunit/include/eunit.hrl").

week_test() ->
    ?assertEqual(<<"2026-W46">>, gh_agg:week(<<"2026-11-12">>)),
    %% ISO weeks cross years: 1 January 2027 is a Friday, in 2026's week 53
    ?assertEqual(<<"2026-W53">>, gh_agg:week(<<"2027-01-01">>)),
    ?assertEqual(<<"2027-W01">>, gh_agg:week(<<"2027-01-04">>)).

valid_test() ->
    [?assert(gh_agg:valid_region(R)) || R <- [<<"BG">>, <<"BG-22">>, <<"FR-75C">>]],
    [?assertNot(gh_agg:valid_region(R)) || R <- [<<"bg-22">>, <<"BG-">>, <<"Sofia">>, 22]],
    ?assert(gh_agg:valid_date(<<"2024-02-29">>)),
    [?assertNot(gh_agg:valid_date(D)) || D <- [<<"2023-02-29">>, <<"2099-01-01">>, <<"12/11/2026">>, none]].

row(Lin, Muts, Region, Date) -> #{lineage => Lin, mutations => Muts, region => Region, collection_date => Date}.

from_rows_test() ->
    Rows = [row(<<"BA.2">>, [<<"R:A1G">>, <<"R:C2T">>], <<"BG-22">>, <<"2026-11-02">>),
            row(<<"BA.2">>, [<<"R:A1G">>], <<"BG-22">>, <<"2026-11-03">>),
            row(<<>>, [<<"R:A1G">>], <<"BG-02">>, <<"2026-11-03">>),
            row(<<"BA.5">>, [], none, <<"2026-11-03">>),                 % no region: not counted
            row(<<"BA.5">>, [], <<"BG-22">>, none)],                     % no date: not counted
    {A, NotCounted} = gh_agg:from_rows(<<"s1">>, Rows, 1),
    ?assertEqual(2, NotCounted),
    ?assertEqual([#{week => <<"2026-W45">>, region => <<"BG-22">>, lineage => <<"BA.2">>, n => 2}], maps:get(lineages, A)),
    ?assertEqual([#{week => <<"2026-W45">>, region => <<"BG-02">>, mutation => <<"R:A1G">>, n => 1},
                  #{week => <<"2026-W45">>, region => <<"BG-22">>, mutation => <<"R:A1G">>, n => 2},
                  #{week => <<"2026-W45">>, region => <<"BG-22">>, mutation => <<"R:C2T">>, n => 1}], maps:get(mutations, A)),
    ?assertEqual([#{week => <<"2026-W45">>, region => <<"BG-02">>, n => 1}, #{week => <<"2026-W45">>, region => <<"BG-22">>, n => 2}],
                 maps:get(totals, A)),
    %% nothing in it names a sample
    ?assertEqual([format, generated, lineages, mutations, site, totals], lists:sort(maps:keys(A))).

merge_test() ->
    {Old, _} = gh_agg:from_rows(<<"s1">>, [row(<<"X">>, [], <<"BG">>, <<"2026-11-02">>)], 1),
    {New, _} = gh_agg:from_rows(<<"s1">>, [row(<<"Y">>, [], <<"BG">>, <<"2026-11-02">>)], 2),
    {Other, _} = gh_agg:from_rows(<<"s2">>, [row(<<"Y">>, [], <<"BG">>, <<"2026-11-02">>)], 1),
    M = gh_agg:merge([Old, Other, New]),
    ?assertEqual([<<"s1">>, <<"s2">>], maps:get(sites, M)),
    %% the newest of s1 only, summed with s2
    ?assertEqual([#{week => <<"2026-W45">>, region => <<"BG">>, lineage => <<"Y">>, n => 2}], maps:get(lineages, M)),
    %% the order the aggregates arrive in does not matter
    ?assertEqual(M, gh_agg:merge([New, Old, Other])).

alerts_test() ->
    Week = fun(D, Rows) -> [row(L, Ms, <<"BG-22">>, D) || {L, Ms} <- Rows] end,
    Base = lists:append([Week(D, [{<<"BA.2">>, [<<"R:A1G">>]} || _ <- lists:seq(1, 18)] ++ [{<<"BA.2">>, [<<"R:C9T">>]} || _ <- [1, 2]])
                         || D <- [<<"2026-10-05">>, <<"2026-10-12">>, <<"2026-10-19">>, <<"2026-10-26">>]]),
    Last = Week(<<"2026-11-02">>, [{<<"BA.2">>, [<<"R:A1G">>]} || _ <- lists:seq(1, 10)]
                                  ++ [{<<"BA.2">>, [<<"R:C9T">>]} || _ <- lists:seq(1, 6)]
                                  ++ [{<<"NEW.1">>, [<<"R:G5A">>]} || _ <- lists:seq(1, 4)]),
    {A, 0} = gh_agg:from_rows(<<"s1">>, Base ++ Last, 1),
    Alerts = gh_agg:alerts(gh_agg:merge([A]), #{}),
    %% NEW.1 is new; C9T rises from 10% to 30% (3x); A1G falls; G5A has 4 < min_n sequences
    ?assertEqual([#{type => new_lineage, week => <<"2026-W45">>, lineage => <<"NEW.1">>, n => 4, regions => [<<"BG-22">>]},
                  #{type => rising_mutation, week => <<"2026-W45">>, mutation => <<"R:C9T">>, n => 6, share => 0.3,
                    baseline => 0.1}], Alerts),
    %% a stricter ratio: C9T's 3x is not enough
    ?assertEqual([new_lineage], [T || #{type := T} <- gh_agg:alerts(gh_agg:merge([A]), #{ratio => 4.0})]).

json_test() ->
    {A, _} = gh_agg:from_rows(<<"s1">>, [row(<<"BA.2">>, [<<"R:A1G">>], <<"BG-22">>, <<"2026-11-02">>)], 7),
    ?assertEqual({ok, A}, gh_agg:from_json(iolist_to_binary(gh_agg:to_json(A)))),
    ?assertEqual({error, not_an_aggregate}, gh_agg:from_json(<<"{\"format\": \"other\"}">>)),
    ?assertEqual({error, not_an_aggregate},
                 gh_agg:from_json(iolist_to_binary(json:encode(#{format => <<"genhub2-aggregates/1">>, site => <<"s">>,
                                                                  generated => 1, lineages => [#{week => 1}],
                                                                  mutations => [], totals => []})))).
