%% Phase D's check, the part inside the labs (plan section 5, FS 5.4): monitoring from aggregated counts, with a new
%% lineage planted at one of three sites. A planted novel lineage must raise an alert at every site, with no central
%% server: each site exports its counts, imports the others', and computes the alerts from all of them.
%%
%% The data: phase A's 1,000 public SARS-CoV-2 genomes, with their real lineages (Nextclade) and mutations (minimap2).
%% Each genome gets a simulated site (regions BG-22, BG-02, BG-03) and a collection date in one of 8 weeks:
%%   weeks 1-7  the genomes of 2020-2023 and the Bulgarian set, spread over the sites and weeks in turn;
%%   week 8     genomes of lineages already seen in weeks 1-7 at every site, and at site C only, the planted lineage:
%%              the most common lineage of the June 2024 genomes that none of the earlier genomes has.
%% Checks:
%%   1. before the exchange, only site C sees the new lineage;
%%   2. after it, all three sites raise the same alerts, the planted lineage among them;
%%   3. a control run without the planted genomes raises no new-lineage alert;
%%   4. the merge does not depend on the order the aggregates arrive in;
%%   5. no aggregate contains a genome's name or accession.
%%
%% Results: acceptance/results/monitoring-<host>-<date>.json; exit status 0 when every check holds.
%%   sh acceptance/run_monitoring.sh      (after acceptance/run.sh, which builds the reference bundles)
-module(gh_monitoring_check).
-export([main/1]).

-define(REF, <<"NC_045512.2">>).
-define(NEXTCLADE_TAG, "2026-10-28--15-04-26Z").
-define(SITES, [{<<"site-a">>, <<"BG-22">>}, {<<"site-b">>, <<"BG-02">>}, {<<"site-c">>, <<"BG-03">>}]).
-define(WEEKS, [<<"2026-09-14">>, <<"2026-09-21">>, <<"2026-09-28">>, <<"2026-10-05">>, <<"2026-10-12">>,
                <<"2026-10-19">>, <<"2026-10-26">>, <<"2026-11-02">>]).

