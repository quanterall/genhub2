%% Tasks usher_build and usher_place (FS 5.2: placement of a new genome in an existing tree, for surveillance), with
%% UShER (Turakhia et al. 2021, doi:10.1038/s41588-021-00862-7). A mutation-annotated tree (MAT) is built once from
%% a tree of the site's genomes and their substitutions against the reference; new genomes are then placed into it
%% by maximum parsimony in seconds, without rebuilding the tree. With the genomes' lineages as clade labels
%% (matUtils annotate), every placed genome also gets the clade of where it lands.
%%   {usher_build, AlignedHash, NewickHash, [{Sample, Clade}]} -> #{mat}
%%     AlignedHash: gh_tree's alignment in reference coordinates, the reference first; NewickHash: a tree of the
%%     same sequences
%%   {usher_place, GenomesHash, MatHash, RefBundle, Accession} -> [#{query, parsimony, placements, clade}]
-module(gh_usher).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1, vcf/2]).

run({usher_build, Aligned, Newick, Clades}, #{home := Home}) ->
    [{RefName, Ref} | Samples] = records(gh_store:read_from(Aligned, Home)),
    gh_store:with_tmp(
      fun(Dir) ->
              [Vcf, Tree, Mat, Ann, CladeTsv] =
                  [filename:join(Dir, F) || F <- ["samples.vcf", "tree.nwk", "mat.pb", "annotated.pb", "clades.tsv"]],
              ok = file:write_file(Vcf, vcf({RefName, Ref}, [{RefName, Ref} | Samples])),
              ok = file:write_file(Tree, gh_store:read_from(Newick, Home)),
              _ = gh_tool:bash("usher -t \"$1\" -v \"$2\" -o \"$3\" -T \"$4\" -d \"$5\" >/dev/null 2>&1",
                               [Tree, Vcf, Mat, integer_to_list(gh_tool:threads()), filename:join(Dir, "out")]),
              Out = case Clades of
                        [] -> Mat;
                        _ ->
                            ok = file:write_file(CladeTsv, [[C, $\t, S, $\n] || {S, C} <- Clades, C =/= <<>>]),
                            _ = gh_tool:bash("matUtils annotate -i \"$1\" -c \"$2\" -o \"$3\" >/dev/null 2>&1",
                                             [Mat, CladeTsv, Ann]),
                            Ann
                    end,
              #{mat => gh_store:move_file(Out), samples => length(Samples) + 1}
      end);
run({usher_place, Genomes, Mat, Refs, Acc}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              [RefFa, Vcf, OutDir] = [filename:join(Dir, F) || F <- ["ref.fa", "new.vcf", "out"]],
              gh_mutations:reference(Refs, Acc, Home, RefFa),
              {ok, RB} = file:read_file(RefFa),
              [_, R0] = binary:split(RB, <<"\n">>),
              Ref = binary:replace(R0, <<"\n">>, <<>>, [global]),
              G = gh_store:ensure(Genomes, Home),
              Best = gh_mutations:align(RefFa, G, Dir),
              Ids = gh_mutations:ids(G),
              Samples = [{Q, case maps:get(Q, Best, none) of
                                 none -> binary:copy(<<"N">>, byte_size(Ref));
                                 {_, Segs} -> gh_cs:aligned(Segs, byte_size(Ref))
                             end} || Q <- Ids],
              ok = file:write_file(Vcf, vcf({Acc, Ref}, Samples)),
              ok = filelib:ensure_path(OutDir),
              _ = gh_tool:bash("usher -i \"$1\" -v \"$2\" -o \"$3\" -T \"$4\" -d \"$5\" >/dev/null 2>&1",
                               [gh_store:ensure(Mat, Home), Vcf, filename:join(Dir, "placed.pb"),
                                integer_to_list(gh_tool:threads()), OutDir]),
              Stats = tsv(filename:join(OutDir, "placement_stats.tsv")),
              Clades = tsv(filename:join(OutDir, "clades.txt")),
              [#{query => Q,
                 parsimony => case maps:get(Q, Stats, []) of [P | _] -> binary_to_integer(P); _ -> null end,
                 placements => case maps:get(Q, Stats, []) of [_, N | _] -> binary_to_integer(N); _ -> null end,
                 clade => case maps:get(Q, Clades, []) of [C | _] -> C; [] -> <<>> end} || Q <- Ids]
      end).

tsv(F) ->
    case file:read_file(F) of
        {ok, B} -> maps:from_list([{K, Rest} || L <- binary:split(B, <<"\n">>, [global, trim_all]),
                                               [K | Rest] <- [binary:split(L, <<"\t">>, [global])]]);
        {error, _} -> #{}
    end.

records(Fasta) ->
    [begin
         [H | Ls] = binary:split(R, <<"\n">>, [global]),
         {hd(binary:split(H, [<<" ">>, <<"\t">>])), iolist_to_binary(Ls)}
     end || R <- binary:split(Fasta, <<">">>, [global]), R =/= <<>>].

%% A VCF of the samples (sequences in the reference's coordinates) against the reference: a record for every
%% position where a sample has another base A, C, G or T; genotype 0 for the reference base, the allele's number
%% for another, . where the sample has no base (N, gap).
-spec vcf({binary(), binary()}, [{binary(), binary()}]) -> iodata().
vcf({RefName, Ref}, Samples) ->
    L = byte_size(Ref),
    Alts = lists:foldl(fun({_, S}, Acc) -> diffs(Ref, S, 0, L, Acc) end, #{}, Samples),
    Header = ["##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT",
              [[$\t, N] || {N, _} <- Samples], $\n],
    [Header | [begin
                   R = binary:at(Ref, P),
                   As = lists:sort(maps:get(P, Alts)),
                   Gt = fun(B) when B =:= R -> $0;
                           (B) -> case index(B, As, 1) of 0 -> $.; I -> $0 + I end
                        end,
                   [RefName, $\t, integer_to_list(P + 1), "\t.\t", R, $\t, lists:join($,, [[A] || A <- As]),
                    "\t.\t.\t.\tGT", [[$\t, Gt(binary:at(S, P))] || {_, S} <- Samples], $\n]
               end || P <- lists:sort(maps:keys(Alts))]].

diffs(_Ref, _S, I, L, Acc) when I >= L -> Acc;
diffs(Ref, S, I, L, Acc) ->
    B = binary:at(S, I),
    case B =/= binary:at(Ref, I) andalso (B =:= $A orelse B =:= $C orelse B =:= $G orelse B =:= $T) of
        true -> diffs(Ref, S, I + 1, L, maps:update_with(I, fun(As) -> lists:usort([B | As]) end, [B], Acc));
        false -> diffs(Ref, S, I + 1, L, Acc)
    end.

index(_, [], _) -> 0;
index(B, [B | _], I) -> I;
index(B, [_ | T], I) -> index(B, T, I + 1).

resources(_) -> #{cpu => gh_tool:threads()}.

describe({usher_build, _, _, Clades}) -> #{task => usher_build, tool => usher, clades => length(Clades)};
describe({usher_place, _, _, Refs, Acc}) -> #{task => usher_place, tool => usher, refs => Refs, reference => Acc}.
