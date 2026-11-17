%% Epidemic monitoring at the site (FS 5.4, the local half of phase D): counts of the site's results by species,
%% lineage and ISO week, each with the job and date it was first seen; and an alert on genhub/alerts when a finished
%% job brings a species or a lineage the site has not seen before. Computed from the job table, so nothing is kept
%% twice. Exchanging the counts between sites, without sequences, is phase D.
%%
%% Aggregates (gh_agg, phase D): the site's counts per week, region, lineage and mutation, from the jobs that carry a
%% region and a collection date (params metadata, per job or per sequence); other sites' aggregates are imported and
%% kept (gh_agg_import), and the alerts are computed from all of them merged.
-module(gh_monitor).
-export([summary/0, job_done/1, tables/0, site/0, aggregate/0, import/1, imported/0, merged_alerts/1,
         rows_for_aggregates/0]).

-record(gh_agg_import, {site, aggregate, imported}).

-spec tables() -> ok.
tables() ->
    case mnesia:create_table(gh_agg_import, [{attributes, record_info(fields, gh_agg_import)}, {disc_copies, [node()]}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, gh_agg_import}} -> ok
    end,
    ok = mnesia:wait_for_tables([gh_agg_import], 60000).

%% this site's name in aggregates: the setting site, or the host's name
-spec site() -> binary().
site() ->
    case application:get_env(genhub2, site) of
        {ok, S} when is_binary(S) -> S;
        _ -> list_to_binary(net_adm:localhost())
    end.

%% {Aggregate, NotCounted}: this site's aggregate now
-spec aggregate() -> {map(), non_neg_integer()}.
aggregate() -> gh_agg:from_rows(site(), rows_for_aggregates(), erlang:system_time(millisecond)).

%% another site's aggregate kept (the newest per site wins in the merge); not this site's own
-spec import(map()) -> ok | {error, own_site}.
import(#{site := S} = A) ->
    case S =:= site() of
        true -> {error, own_site};
        false -> mnesia:dirty_write(#gh_agg_import{site = S, aggregate = A, imported = erlang:system_time(millisecond)})
    end.

-spec imported() -> [map()].
imported() -> [A || #gh_agg_import{aggregate = A} <- mnesia:dirty_match_object(#gh_agg_import{_ = '_'})].

%% #{alerts, sites, latest_week}: the alerts of this site's aggregate merged with the imported ones
-spec merged_alerts(map()) -> map().
merged_alerts(Opts) ->
    {Own, _} = aggregate(),
    M = gh_agg:merge([Own | imported()]),
    #{alerts => gh_agg:alerts(M, Opts), sites => maps:get(sites, M),
      latest_week => case [W || #{week := W} <- maps:get(totals, M)] of [] -> null; Ws -> lists:max(Ws) end}.

%% one row per sequence of every finished analysis: #{lineage, mutations, region, collection_date}; the metadata is
%% the job's (params metadata), a sequence's own (metadata sequences) overriding it
-spec rows_for_aggregates() -> [map()].
rows_for_aggregates() ->
    lists:append(
      [begin
           V = gh_jobs:view(Id),
           Meta = maps:get(metadata, maps:get(params, V, #{}), #{}),
           Per = maps:get(sequences, Meta, #{}),
           Muts = maps:from_list([{Q, [mutation(Acc, S) || S <- Ss]}
                                  || #{query := Q, aligned := true, reference := Acc, substitutions := Ss}
                                         <- results(V, mutations)]),
           [begin
                M = maps:merge(maps:with([region, collection_date], Meta), maps:get(Q, Per, #{})),
                #{lineage => P, mutations => maps:get(Q, Muts, []), region => maps:get(region, M, none),
                  collection_date => maps:get(collection_date, M, none)}
            end || #{query := Q, pango := P} <- gh_export:rows(V)]
       end || #{id := Id, state := done, kind := K} <- gh_jobs:list(), K =/= tree]).

results(#{steps := Steps}, Step) ->
    case Steps of
        #{Step := #{results := R}} -> lists:append([X || X <- R, is_list(X)]);
        _ -> []
    end.

mutation(Acc, [Pos, Ref, Alt]) -> iolist_to_binary([Acc, ":", Ref, integer_to_list(Pos), Alt]).

%% #{species, lineages: [#{name, count, first_seen, first_job}], weeks: [#{week, lineage, count}], analyses}
-spec summary() -> map().
summary() ->
    Rows = rows(),
    #{analyses => length(lists:usort([J || {J, _, _} <- Rows])),
      species => tally([{maps:get(species, R), J, T} || {J, T, R} <- Rows, maps:get(species, R) =/= <<>>]),
      lineages => tally([{maps:get(pango, R), J, T} || {J, T, R} <- Rows, maps:get(pango, R) =/= <<>>]),
      weeks => [#{week => W, lineage => L, count => N}
                || {{W, L}, N} <- lists:sort(maps:to_list(count([{week(T), maps:get(pango, R)}
                                                                 || {_, T, R} <- Rows, maps:get(pango, R) =/= <<>>])))]}.

%% after a job is done: an alert for each species or lineage it is the first to bring
-spec job_done(binary()) -> ok.
job_done(Id) ->
    Rows = rows(),
    Earlier = [R || {J, _, R} <- Rows, J =/= Id],
    Mine = [R || {J, _, R} <- Rows, J =:= Id],
    _ = [begin
             Alert = #{type => <<"new_", (atom_to_binary(K))/binary>>, K => V, job => Id},
             gh_audit:log(<<"system">>, alert, Id, ok, Alert),
             gh_events:publish(<<"genhub/alerts">>, Alert)
         end
         || K <- [species, pango],
            V <- lists:usort([maps:get(K, R) || R <- Mine]), V =/= <<>>,
            not lists:member(V, [maps:get(K, R) || R <- Earlier])],
    ok.

%% {Job, Created, Row} of every sequence of every finished analysis (gh_export:rows/1), oldest first
rows() ->
    lists:append([[{maps:get(id, J), maps:get(created, J), R} || R <- gh_export:rows(gh_jobs:view(maps:get(id, J)))]
                  || J <- lists:reverse(gh_jobs:list()), maps:get(state, J) =:= done, maps:get(kind, J) =/= tree]).

tally(Items) ->
    Firsts = lists:foldl(fun({K, J, T}, M) -> case is_map_key(K, M) of true -> M; false -> M#{K => {J, T}} end end,
                         #{}, Items),
    Counts = count([K || {K, _, _} <- Items]),
    [#{name => K, count => N, first_job => element(1, maps:get(K, Firsts)),
       first_seen => list_to_binary(calendar:system_time_to_rfc3339(element(2, maps:get(K, Firsts)),
                                                                    [{unit, millisecond}, {offset, "Z"}]))}
     || {K, N} <- lists:reverse(lists:keysort(2, maps:to_list(Counts)))].

count(L) -> lists:foldl(fun(X, M) -> maps:update_with(X, fun(C) -> C + 1 end, 1, M) end, #{}, L).

%% "2026-W46"
week(Ms) ->
    {Date, _} = calendar:system_time_to_universal_time(Ms, millisecond),
    {Y, W} = calendar:iso_week_number(Date),
    iolist_to_binary(io_lib:format("~4..0B-W~2..0B", [Y, W])).
