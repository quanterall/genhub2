%% Alignments of genomes to a reference, from minimap2's PAF with the long cs tag (minimap2 -c --cs=long): the cs
%% string spells the alignment along the reference: =ACGT identical bases, *ag reference a where the genome has g,
%% +ag inserted in the genome, -ag deleted from it. From it: the genome's mutations against the reference, and the
%% genome laid out in reference coordinates (insertions dropped, deletions as -, unaligned parts as N) for trees.
%%
%% minimap2 splits a genome's alignment where the genome has long runs of N or diverges strongly, so a genome has
%% one or more primary alignments (tp:A:P); all of them are used, best score first, each kept unless it overlaps
%% the reference range of one kept before it.
-module(gh_cs).
-export([best/1, ops/1, mutations/2, aligned/2]).

-type op() :: {match, binary()} | {sub, byte(), byte()} | {ins, binary()} | {del, binary()}.
-type segment() :: {non_neg_integer(), non_neg_integer(), [op()]}.

%% PAF text -> #{QueryName => {TLen, [{TStart, TEnd, Ops}]}}, the segments in reference order
-spec best(binary()) -> #{binary() => {non_neg_integer(), [segment()]}}.
best(Paf) ->
    Rows = [binary:split(L, <<"\t">>, [global]) || L <- binary:split(Paf, <<"\n">>, [global, trim_all])],
    Prim = [{Q, binary_to_integer(TLen), binary_to_integer(TS), binary_to_integer(TE), score(Tags), Tags}
            || [Q, _QLen, _QS, _QE, _Strand, _T, TLen, TS, TE, _Match, _ALen, _MapQ | Tags] <- Rows,
               lists:member(<<"tp:A:P">>, Tags)],
    ByQ = lists:foldl(fun({Q, _, _, _, _, _} = P, M) -> maps:update_with(Q, fun(L) -> [P | L] end, [P], M) end, #{}, Prim),
    maps:map(fun(_, Ps) ->
                     Sorted = lists:sort(fun({_, _, S1, _, A, _}, {_, _, S2, _, B, _}) -> {A, -S1} >= {B, -S2} end, Ps),
                     Kept = lists:foldl(fun({_, _, TS, TE, _, Tags}, Acc) ->
                                                case [x || {S, E, _} <- Acc, TS < E, S < TE] of
                                                    [] -> [{TS, TE, ops(cs(Tags))} | Acc];
                                                    _ -> Acc
                                                end
                                        end, [], Sorted),
                     {element(2, hd(Ps)), lists:keysort(1, Kept)}
             end, ByQ).

score(Tags) ->
    case [binary_to_integer(V) || <<"AS:i:", V/binary>> <- Tags] of
        [S] -> S;
        [] -> 0
    end.

cs(Tags) ->
    [Cs] = [C || <<"cs:Z:", C/binary>> <- Tags],
    Cs.

-spec ops(binary()) -> [op()].
ops(<<>>) -> [];
ops(<<$=, R/binary>>) -> {S, Rest} = run(R), [{match, S} | ops(Rest)];
ops(<<$*, A, B, R/binary>>) -> [{sub, upper(A), upper(B)} | ops(R)];
ops(<<$+, R/binary>>) -> {S, Rest} = run(R), [{ins, upper_bin(S)} | ops(Rest)];
ops(<<$-, R/binary>>) -> {S, Rest} = run(R), [{del, upper_bin(S)} | ops(Rest)].

run(B) ->
    case binary:match(B, [<<"=">>, <<"*">>, <<"+">>, <<"-">>, <<"~">>]) of
        nomatch -> {B, <<>>};
        {P, _} -> {binary:part(B, 0, P), binary:part(B, P, byte_size(B) - P)}
    end.

upper(C) when C >= $a, C =< $z -> C - 32;
upper(C) -> C.

upper_bin(B) -> << <<(upper(C))>> || <<C>> <= B >>.

%% Mutations against the reference, positions 1-based on it: substitutions [Pos, Ref, Alt] (A/C/G/T only; any other
%% genome base counts as missing), insertions [Pos, Seq] after reference position Pos, deletions [Pos, Length].
-spec mutations([segment()], non_neg_integer()) -> map().
mutations(Segments, _TLen) ->
    Ms = [mut(Ops, TS, [], [], [], 0) || {TS, _TE, Ops} <- Segments],
    #{substitutions => lists:append([S || {S, _, _, _} <- Ms]), insertions => lists:append([I || {_, I, _, _} <- Ms]),
      deletions => lists:append([D || {_, _, D, _} <- Ms]), missing => lists:sum([M || {_, _, _, M} <- Ms])}.

mut([], _T, S, I, D, M) -> {lists:reverse(S), lists:reverse(I), lists:reverse(D), M};
mut([{match, Seq} | R], T, S, I, D, M) -> mut(R, T + byte_size(Seq), S, I, D, M);
mut([{sub, A, B} | R], T, S, I, D, M) ->
    case lists:member(B, "ACGT") of
        true -> mut(R, T + 1, [[T + 1, <<A>>, <<B>>] | S], I, D, M);
        false -> mut(R, T + 1, S, I, D, M + 1)
    end;
mut([{ins, Seq} | R], T, S, I, D, M) -> mut(R, T, S, [[T, Seq] | I], D, M);
mut([{del, Seq} | R], T, S, I, D, M) -> mut(R, T + byte_size(Seq), S, I, [[T + 1, byte_size(Seq)] | D], M).

%% The genome in reference coordinates: TLen bases, N where no segment covers the reference.
-spec aligned([segment()], non_neg_integer()) -> binary().
aligned(Segments, TLen) ->
    {Parts, End} = lists:foldl(fun({TS, TE, Ops}, {Acc, Pos}) ->
                                       {[[binary:copy(<<"N">>, TS - Pos), [al(Op) || Op <- Ops]] | Acc], TE}
                               end, {[], 0}, Segments),
    iolist_to_binary([lists:reverse(Parts), binary:copy(<<"N">>, TLen - End)]).

al({match, S}) -> S;
al({sub, _, B}) -> <<B>>;
al({ins, _}) -> <<>>;
al({del, S}) -> binary:copy(<<"-">>, byte_size(S)).
