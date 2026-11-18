%% Discovery (plan section 3.5, FS 3.3): a GA4GH Beacon v2 (https://www.ga4gh.org/product/beacon/,
%% https://docs.genomebeacons.org/) over the lab's approved shared datasets (gh_share), so a researcher can ask whether
%% the lab holds genomes with a given mutation or of a given lineage without seeing them.
%%   variants  referenceName (the reference accession, e.g. NC_045512.2), start (0-based, as in Beacon v2),
%%             referenceBases and alternateBases: one substitution; "NC_045512.2", 23402, "A", "G" is A23403G
%%   filters   lineage:<name>, e.g. lineage:LB.1.7; several are combined with AND, and with a variant
%% It searches only approved datasets' anonymised results (genomes renamed, no dates), never unshared analyses.
%% Granularity: boolean (exists) for every role; count only for the lab's own roles (admin, analyst), never for
%% researchers, so small counts do not leave the lab.
-module(gh_beacon).
-export([info/1, datasets/0, filtering_terms/0, query/3]).

-define(API, <<"v2.0.0">>).

-spec info(binary()) -> map().
info(Site) ->
    #{id => <<"genhub2.", Site/binary>>, name => <<"GenHub2 Beacon at ", Site/binary>>, apiVersion => ?API,
      environment => <<"prod">>, organization => #{id => Site, name => Site},
      description => <<"Viral genomes the lab approved for sharing: substitutions against reference genomes, and "
                       "lineages">>, version => <<"0.1.0">>}.

-spec datasets() -> [map()].
datasets() ->
    [#{id => Id, name => T, description => De,
       dataUseConditions => #{duoDataUse => [#{id => C, label => L} || #{code := C, label := L} <- Cs]}}
     || #{id := Id, title := T, description := De, consent := Cs, state := approved} <- gh_share:list()].

%% the lineages in approved datasets, as Beacon filtering terms
-spec filtering_terms() -> [map()].
filtering_terms() ->
    Ls = lists:usort([L || {_, Rows} <- rows(), #{<<"lineage">> := L} <- Rows, is_binary(L), L =/= <<>>]),
    [#{type => <<"alphanumeric">>, id => <<"lineage:", L/binary>>, label => <<"lineage ", L/binary>>, scopes => [<<"genomicVariant">>]}
     || L <- Ls].

%% Query: #{variant => {Ref, Start0, RefBases, AltBases} | none, lineages => [binary()]}; Granularity: boolean | count.
%% {ok, Response} or {error, Why}
-spec query(map(), boolean | count, map()) -> {ok, map()} | {error, binary()}.
query(#{variant := none, lineages := []}, _, _) -> {error, <<"give a variant (referenceName, start, referenceBases, alternateBases) or filters">>};
query(#{variant := V, lineages := Ls} = Q, Granularity, Request) ->
    Mut = case V of
              none -> none;
              {Ref, Start, RB, AB} -> iolist_to_binary([Ref, ":", RB, integer_to_list(Start + 1), AB])
          end,
    Match = fun(#{<<"lineage">> := L} = R) ->
                    (Mut =:= none orelse lists:member(Mut, maps:get(<<"mutations">>, R, [])))
                        andalso lists:all(fun(X) -> X =:= L end, Ls);
               (_) -> false
            end,
    Sets = [{Id, length([R || R <- Rows, Match(R)])} || {Id, Rows} <- rows()],
    Total = lists:sum([N || {_, N} <- Sets]),
    ResultSets = [maps:merge(#{id => Id, setType => <<"dataset">>, exists => N > 0},
                             case Granularity of count -> #{resultsCount => N}; boolean -> #{} end)
                  || {Id, N} <- Sets],
    {ok, #{meta => #{beaconId => maps:get(beacon_id, Request), apiVersion => ?API, returnedGranularity => Granularity,
                     receivedRequestSummary => maps:without([beacon_id], Request#{query => summary(Q)}),
                     returnedSchemas => [#{entityType => <<"genomicVariant">>, schema => <<"beacon-g_variant-v2.0.0">>}]},
           responseSummary => maps:merge(#{exists => Total > 0},
                                         case Granularity of count -> #{numTotalResults => Total}; boolean -> #{} end),
           response => #{resultSets => ResultSets}}}.

summary(#{variant := V, lineages := Ls}) ->
    maps:merge(case V of
                   none -> #{};
                   {Ref, Start, RB, AB} -> #{referenceName => Ref, start => Start, referenceBases => RB, alternateBases => AB}
               end, #{filters => [<<"lineage:", L/binary>> || L <- Ls]}).

%% [{DatasetId, [result row]}] of the approved datasets (their results.json)
rows() ->
    [{Id, json:decode(gh_store:read(H))}
     || #{id := Id, state := approved, files := Fs} <- gh_share:list(), #{name := <<"results.json">>, id := H} <- Fs].
