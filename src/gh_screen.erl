%% Task screen: the nearest viral references of a read set (gh2k screen: MinHash of the K-mers seen at least twice),
%% to choose the reference for consensus.
%%   {screen, R1, R2, RefBundle, Top} -> #{reads, bases, hits := [Hit]}, each hit with its taxonomy
-module(gh_screen).
-behaviour(pq_task).
-export([run/2, describe/1]).

run({screen, R1, R2, Refs, Top}, #{home := Home}) ->
    Out = gh_tool:gh2k_must(["screen", gh_refs:file(Refs, "refs.sketch", Home), integer_to_list(Top),
                             gh_store:ensure(R1, Home), gh_store:ensure(R2, Home)]),
    R = json:decode(Out),
    R#{<<"hits">> := [gh_classify:annotate(H, Refs, Home) || H <- maps:get(<<"hits">>, R)]}.

describe({screen, _, _, Refs, Top}) -> #{task => screen, tool => gh2k, refs => Refs, top => Top}.
