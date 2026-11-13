%% Task consensus (FS 3.2): a sample's genome from its (dehosted) read pairs: the reads aligned to the chosen
%% reference (minimap2 -ax sr), sorted, and the consensus called by samtools consensus in its simple mode: a base
%% where at least MinDepth reads cover the position and 60% of them agree, N elsewhere; insertions shown, deletions
%% left out. Runs at the lab.
%%   {consensus, R1, R2, RefBundle, Accession, MinDepth} -> #{genome, reference, mean_depth, breadth, n_fraction, length}
-module(gh_consensus).
-behaviour(pq_task).
-export([run/2, describe/1]).

run({consensus, R1, R2, Refs, Acc, MinDepth}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              [Ref, Bam, Cons] = [filename:join(Dir, F) || F <- ["ref.fa", "reads.bam", "consensus.fa"]],
              gh_mutations:reference(Refs, Acc, Home, Ref),
              _ = gh_tool:bash("minimap2 -ax sr -t \"$1\" \"$2\" \"$3\" \"$4\" 2>/dev/null"
                               " | samtools sort -@ 2 -o \"$5\" - 2>/dev/null; samtools index \"$5\"",
                               [integer_to_list(gh_tool:threads()), Ref, gh_store:ensure(R1, Home),
                                gh_store:ensure(R2, Home), Bam]),
              _ = gh_tool:bash("samtools consensus -a -m simple -c 0.6 -d \"$1\" --show-ins yes --show-del no"
                               " -o \"$3\" \"$2\" 2>/dev/null",
                               [integer_to_list(MinDepth), Bam, Cons]),
              Cov = gh_tool:bash("samtools coverage -H \"$1\"", [Bam]),
              [_Name, _S, _E, _Reads, _CovBases, Breadth, Depth | _] = binary:split(hd(binary:split(Cov, <<"\n">>)),
                                                                                    <<"\t">>, [global]),
              {ok, C} = file:read_file(Cons),
              [_Header, Seq0] = binary:split(C, <<"\n">>),
              Seq = binary:replace(Seq0, <<"\n">>, <<>>, [global]),
              Ns = length(binary:matches(Seq, <<"N">>)),
              ok = file:write_file(Cons, [<<">consensus_">>, Acc, <<"\n">>, Seq, <<"\n">>]),
              #{genome => gh_store:move_file(Cons), reference => Acc, length => byte_size(Seq),
                mean_depth => num(Depth), breadth => num(Breadth) / 100,
                n_fraction => Ns / max(1, byte_size(Seq))}
      end).

num(B) ->
    try binary_to_float(B) catch error:badarg -> float(binary_to_integer(B)) end.

describe({consensus, _, _, Refs, Acc, MinDepth}) ->
    #{task => consensus, tools => [minimap2, samtools], refs => Refs, reference => Acc, min_depth => MinDepth}.
