%% Task classify (FS 5.1): the nearest viral references of each genome (gh2k classify: MinHash distances against the
%% reference bundle's sketches), each with its taxonomy, and a call: the nearest reference's species, genus and
%% family. Confidence from the estimated identity (1 - Mash distance) to the nearest reference: high >= 0.95,
%% medium >= 0.85, low below; no shared hashes with any reference: unclassified. The thresholds are reported with
%% the acceptance test's accuracy per confidence level, not assumed.
%%   {classify, GenomesHash, RefBundle, Top} -> [#{query, length, hits, call}] in the file's order
-module(gh_classify).
-behaviour(pq_task).
-export([run/2, describe/1, annotate/3, call/1]).

run({classify, Genomes, Refs, Top}, #{home := Home}) ->
    Out = gh_tool:gh2k_must(["classify", gh_refs:file(Refs, "refs.sketch", Home), gh_store:ensure(Genomes, Home),
                             integer_to_list(Top)]),
    [begin
         Q = json:decode(L),
         call(Q#{<<"hits">> := [annotate(H, Refs, Home) || H <- maps:get(<<"hits">>, Q)]})
     end || L <- binary:split(Out, <<"\n">>, [global, trim_all])].

-spec annotate(map(), gh_store:hash(), node()) -> map().
annotate(#{<<"ref">> := Acc} = Hit, Refs, Home) ->
    T = gh_refs:taxon(Refs, Acc, Home),
    Hit#{<<"taxid">> => maps:get(taxid, T), <<"species">> => maps:get(species, T),
         <<"genus">> => maps:get(genus, T), <<"family">> => maps:get(family, T),
         <<"organism">> => maps:get(organism, T)}.

-spec call(map()) -> map().
call(#{<<"hits">> := []} = Q) ->
    Q#{<<"call">> => #{<<"confidence">> => <<"unclassified">>}};
call(#{<<"hits">> := [Best | _]} = Q) ->
    Ani = maps:get(<<"ani">>, Best),
    Conf = if Ani >= 0.95 -> <<"high">>; Ani >= 0.85 -> <<"medium">>; true -> <<"low">> end,
    Call = maps:with([<<"species">>, <<"genus">>, <<"family">>, <<"organism">>, <<"taxid">>, <<"ref">>, <<"ani">>], Best),
    Q#{<<"call">> => Call#{<<"confidence">> => Conf}}.

describe({classify, _, Refs, Top}) -> #{task => classify, tool => gh2k, refs => Refs, top => Top}.
