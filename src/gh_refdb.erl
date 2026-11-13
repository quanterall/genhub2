%% Building the reference bundles of phase A (gh_refs), each once per site: its hash is kept in
%% <data_dir>/bundles/<name>, and the bundle itself is in the store.
%%
%%   refseq_viral()      every complete viral genome in NCBI RefSeq (NCBI Datasets, taxon 10239, RefSeq only,
%%                       complete only), with each one's species, genus and family from NCBI Taxonomy, and its
%%                       MinHash sketches (K = 21, S = 1,000, Mash's defaults)
%%   host(MinimapIndex)  the human genome's minimap2 index (-x sr), for dehost
%%   nextclade(Tag)      Nextclade's SARS-CoV-2 dataset at a pinned tag
%%   genomes(Accs, Dir)  (for tests) the GenBank genomes with these accessions: a FASTA file and their taxonomy
-module(gh_refdb).
-export([refseq_viral/0, host/1, nextclade/1, genomes/2, named/2, taxonomy_tsv/2]).

-define(K, "21").
-define(S, "1000").

%% the bundle saved under Name, or Build()'s, saved
-spec named(string(), fun(() -> gh_store:hash())) -> gh_store:hash().
named(Name, Build) ->
    F = filename:join([application:get_env(genhub2, data_dir, "data"), "bundles", Name]),
    case file:read_file(F) of
        {ok, H} -> string:trim(H);
        {error, enoent} ->
            H = Build(),
            ok = filelib:ensure_dir(F),
            ok = file:write_file(F, H),
            H
    end.

-spec refseq_viral() -> gh_store:hash().
refseq_viral() ->
    named("refseq_viral", fun() ->
        Url = gh_ncbi:genome_download_url("10239", #{"refseq_only" => "true", "complete_only" => "true"}),
        #{hash := Zip} = gh_fetch:run({fetch_public, Url}, #{home => node()}),
        gh_store:with_tmp(fun(Dir) ->
            [Fasta, Reports, Tax, Sketch] = [filename:join(Dir, F) || F <- ["refs.fasta", "reports.jsonl",
                                                                             "taxonomy.tsv", "refs.sketch"]],
            unzip(gh_store:path(Zip), Fasta, Reports),
            taxonomy_tsv(Reports, Tax),
            _ = gh_tool:bash("samtools faidx \"$1\"", [Fasta]),
            _ = gh_tool:gh2k_must(["sketch", ?K, ?S, Fasta, Sketch]),
            gh_refs:bundle(#{"refs.fasta" => Fasta, "refs.fasta.fai" => Fasta ++ ".fai", "refs.sketch" => Sketch,
                             "taxonomy.tsv" => Tax, "ncbi_dataset.zip" => gh_store:path(Zip)})
        end)
    end).

-spec host(file:filename()) -> gh_store:hash().
host(MinimapIndex) ->
    named("host", fun() -> gh_refs:bundle(#{"host.mmi" => MinimapIndex}) end).

-spec nextclade(string()) -> gh_store:hash().
nextclade(Tag) ->
    named("nextclade-sars-cov-2-" ++ Tag, fun() ->
        gh_store:with_tmp(fun(Dir) ->
            Zip = filename:join(Dir, "dataset.zip"),
            _ = gh_tool:bash("nextclade dataset get --name nextstrain/sars-cov-2/wuhan-hu-1/orfs --tag \"$1\""
                             " --output-zip \"$2\" >/dev/null 2>&1", [Tag, Zip]),
            filelib:file_size(Zip) > 0 orelse error({empty_download, nextclade, Tag}),
            gh_refs:bundle(#{"dataset.zip" => Zip})
        end)
    end).

%% The genomes with these accessions, downloaded 100 at a time, into Dir: {FASTA, taxonomy TSV}.
-spec genomes([binary()], file:filename()) -> {file:filename(), file:filename()}.
genomes(Accs, Dir) ->
    [Fasta, Reports, Tax] = [filename:join(Dir, F) || F <- ["genomes.fasta", "reports.jsonl", "taxonomy.tsv"]],
    ok = file:write_file(Fasta, <<>>),
    ok = file:write_file(Reports, <<>>),
    lists:foreach(
      fun(Batch) ->
              #{hash := Zip} = gh_fetch:run({fetch_public, gh_ncbi:accession_download_url(Batch)}, #{home => node()}),
              _ = gh_tool:bash("unzip -p \"$1\" ncbi_dataset/data/genomic.fna >> \"$2\"; "
                               "unzip -p \"$1\" ncbi_dataset/data/data_report.jsonl >> \"$3\"",
                               [gh_store:path(Zip), Fasta, Reports])
      end, chunks(Accs, 100)),
    taxonomy_tsv(Reports, Tax),
    {Fasta, Tax}.

unzip(Zip, Fasta, Reports) ->
    _ = gh_tool:bash("unzip -p \"$1\" ncbi_dataset/data/genomic.fna > \"$2\"; "
                     "unzip -p \"$1\" ncbi_dataset/data/data_report.jsonl > \"$3\"", [Zip, Fasta, Reports]),
    ok.

%% NCBI Datasets' data_report.jsonl -> TSV: accession, taxid, species, genus, family, organism
-spec taxonomy_tsv(file:filename(), file:filename()) -> ok.
taxonomy_tsv(Reports, Out) ->
    {ok, B} = file:read_file(Reports),
    Recs = [begin
                R = json:decode(L),
                V = maps:get(<<"virus">>, R),
                {maps:get(<<"accession">>, R), maps:get(<<"taxId">>, V), maps:get(<<"organismName">>, V, <<>>)}
            end || L <- binary:split(B, <<"\n">>, [global, trim_all])],
    Tax = gh_ncbi:taxonomy([T || {_, T, _} <- Recs]),
    Rows = [begin
                X = maps:get(T, Tax, #{species => <<>>, genus => <<>>, family => <<>>}),
                lists:join(<<"\t">>, [A, integer_to_binary(T), clean(maps:get(species, X)), clean(maps:get(genus, X)),
                                      clean(maps:get(family, X)), clean(O)]) ++ [<<"\n">>]
            end || {A, T, O} <- Recs],
    file:write_file(Out, [<<"#accession\ttaxid\tspecies\tgenus\tfamily\torganism\n">> | Rows]).

clean(B) -> binary:replace(B, [<<"\t">>, <<"\n">>, <<"\r">>], <<" ">>, [global]).

chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].
