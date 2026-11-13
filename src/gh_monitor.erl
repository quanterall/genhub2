%% Epidemic monitoring at the site (FS 5.4, the local half of phase D): counts of the site's results by species,
%% lineage and ISO week, each with the job and date it was first seen; and an alert on genhub/alerts when a finished
%% job brings a species or a lineage the site has not seen before. Computed from the job table, so nothing is kept
%% twice. Exchanging the counts between sites, without sequences, is phase D.
-module(gh_monitor).
-export([summary/0, job_done/1]).

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
    _ = [gh_events:publish(<<"genhub/alerts">>, #{type => <<"new_", (atom_to_binary(K))/binary>>, K => V, job => Id})
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
