%% Task tree (FS 5.2): a phylogenetic tree of genomes. Each genome is aligned to the reference genome (minimap2
%% asm20, gh_cs) and laid out in its coordinates, the reference first; then neighbour-joining on Jukes-Cantor
%% distances (gh2k nj, Apache 2.0) or approximate maximum likelihood (FastTreeMP -nt -gtr, GPL, as a separate
%% program; Price et al. 2010, doi:10.1371/journal.pone.0009490), or the same by VeryFastTree, its parallel
%% reimplementation (GPL, a separate program; Piñeiro et al. 2020, doi:10.1093/gigascience/giaa055).
%%   {tree, GenomesHash, RefBundle, Accession, nj | fasttree | veryfasttree} -> #{newick, aligned, sequences, columns}
%%   {ml, AlignedHash, fasttree | veryfasttree} -> the same, from an alignment made by gh_phylo's align tasks
%% (Tree jobs spread their work over gh_phylo's tasks; the first form does it all in one task.)
-module(gh_tree).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1, aligned_rows/5]).

run({tree, Genomes, Refs, Acc, Method}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              [Aligned, Tree] = [filename:join(Dir, F) || F <- ["aligned.fa", "tree.nwk"]],
              {Rows, N, TLen} = aligned_rows(gh_store:ensure(Genomes, Home), Refs, Acc, Home, Dir),
              ok = file:write_file(Aligned, Rows),
              case Method of
                  nj -> ok = file:write_file(Tree, gh_tool:gh2k_must(["nj", Aligned]));
                  _ -> ml(Method, Aligned, Tree)
              end,
              #{newick => gh_store:move_file(Tree), aligned => gh_store:move_file(Aligned),
                sequences => N + 1, columns => TLen, method => Method}
      end);
run({ml, AlignedHash, Method}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              Aligned = gh_store:ensure(AlignedHash, Home),
              Tree = filename:join(Dir, "tree.nwk"),
              ml(Method, Aligned, Tree),
              {N, Columns} = gh_phylo:shape(Aligned),
              #{newick => gh_store:move_file(Tree), aligned => AlignedHash, sequences => N, columns => Columns,
                method => Method}
      end).

ml(fasttree, Aligned, Tree) ->
    <<>> = gh_tool:bash("OMP_NUM_THREADS=\"$3\" fasttreeMP -nt -gtr -quiet -nopr \"$1\" > \"$2\"",
                        [Aligned, Tree, integer_to_list(tree_threads())]), ok;
ml(veryfasttree, Aligned, Tree) ->
    <<>> = gh_tool:bash("VeryFastTree -nt -gtr -quiet -nopr -threads \"$3\" \"$1\" > \"$2\"",
                        [Aligned, Tree, integer_to_list(tree_threads())]), ok.

%% The genomes of the FASTA file Genomes aligned to the reference genome Acc and laid out in its coordinates, a
%% genome that does not align being all N: {Rows, NumberOfGenomes, Columns}, Rows in FASTA, the reference's record
%% first.
-spec aligned_rows(file:filename(), gh_store:hash(), binary(), node(), file:filename()) ->
          {iodata(), non_neg_integer(), non_neg_integer()}.
aligned_rows(Genomes, Refs, Acc, Home, Dir) ->
    Ref = filename:join(Dir, "ref.fa"),
    gh_mutations:reference(Refs, Acc, Home, Ref),
    Best = gh_mutations:align(Ref, Genomes, Dir),
    {ok, RefFa} = file:read_file(Ref),
    [_, RefSeq0] = binary:split(RefFa, <<"\n">>),
    RefSeq = binary:replace(RefSeq0, <<"\n">>, <<>>, [global]),
    TLen = byte_size(RefSeq),
    Ids = gh_mutations:ids(Genomes),
    Rows = [[<<">">>, Acc, <<"\n">>, RefSeq, <<"\n">>]
            | [[<<">">>, Q, <<"\n">>,
                case maps:get(Q, Best, none) of
                    none -> binary:copy(<<"N">>, TLen);
                    {_, Segs} -> gh_cs:aligned(Segs, TLen)
                end, <<"\n">>] || Q <- Ids]],
    {Rows, length(Ids), TLen}.

%% FastTreeMP's threads: every scheduler of the node (a tree is one task, the largest of phase A)
tree_threads() -> erlang:system_info(schedulers_online).

resources({tree, _, _, _, M}) when M =:= fasttree; M =:= veryfasttree -> #{cpu => tree_threads()};
resources({tree, _, _, _, nj}) -> #{cpu => 1};
resources({ml, _, _}) -> #{cpu => tree_threads()}.

describe({tree, _, Refs, Acc, Method}) ->
    #{task => tree, tools => [minimap2, case Method of nj -> gh2k; fasttree -> fasttree_mp; veryfasttree -> veryfasttree end], refs => Refs,
      reference => Acc};
describe({ml, _, Method}) ->
    #{task => tree, tools => [case Method of fasttree -> fasttree_mp; veryfasttree -> veryfasttree end]}.
