%% Comparing trees: the Robinson-Foulds distance (Robinson and Foulds 1981, doi:10.1016/0025-5564(81)90043-2) of two
%% unrooted trees on the same leaves, the number of splits (bipartitions of the leaves, one per internal branch) in
%% one tree but not the other. Branches shorter than MinLength are collapsed first: genomes of an outbreak are often
%% identical, and the order in which a program resolves identical genomes is arbitrary, not a difference.
-module(gh_treecmp).
-export([rf/3, splits/2]).

%% #{rf, splits_a, splits_b, normalised}: normalised by the splits of both trees together
-spec rf(binary(), binary(), float()) -> map().
rf(A, B, MinLength) ->
    SA = splits(A, MinLength),
    SB = splits(B, MinLength),
    D = sets:size(sets:subtract(SA, SB)) + sets:size(sets:subtract(SB, SA)),
    Max = sets:size(SA) + sets:size(SB),
    #{rf => D, splits_a => sets:size(SA), splits_b => sets:size(SB),
      normalised => case Max of 0 -> 0.0; _ -> D / Max end}.

%% the non-trivial splits of a tree, each as the sorted leaves on the side without the first leaf (by name)
-spec splits(binary(), float()) -> sets:set([binary()]).
splits(Newick, MinLength) ->
    T = gh_export:newick(Newick),
    All = lists:sort(leaves(T)),
    N = length(All),
    First = hd(All),
    Sides = lists:append([below(K, MinLength) || {node, Kids, _, _} <- [T], K <- Kids]),
    sets:from_list([norm(S, All, First) || S <- Sides, length(S) > 1, length(S) < N - 1], [{version, 2}]).

%% the leaf sets below every branch of the subtree longer than MinLength (its own branch included)
below({node, [], _, _}, _) -> [];
below({node, Kids, _, L} = T, Min) ->
    Inner = lists:append([below(K, Min) || K <- Kids]),
    case L > Min of
        true -> [lists:sort(leaves(T)) | Inner];
        false -> Inner
    end.

leaves({node, [], Name, _}) -> [Name];
leaves({node, Kids, _, _}) -> lists:append([leaves(K) || K <- Kids]).

norm(S, All, First) ->
    case lists:member(First, S) of
        true -> ordsets:subtract(All, S);
        false -> S
    end.
