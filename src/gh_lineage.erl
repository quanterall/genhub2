%% Task lineage (FS 5.1): clades and lineages of genomes, with Nextclade's own mutation calls and quality status, by
%% Nextclade (Aksamentov et al. 2021, doi:10.21105/joss.03773). A bundle of several datasets (gh_refdb:
%% nextclade_datasets/0) holds Nextclade's minimizer index: nextclade sort sends each genome to the dataset it matches
%% best (SARS-CoV-2, influenza HA, RSV A and B, mpox, measles, ...), and each dataset runs on its genomes. A bundle of
%% one dataset (gh_refdb:nextclade/1) runs that dataset on every genome.
%%   {lineage, GenomesHash, DatasetBundle} -> [#{query, dataset, clade, pango, qc, substitutions, aa_substitutions,
%%                                              aa_deletions, total_missing}]
%%   in the file's order; a genome no dataset matches has dataset <<>> and nothing else
-module(gh_lineage).
-behaviour(pq_task).
-export([run/2, describe/1]).

run({lineage, Genomes, Bundle}, #{home := Home}) ->
    G = gh_store:ensure(Genomes, Home),
    Manifest = gh_refs:manifest(Bundle, Home),
    gh_store:with_tmp(
      fun(Dir) ->
              Rows = case is_map_key("minimizer_index.json", Manifest) of
                         false -> run_dataset(gh_refs:file(Bundle, "dataset.zip", Home), G, Dir, <<>>);
                         true -> sorted(Bundle, Home, G, Dir)
                     end,
              ByQ = maps:from_list([{maps:get(query, R), R} || R <- Rows]),
              [maps:get(Q, ByQ, #{query => Q, dataset => <<>>}) || Q <- gh_mutations:ids(G)]
      end).

%% genomes sent to their datasets by nextclade sort, each dataset run on its own
sorted(Bundle, Home, G, Dir) ->
    Sort = filename:join(Dir, "sort.tsv"),
    %% --all-matches: sort's best match is often a dataset the bundle does not hold (e.g. sars-cov-2/BA.2.86); the
    %% best-scoring match the bundle holds is used
    _ = gh_tool:bash("nextclade sort --all-matches -m \"$1\" --output-results-tsv \"$2\" \"$3\" >/dev/null",
                     [gh_refs:file(Bundle, "minimizer_index.json", Home), Sort, G]),
    {ok, Ds} = file:read_file(gh_refs:file(Bundle, "datasets.tsv", Home)),
    Files = maps:from_list([{N, F} || L <- binary:split(Ds, <<"\n">>, [global, trim_all]), binary:first(L) =/= $#,
                                      [N, _Tag, F] <- [binary:split(L, <<"\t">>, [global])]]),
    Best = lists:foldl(fun(#{<<"seqName">> := S, <<"dataset">> := D, <<"score">> := Sc}, M) when D =/= <<>> ->
                               Q = first_word(S),
                               Score = num(Sc),
                               case is_map_key(D, Files) andalso Score > element(1, maps:get(Q, M, {-1.0, none})) of
                                   true -> M#{Q => {Score, D}};
                                   false -> M
                               end;
                          (_, M) -> M
                       end, #{}, tsv_maps(Sort)),
    ByDataset = maps:groups_from_list(fun({_, {_, D}}) -> D end, fun({Q, _}) -> Q end, maps:to_list(Best)),
    lists:append([begin
                      Sub = filename:join(Dir, binary_to_list(maps:get(D, Files)) ++ ".fa"),
                      ok = file:write_file(Sub, [[<<">">>, Id, string:trim(R, trailing, "\n"), <<"\n">>]
                                                 || {Id, R} <- gh_fasta:records(G), lists:member(Id, Qs)]),
                      run_dataset(gh_refs:file(Bundle, binary_to_list(maps:get(D, Files)), Home), Sub, Dir, D)
                  end || {D, Qs} <- maps:to_list(ByDataset)]).

run_dataset(Zip, Fasta, Dir, Name) ->
    Tsv = filename:join(Dir, "nextclade-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tsv"),
    _ = gh_tool:bash("nextclade run --in-order -j \"$1\" --input-dataset \"$2\" --output-tsv \"$3\" \"$4\""
                     " >/dev/null",
                     [integer_to_list(gh_tool:threads()), Zip, Tsv, Fasta]),
    [row(M, Name) || M <- tsv_maps(Tsv)].

tsv_maps(F) ->
    {ok, B} = file:read_file(F),
    case [binary:split(L, <<"\t">>, [global]) || L <- binary:split(B, <<"\n">>, [global, trim_all])] of
        [] -> [];
        [Header | Rows] -> [maps:from_list(lists:zip(Header, R ++ lists:duplicate(max(0, length(Header) - length(R)), <<>>), trim))
                            || R <- Rows]
    end.

row(M, Dataset) ->
    G = fun(K) -> maps:get(K, M, <<>>) end,
    #{query => first_word(G(<<"seqName">>)), dataset => Dataset, clade => G(<<"clade">>),
      pango => G(<<"Nextclade_pango">>), qc => G(<<"qc.overallStatus">>), total_missing => G(<<"totalMissing">>),
      substitutions => list(G(<<"substitutions">>)),
      %% amino-acid changes, as Nextclade writes them (S:N501Y; deletions S:H69-): what the structure viewer shows
      aa_substitutions => list(G(<<"aaSubstitutions">>)), aa_deletions => list(G(<<"aaDeletions">>))}.

list(B) -> [S || S <- binary:split(B, <<",">>, [global]), S =/= <<>>].

first_word(S) -> hd(binary:split(S, [<<" ">>, <<"\t">>])).

num(<<>>) -> 0.0;
num(B) -> try binary_to_float(B) catch error:badarg -> float(binary_to_integer(B)) end.

describe({lineage, _, Dataset}) -> #{task => lineage, tool => nextclade, dataset => Dataset}.
