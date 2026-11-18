%% Epidemic monitoring from aggregated counts (FS 5.4, plan section 3.4, phase D): each site turns its results into
%% counts per ISO week, region and lineage, and per week, region and mutation, and sites exchange these counts, never
%% sequences, sample names or patients' data. Every site merges the same aggregates the same way and computes the
%% alerts from them, so every site raises the same alerts, with no central server.
%%
%% An aggregate (format genhub2-aggregates/1):
%%   #{format, site, generated (ms), lineages => [#{week, region, lineage, n}], mutations => [#{week, region, mutation, n}],
%%     totals => [#{week, region, n}], lineage_mutations => [#{week, lineage, mutation, n}]}
%%   week: the ISO week of the sample's collection date, "2026-W46"; region: ISO 3166-2 (e.g. "BG-22");
%%   mutation: reference accession and substitution, e.g. "NC_045512.2:A23403G"; totals: the sequences counted.
%% Sequences without a region and collection date are not counted (from_rows/3 says how many).
%%
%% Alerts (alerts/2), on the latest week of the merged counts:
%%   new_lineage      a lineage counted in that week and in no earlier week, at any site
%%   rising_mutation  a mutation whose share of that week's sequences is at least min_share, at least ratio times its
%%                    mean share over the baseline_weeks before, in at least min_n sequences; unless at least half of
%%                    its sequences that week are of a new lineage: then it is listed in that lineage's alert
%%                    (mutations), not raised on its own
-module(gh_agg).
-export([from_rows/3, merge/1, alerts/2, week/1, valid_region/1, valid_date/1, to_json/1, from_json/1]).

-define(FORMAT, <<"genhub2-aggregates/1">>).
-define(DEFAULTS, #{min_share => 0.10, ratio => 2.0, min_n => 5, baseline_weeks => 4}).

%% Rows: #{lineage, mutations => [binary()], region, collection_date} per sequence (lineage <<>> when none).
%% {Aggregate, NotCounted}
-spec from_rows(binary(), [map()], integer()) -> {map(), non_neg_integer()}.
from_rows(Site, Rows, Now) ->
    Counted = [R#{week => week(D)} || #{region := Reg, collection_date := D} = R <- Rows,
                                       valid_region(Reg), valid_date(D)],
    L = count([{W, Reg, Lin} || #{week := W, region := Reg, lineage := Lin} <- Counted, Lin =/= <<>>]),
    M = count([{W, Reg, Mu} || #{week := W, region := Reg, mutations := Ms} <- Counted, Mu <- lists:usort(Ms)]),
    T = count([{W, Reg} || #{week := W, region := Reg} <- Counted]),
    LM = count([{W, Lin, Mu} || #{week := W, lineage := Lin, mutations := Ms} <- Counted, Lin =/= <<>>, Mu <- lists:usort(Ms)]),
    {#{format => ?FORMAT, site => Site, generated => Now,
       lineages => [#{week => W, region => Reg, lineage => Lin, n => N} || {{W, Reg, Lin}, N} <- lists:sort(maps:to_list(L))],
       mutations => [#{week => W, region => Reg, mutation => Mu, n => N} || {{W, Reg, Mu}, N} <- lists:sort(maps:to_list(M))],
       totals => [#{week => W, region => Reg, n => N} || {{W, Reg}, N} <- lists:sort(maps:to_list(T))],
       lineage_mutations => [#{week => W, lineage => Lin, mutation => Mu, n => N}
                             || {{W, Lin, Mu}, N} <- lists:sort(maps:to_list(LM))]},
     length(Rows) - length(Counted)}.

%% the aggregates of several sites as one: per site the newest; counts summed; the sites listed
-spec merge([map()]) -> map().
merge(Aggs) ->
    Newest = maps:values(lists:foldl(fun(#{site := S, generated := G} = A, Acc) ->
                                             case Acc of
                                                 #{S := #{generated := G0}} when G0 >= G -> Acc;
                                                 _ -> Acc#{S => A}
                                             end
                                     end, #{}, [A || #{format := ?FORMAT} = A <- Aggs])),
    %% optional in older aggregates
    WithLM = [A#{lineage_mutations => maps:get(lineage_mutations, A, [])} || A <- Newest],
    Sum = fun(Key, Fields) ->
                  C = lists:foldl(fun(E, Acc) -> maps:update_with([maps:get(F, E) || F <- Fields],
                                                                  fun(N) -> N + maps:get(n, E) end, maps:get(n, E), Acc)
                                  end, #{}, lists:append([maps:get(Key, A) || A <- WithLM])),
                  [maps:from_list(lists:zip(Fields, K) ++ [{n, N}]) || {K, N} <- lists:sort(maps:to_list(C))]
          end,
    #{format => ?FORMAT, sites => lists:sort([S || #{site := S} <- Newest]),
      lineages => Sum(lineages, [week, region, lineage]), mutations => Sum(mutations, [week, region, mutation]),
      totals => Sum(totals, [week, region]), lineage_mutations => Sum(lineage_mutations, [week, lineage, mutation])}.

%% the alerts of merged aggregates (merge/1) for their latest week; Opts overrides ?DEFAULTS
-spec alerts(map(), map()) -> [map()].
alerts(#{totals := []}, _) -> [];
alerts(#{lineages := Ls, mutations := Ms, totals := Ts} = Merged, Opts0) ->
    LMs = maps:get(lineage_mutations, Merged, []),
    #{min_share := MinShare, ratio := Ratio, min_n := MinN, baseline_weeks := BW} = maps:merge(?DEFAULTS, Opts0),
    Weeks = lists:usort([W || #{week := W} <- Ts]),
    Last = lists:last(Weeks),
    Before = lists:sublist(lists:reverse(Weeks -- [Last]), BW),
    Total = fun(W) -> lists:sum([N || #{week := X, n := N} <- Ts, X =:= W]) end,
    Earlier = sets:from_list([L || #{week := W, lineage := L} <- Ls, W < Last], [{version, 2}]),
    New = [#{type => new_lineage, week => Last, lineage => L,
             n => lists:sum([N || #{week := W, lineage := X, n := N} <- Ls, W =:= Last, X =:= L]),
             regions => lists:usort([R || #{week := W, lineage := X, region := R} <- Ls, W =:= Last, X =:= L])}
           || L <- lists:usort([L || #{week := W, lineage := L} <- Ls, W =:= Last]), not sets:is_element(L, Earlier)],
    MutN = fun(W, Mu) -> lists:sum([N || #{week := X, mutation := Y, n := N} <- Ms, X =:= W, Y =:= Mu]) end,
    Share = fun(W, Mu) -> case Total(W) of 0 -> 0.0; T -> MutN(W, Mu) / T end end,
    Rising = [#{type => rising_mutation, week => Last, mutation => Mu, n => MutN(Last, Mu), share => round4(Share(Last, Mu)),
                baseline => round4(Base)}
              || Mu <- lists:usort([Mu || #{week := W, mutation := Mu} <- Ms, W =:= Last]),
                 MutN(Last, Mu) >= MinN, Share(Last, Mu) >= MinShare,
                 Base <- [case Before of [] -> 0.0; _ -> lists:sum([Share(W, Mu) || W <- Before]) / length(Before) end],
                 Share(Last, Mu) >= Ratio * Base, Before =/= []],
    %% a rising mutation mostly in a new lineage's sequences goes into that lineage's alert
    NewL = [L || #{lineage := L} <- New],
    InLin = fun(Mu, L) -> lists:sum([N || #{week := W, lineage := X, mutation := Y, n := N} <- LMs, W =:= Last, X =:= L, Y =:= Mu]) end,
    Owner = fun(#{mutation := Mu, n := N}) ->
                    case lists:reverse(lists:sort([{InLin(Mu, L), L} || L <- NewL])) of
                        [{K, L} | _] when 2 * K >= N, K > 0 -> L;
                        _ -> none
                    end
            end,
    Owned = [{Owner(R), R} || R <- Rising],
    [A#{mutations => [maps:with([mutation, n, share, baseline], R) || {L, R} <- Owned, L =:= maps:get(lineage, A)]} || A <- New]
        ++ [R || {none, R} <- Owned].

round4(X) -> round(X * 10000) / 10000.

%% "2026-W46" of an ISO date "2026-11-12"
-spec week(binary()) -> binary().
week(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary>>) ->
    {WY, W} = calendar:iso_week_number({binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)}),
    iolist_to_binary(io_lib:format("~4..0B-W~2..0B", [WY, W])).

%% ISO 3166-2: a country code, optionally a subdivision ("BG", "BG-22")
-spec valid_region(term()) -> boolean().
valid_region(R) when is_binary(R) -> re:run(R, "^[A-Z]{2}(-[A-Z0-9]{1,3})?$", [{capture, none}]) =:= match;
valid_region(_) -> false.

%% an ISO date that exists and is not in the future
-spec valid_date(term()) -> boolean().
valid_date(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary>>) ->
    try
        Date = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
        calendar:valid_date(Date) andalso Date =< element(1, calendar:universal_time())
    catch error:badarg -> false
    end;
valid_date(_) -> false.

%% aggregates as JSON (binary keys, as another site sends them) and back, checked
-spec to_json(map()) -> iodata().
to_json(A) -> json:encode(A).

-spec from_json(binary()) -> {ok, map()} | {error, term()}.
from_json(B) ->
    %% everything inside the try: a malformed field anywhere is a refusal, not a crash
    try {ok, convert(json:decode(B))}
    catch _:_ -> {error, not_an_aggregate}
    end.

convert(#{<<"format">> := ?FORMAT, <<"site">> := S, <<"generated">> := G, <<"lineages">> := L, <<"mutations">> := M,
          <<"totals">> := T} = Agg) when is_binary(S), is_integer(G) ->
    Row = fun(Fields) -> fun(E) -> maps:from_list([{F, field(E, F)} || F <- Fields] ++ [{n, count_n(E)}]) end end,
    #{format => ?FORMAT, site => S, generated => G,
      lineages => lists:map(Row([week, region, lineage]), L),
      mutations => lists:map(Row([week, region, mutation]), M),
      totals => lists:map(Row([week, region]), T),
      lineage_mutations => lists:map(Row([week, lineage, mutation]), maps:get(<<"lineage_mutations">>, Agg, []))}.

field(E, F) ->
    case maps:get(atom_to_binary(F), E) of
        V when is_binary(V) -> V;
        _ -> error(bad_field)
    end.

count_n(#{<<"n">> := N}) when is_integer(N), N > 0 -> N.

count(L) -> lists:foldl(fun(X, M) -> maps:update_with(X, fun(C) -> C + 1 end, 1, M) end, #{}, L).
