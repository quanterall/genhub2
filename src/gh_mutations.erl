%% Task mutations (FS 3.2, 5.1): each genome's mutations against a reference genome (for SARS-CoV-2, Wuhan-Hu-1,
%% NC_045512.2), from its primary alignments by minimap2 -cx asm20 --cs=long (gh_cs).
%%   {mutations, GenomesHash, RefBundle, Accession} -> [#{query, aligned := false} |
%%       #{query, aligned := true, reference, ref_start, ref_end, substitutions, insertions, deletions, missing}]
%%   in the file's order
%% The container form (container/1, result/2, for the federation executor): minimap2 in the genhub2-task image,
%% with the reference genome taken from the bundle here and given as an input; its alignments are read here, as
%% run/2 reads them.
-module(gh_mutations).
-behaviour(pq_task).
-export([run/2, describe/1, reference/4, align/3, ids/1, container/1, result/2]).

-define(MINIMAP2, ["-c", "-x", "asm20", "--cs=long"]).

run({mutations, Genomes, Refs, Acc}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              Ref = filename:join(Dir, "ref.fa"),
              reference(Refs, Acc, Home, Ref),
              G = gh_store:ensure(Genomes, Home),
              of_alignments(align(Ref, G, Dir), Acc, G)
      end).

of_alignments(Best, Acc, G) ->
    [case maps:get(Q, Best, none) of
         none -> #{query => Q, aligned => false};
         {TLen, Segs} ->
             (gh_cs:mutations(Segs, TLen))#{query => Q, aligned => true, reference => Acc,
                                            ref_start => element(1, hd(Segs)) + 1,
                                            ref_end => element(2, lists:last(Segs)), segments => length(Segs)}
     end || Q <- ids(G)].

-spec container(term()) -> map().
container({mutations, Genomes, Refs, Acc}) ->
    Ref = gh_store:with_tmp(fun(Dir) ->
                                    F = filename:join(Dir, "ref.fa"),
                                    reference(Refs, Acc, node(), F),
                                    gh_store:move_file(F)
                            end),
    #{name => <<"viral genome mutations">>,
      description => <<"align viral genomes to their reference genome and call their mutations against it">>,
      inputs => [{<<"/work/in/ref.fa">>, Ref}, {<<"/work/in/genomes.fa">>, Genomes}],
      outputs => [<<"/work/out/aln.paf">>],
      command => [<<"minimap2">> | [list_to_binary(A) || A <- ?MINIMAP2]]
          ++ [<<"-t">>, <<"2">>, <<"-o">>, <<"/work/out/aln.paf">>, <<"/work/in/ref.fa">>, <<"/work/in/genomes.fa">>],
      resources => #{cpu => 2, ram_gb => 2, disk_gb => 1}}.

%% run/2's result from the container's output
-spec result(term(), #{binary() => gh_store:hash()}) -> [map()].
result({mutations, Genomes, _, Acc}, #{<<"/work/out/aln.paf">> := H}) ->
    of_alignments(gh_cs:best(gh_store:read(H)), Acc, gh_store:path(Genomes)).

%% the reference genome Acc of the bundle, written to File
-spec reference(gh_store:hash(), binary(), node(), file:filename()) -> ok.
reference(Refs, Acc, Home, File) ->
    _ = gh_tool:bash("samtools faidx \"$1\" \"$2\" > \"$3\"", [gh_refs:file(Refs, "refs.fasta", Home), Acc, File]),
    ok.

%% gh_cs:best/1 of the genomes aligned to the reference
-spec align(file:filename(), file:filename(), file:filename()) -> map().
align(Ref, Genomes, _Dir) ->
    gh_cs:best(gh_tool:bash("minimap2 " ++ lists:flatten(lists:join(" ", ?MINIMAP2)) ++ " -t \"$1\" \"$2\" \"$3\" 2>/dev/null",
                            [integer_to_list(gh_tool:threads()), Ref, Genomes])).

%% the sequence names (the headers' first words) of a FASTA file, in order
-spec ids(file:filename()) -> [binary()].
ids(Fasta) ->
    {ok, B} = file:read_file(Fasta),
    [hd(binary:split(H, [<<" ">>, <<"\t">>, <<"\r">>])) || <<">", H/binary>> <- binary:split(B, <<"\n">>, [global])].

describe({mutations, _, Refs, Acc}) -> #{task => mutations, tool => minimap2, refs => Refs, reference => Acc}.
