%% Task dehost (FS 3.2, 3.4): the human reads removed from a clinical sample's read pairs, before anything else sees
%% them. A pair is kept only if neither read aligns to the human genome (minimap2 -ax sr against the host bundle's
%% index, then samtools fastq -f 12: both unmapped). Runs at the lab only: its input is patient data.
%%   {dehost, R1, R2, HostBundle} -> #{r1, r2, pairs_in, pairs_kept}
-module(gh_dehost).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1]).

run({dehost, R1, R2, Host}, #{home := Home}) ->
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
              #{r1 => gh_store:move_file(O1), r2 => gh_store:move_file(O2), pairs_in => In, pairs_kept => Kept}
      end).

resources({dehost, _, _, Host}) -> #{cpu => gh_tool:threads(), memory_mb => 12000, data => [Host], site_only => true}.

describe({dehost, _, _, Host}) -> #{task => dehost, tools => [minimap2, samtools], host => Host}.