-spec main([string()]) -> no_return().
main([Out]) ->
    {ok, _} = application:ensure_all_started(genhub2),
    T0 = erlang:monotonic_time(millisecond),
    Refs = gh_refdb:refseq_viral(),
    Next = gh_refdb:nextclade(?NEXTCLADE_TAG),
    #{fasta := Fasta, sets := Sets} = gh_acceptance:sars_cov_2(),
    log("lineages and mutations of the 1,000 genomes"),
    Genomes = genomes(Fasta, Sets, Refs, Next),
    {Plan, Planted} = plan(Genomes),
    log(io_lib:format("planted lineage ~s: ~b genomes at site C in the last week", [Planted, length(planted_rows(Plan))])),
    WithPlant = run(Plan),
    Control = run([P || #{planted := false} = P <- Plan]),
    Checks = checks(WithPlant, Control, Planted, Genomes),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), planted_lineage => Planted,
          sites => [#{site => S, region => Reg} || {S, Reg} <- ?SITES], weeks => [gh_agg:week(W) || W <- ?WEEKS],
          genomes => length(Genomes), counted => length(Plan),
          with_plant => maps:without([aggregates_json], WithPlant), control => maps:without([aggregates_json], Control),
          checks => Checks, seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(gh_json:term(R))),
    Failed = [C || #{ok := false} = C <- Checks],
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    io:format("~b of ~b checks hold~nwritten ~s~n", [length(Checks) - length(Failed), length(Checks), Out]),
    halt(case Failed of [] -> 0; _ -> 1 end).

log(S) -> io:format("~s ~s~n", [calendar:system_time_to_rfc3339(erlang:system_time(second)), S]).

%% [#{query, set, lineage, mutations}] in the file's order
genomes(Fasta, Sets, Refs, Next) ->
    Chunks = gh_phylo:chunks(Fasta, 100),
    Lin = lists:append(pq_rexec:map([{pq_task, gh_lineage, {lineage, C, Next}} || C <- Chunks], local, #{})),
    Mut = lists:append(pq_rexec:map([{pq_task, gh_mutations, {mutations, C, Refs, ?REF}} || C <- Chunks], local, #{})),
    SetOf = maps:from_list([{A, S} || {S, A} <- Sets]),
    LinOf = maps:from_list([{Q, P} || #{query := Q, pango := P} <- Lin]),
    [#{query => Q, set => maps:get(Q, SetOf, maps:get(base(Q), SetOf, <<>>)), lineage => maps:get(Q, LinOf, <<>>),
       mutations => [iolist_to_binary([?REF, ":", Rf, integer_to_list(P), A]) || [P, Rf, A] <- Ss]}
     || #{query := Q, aligned := true, substitutions := Ss} <- Mut].

%% the accession without its version ("PX916490.1" -> "PX916490"), for the check that no aggregate names a genome
base(Q) ->
    case binary:split(Q, <<".">>) of [B, _] -> B; _ -> Q end.

%% Plan: each genome counted, with site, region, date and planted flag; and the planted lineage
plan(Genomes) ->
    Early = [G || #{set := S, lineage := L} = G <- Genomes, S =/= <<"2024-06">>, L =/= <<>>],
    Late = [G || #{set := <<"2024-06">>, lineage := L} = G <- Genomes, L =/= <<>>],
    Seen = sets:from_list([L || #{lineage := L} <- Early], [{version, 2}]),
    Novel = count([L || #{lineage := L} <- Late, not sets:is_element(L, Seen)]),
    [{Planted, _} | _] = lists:sort(fun({A, NA}, {B, NB}) -> {NB, A} =< {NA, B} end, maps:to_list(Novel)),
    NSites = length(?SITES),
    %% weeks 1-7: the early genomes in turn over sites and weeks; every 8th early genome goes to week 8 instead,
    %% if its lineage is already among those placed in weeks 1-7 at its site's region
    {Spread, _} = lists:mapfoldl(fun(G, I) ->
                                         {S, Reg} = lists:nth(1 + I rem NSites, ?SITES),
                                         Wk = case I rem 8 of 7 -> 8; _ -> 1 + (I div NSites) rem 7 end,
                                         {G#{site => S, region => Reg, collection_date => lists:nth(Wk, ?WEEKS), week_no => Wk,
                                             planted => false}, I + 1}
                                 end, 0, Early),
    InFirst7 = sets:from_list([L || #{lineage := L, week_no := W} <- Spread, W < 8], [{version, 2}]),
    Week8 = [G || #{week_no := 8, lineage := L} = G <- Spread, sets:is_element(L, InFirst7)],
    {SiteC, RegC} = lists:last(?SITES),
    Plant = [G#{site => SiteC, region => RegC, collection_date => lists:last(?WEEKS), week_no => 8, planted => true}
             || #{lineage := L} = G <- Late, L =:= Planted],
    {[G || #{week_no := W} = G <- Spread, W < 8] ++ Week8 ++ Plant, Planted}.

planted_rows(Plan) -> [P || #{planted := true} = P <- Plan].

%% every site: its own aggregate; the alerts before the exchange (its own counts only) and after it (all, as JSON)
run(Plan) ->
    Aggs = [begin
                Rows = [maps:with([lineage, mutations, region, collection_date], P) || #{site := X} = P <- Plan, X =:= S],
                {A, 0} = gh_agg:from_rows(S, Rows, 1000),
                A
            end || {S, _} <- ?SITES],
    Json = [iolist_to_binary(gh_agg:to_json(A)) || A <- Aggs],
    Before = [gh_agg:alerts(gh_agg:merge([A]), #{}) || A <- Aggs],
    %% each site imports the others' aggregates as JSON, exactly as they would arrive
    After = [begin
                 Others = [begin {ok, X} = gh_agg:from_json(J), X end || {J, I2} <- lists:zip(Json, lists:seq(1, 3)), I2 =/= I],
                 gh_agg:alerts(gh_agg:merge([A | Others]), #{})
             end || {A, I} <- lists:zip(Aggs, lists:seq(1, 3))],
    Orders = [gh_agg:merge(P) || P <- [Aggs, lists:reverse(Aggs), [lists:nth(2, Aggs), lists:nth(3, Aggs), hd(Aggs)]]],
    #{sites => [S || {S, _} <- ?SITES], before => Before, after_exchange => After, aggregates_json => Json,
      merge_order_independent => lists:usort(Orders) =:= [hd(Orders)],
      counts => [#{site => maps:get(site, A), sequences => lists:sum([N || #{n := N} <- maps:get(totals, A)])} || A <- Aggs]}.

checks(W, C, Planted, Genomes) ->
    NewOf = fun(Alerts) -> [L || #{type := new_lineage, lineage := L} <- Alerts] end,
    Before = [NewOf(A) || A <- maps:get(before, W)],
    After = maps:get(after_exchange, W),
    Names = lists:usort(lists:append([[Q, base(Q)] || #{query := Q} <- Genomes])),
    Leaked = [N || J <- maps:get(aggregates_json, W), N <- Names, binary:match(J, N) =/= nomatch],
    [check(<<"before the exchange, only site C sees the planted lineage">>,
           [lists:member(Planted, B) || B <- Before] =:= [false, false, true], Before),
     check(<<"after the exchange, every site raises the same alerts">>, lists:usort(After) =:= [hd(After)],
           [#{new_lineage => length([x || #{type := new_lineage} <- A]),
              mutations_in_new_lineages => lists:sum([length(maps:get(mutations, X, [])) || #{type := new_lineage} = X <- A]),
              rising_mutation => length([x || #{type := rising_mutation} <- A])} || A <- After]),
     check(<<"after the exchange, every site alerts on the planted lineage">>,
           lists:all(fun(A) -> lists:member(Planted, NewOf(A)) end, After), [NewOf(A) || A <- After]),
     check(<<"control without the planted genomes: no new-lineage alert at any site">>,
           [NewOf(A) || A <- maps:get(after_exchange, C)] =:= [[], [], []], [NewOf(A) || A <- maps:get(after_exchange, C)]),
     check(<<"the merge does not depend on the order the aggregates arrive in">>, maps:get(merge_order_independent, W), true),
     check(<<"no aggregate contains a genome's name or accession">>, Leaked =:= [], Leaked)].

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => iolist_to_binary(io_lib:format("~0P", [Value, 40]))}.

count(L) -> lists:foldl(fun(X, M) -> maps:update_with(X, fun(N) -> N + 1 end, 1, M) end, #{}, L).
