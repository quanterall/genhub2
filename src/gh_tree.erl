%% Task tree (FS 5.2): a phylogenetic tree of genomes. Each genome is aligned to the reference genome (minimap2
%% asm20, gh_cs) and laid out in its coordinates, the reference first; then neighbour-joining on Jukes-Cantor
%% distances (gh2k nj, Apache 2.0) or approximate maximum likelihood (FastTreeMP -nt -gtr, GPL, as a separate
%% program; Price et al. 2010, doi:10.1371/journal.pone.0009490), or the same by VeryFastTree, its parallel
%% reimplementation (GPL, a separate program; Piñeiro et al. 2020, doi:10.1093/gigascience/giaa055).
%%   {tree, GenomesHash, RefBundle, Accession, nj | fasttree | veryfasttree} -> #{newick, aligned, sequences, columns}
-module(gh_tree).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1]).

run({tree, Genomes, Refs, Acc, Method}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              [Ref, Aligned, Tree] = [filename:join(Dir, F) || F <- ["ref.fa", "aligned.fa", "tree.nwk"]],
              gh_mutations:reference(Refs, Acc, Home, Ref),
              G = gh_store:ensure(Genomes, Home),
              Best = gh_mutations:align(Ref, G, Dir),
              {ok, RefFa} = file:read_file(Ref),
              [_, RefSeq0] = binary:split(RefFa, <<"\n">>),
              RefSeq = binary:replace(RefSeq0, <<"\n">>, <<>>, [global]),
              TLen = byte_size(RefSeq),
              Ids = gh_mutations:ids(G),
              Rows = [[<<">">>, Acc, <<"\n">>, RefSeq, <<"\n">>]
                      | [[<<">">>, Q, <<"\n">>,
                          case maps:get(Q, Best, none) of
                              none -> binary:copy(<<"N">>, TLen);
                              {_, Segs} -> gh_cs:aligned(Segs, TLen)
                          end, <<"\n">>] || Q <- Ids]],
              ok = file:write_file(Aligned, Rows),
              case Method of
                  nj -> ok = file:write_file(Tree, gh_tool:gh2k_must(["nj", Aligned]));
                  fasttree -> <<>> = gh_tool:bash("OMP_NUM_THREADS=\"$3\" fasttreeMP -nt -gtr -quiet -nopr \"$1\" > \"$2\"",
                                               [Aligned, Tree, integer_to_list(tree_threads())]), ok;
                  veryfasttree -> <<>> = gh_tool:bash("VeryFastTree -nt -gtr -quiet -nopr -threads \"$3\" \"$1\" > \"$2\"",
                                                   [Aligned, Tree, integer_to_list(tree_threads())]), ok
              end,
              #{newick => gh_store:move_file(Tree), aligned => gh_store:move_file(Aligned),
                sequences => length(Ids) + 1, columns => TLen, method => Method}
      end).

%% FastTreeMP's threads: every scheduler of the node (a tree is one task, the largest of phase A)
tree_threads() -> erlang:system_info(schedulers_online).

resources({tree, _, _, _, M}) when M =:= fasttree; M =:= veryfasttree -> #{cpu => tree_threads()};
resources({tree, _, _, _, nj}) -> #{cpu => 1}.

describe({tree, _, Refs, Acc, Method}) ->
    #{task => tree, tools => [minimap2, case Method of nj -> gh2k; fasttree -> fasttree_mp; veryfasttree -> veryfasttree end], refs => Refs,
      reference => Acc}.
