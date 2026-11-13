%% Task lineage (FS 5.1): clade and Pango lineage of SARS-CoV-2 genomes, and Nextclade's own mutation calls and
%% quality status, by Nextclade (Aksamentov et al. 2021, doi:10.21105/joss.03773) with a pinned dataset bundle.
%%   {lineage, GenomesHash, DatasetBundle} -> [#{query, clade, pango, qc, substitutions, total_missing}] in order
-module(gh_lineage).
-behaviour(pq_task).
-export([run/2, describe/1]).

run({lineage, Genomes, Dataset}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              Tsv = filename:join(Dir, "nextclade.tsv"),
              _ = gh_tool:bash("nextclade run --in-order -j \"$1\" --input-dataset \"$2\" --output-tsv \"$3\" \"$4\""
                               " >/dev/null",
                               [integer_to_list(gh_tool:threads()), gh_refs:file(Dataset, "dataset.zip", Home), Tsv,
                                gh_store:ensure(Genomes, Home)]),
              {ok, B} = file:read_file(Tsv),
              [Header | Rows] = [binary:split(L, <<"\t">>, [global]) || L <- binary:split(B, <<"\n">>, [global, trim_all])],
              [row(maps:from_list(lists:zip(Header, R, trim))) || R <- Rows]
      end).

row(M) ->
    G = fun(K) -> maps:get(K, M, <<>>) end,
    #{query => hd(binary:split(G(<<"seqName">>), [<<" ">>, <<"\t">>])), clade => G(<<"clade">>), pango => G(<<"Nextclade_pango">>),
      qc => G(<<"qc.overallStatus">>), total_missing => G(<<"totalMissing">>),
      substitutions => [S || S <- binary:split(G(<<"substitutions">>), <<",">>, [global]), S =/= <<>>]}.

describe({lineage, _, Dataset}) -> #{task => lineage, tool => nextclade, dataset => Dataset}.
