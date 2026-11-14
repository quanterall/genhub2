%% Task dehost (FS 3.2, 3.4): the human reads removed from a clinical sample's read pairs, before anything else sees
%% them. Runs at the lab only: its input is patient data. Two methods, by the host bundle:
%%   host.mmi (gh_refdb:host/1)     a pair is kept only if neither read aligns to the genome of the index (minimap2
%%                                  -ax sr, then samtools fastq -f 12: both unmapped)
%%   hostile/* (gh_refdb:hostile/1) Hostile (Constantinides et al. 2023, doi:10.1093/bioinformatics/btad728) with its
%%                                  index of the T2T human genome and HLA alleles, masked where it resembles RefSeq
%%                                  viruses and phages, so viral reads are not taken for human ones
%%   {dehost, R1, R2, HostBundle} -> #{r1, r2, pairs_in, pairs_kept, method}
-module(gh_dehost).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1]).

run({dehost, R1, R2, Host}, #{home := Home} = Ctx) ->
    case [N || "hostile/" ++ N <- maps:keys(gh_refs:manifest(Host, Home)), lists:suffix(".fa.gz", N)] of
        [Fa] -> hostile(R1, R2, Host, Fa, Ctx);
        [] -> minimap2(R1, R2, Host, Ctx)
    end.

hostile(R1, R2, Host, Fa, #{home := Home}) ->
    Dir0 = gh_refs:dir(Host, Home),
    gh_store:with_tmp(
      fun(Dir) ->
              [I1, I2] = [gh_store:ensure(R, Home) || R <- [R1, R2]],
              _ = gh_tool:bash("XDG_DATA_HOME=\"$1\" hostile clean --fastq1 \"$2\" --fastq2 \"$3\" --aligner minimap2"
                               " --index \"$4\" --airplane --reorder --threads \"$5\" --output \"$6\" >/dev/null",
                               [filename:absname(Dir0), I1, I2, filename:basename(Fa, ".fa.gz"),
                                integer_to_list(gh_tool:threads()), Dir]),
              [C1] = filelib:wildcard(filename:join(Dir, "*.clean_1.fastq.gz")),
              [C2] = filelib:wildcard(filename:join(Dir, "*.clean_2.fastq.gz")),
              [O1, O2] = [filename:join(Dir, F) || F <- ["kept.R1.fastq", "kept.R2.fastq"]],
              _ = gh_tool:bash("gzip -dc \"$1\" > \"$2\"; gzip -dc \"$3\" > \"$4\"", [C1, O1, C2, O2]),
              {In, Kept} = {gh_fastq:count(I1), gh_fastq:count(O1)},
              #{r1 => gh_store:move_file(O1), r2 => gh_store:move_file(O2), pairs_in => In, pairs_kept => Kept,
                method => hostile}
      end).

minimap2(R1, R2, Host, #{home := Home}) ->
    Index = gh_refs:file(Host, "host.mmi", Home),
    gh_store:with_tmp(
      fun(Dir) ->
              [O1, O2] = [filename:join(Dir, F) || F <- ["kept.R1.fastq", "kept.R2.fastq"]],
              _ = gh_tool:bash("minimap2 -ax sr -t \"$1\" \"$2\" \"$3\" \"$4\" 2>/dev/null"
                               " | samtools fastq -f 12 -F 256 -1 \"$5\" -2 \"$6\" -0 /dev/null -s /dev/null - 2>/dev/null",
                               [integer_to_list(gh_tool:threads()), Index, gh_store:ensure(R1, Home),
                                gh_store:ensure(R2, Home), O1, O2]),
              In = gh_fastq:count(gh_store:ensure(R1, Home)),
              Kept = gh_fastq:count(O1),
              #{r1 => gh_store:move_file(O1), r2 => gh_store:move_file(O2), pairs_in => In, pairs_kept => Kept,
                method => minimap2}
      end).

resources({dehost, _, _, Host}) -> #{cpu => gh_tool:threads(), memory_mb => 12000, data => [Host], site_only => true}.

describe({dehost, _, _, Host}) -> #{task => dehost, tools => [minimap2, samtools, hostile], host => Host}.
