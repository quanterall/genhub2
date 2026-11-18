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
-export([check_update/0, apply_update/0, usher_sars_cov_2/3, refseq_viral/0, viral_proteins/0, host/1, hostile/1, primers/2, kraken/1, nextclade/1,
         nextclade_datasets/0, genomes/2, named/2, taxonomy_tsv/2]).

%% Nextclade datasets for the viruses Bulgarian labs see most, besides SARS-CoV-2 (its tag pinned in nextclade/1)
-define(NEXTCLADE_DATASETS,
        ["nextstrain/flu/h1n1pdm/ha/MW626062", "nextstrain/flu/h1n1pdm/ha/CY121680", "nextstrain/flu/h3n2/ha/EPI1857216",
         "nextstrain/flu/h3n2/ha/CY163680", "nextstrain/flu/vic/ha/KX058884", "nextstrain/flu/b/ha/KX058884",
         "nextstrain/flu/yam/ha/JN993010", "nextstrain/rsv/a/EPI_ISL_412866", "nextstrain/rsv/b/EPI_ISL_1653999",
         "nextstrain/mpox/all-clades", "nextstrain/orthoebolavirus/ebov", "nextstrain/measles/genome/WHO-2012",
         "nextstrain/dengue/all", "nextstrain/hmpv/all-clades/NC_039199", "nextstrain/rubella/genome",
         "nextstrain/mumps/genome", "nextstrain/wnv/all-lineages",
         %% dengue: nextclade sort matches the serotype datasets of the community collection
         "community/v-gen-lab/dengue/denv1", "community/v-gen-lab/dengue/denv2", "community/v-gen-lab/dengue/denv3",
         "community/v-gen-lab/dengue/denv4"]).

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

%% The site's mutation-annotated tree of SARS-CoV-2 (gh_usher), for placing new genomes (pipeline step place): a
%% neighbour-joining tree of the genomes of the FASTA file Genomes against Wuhan-Hu-1, each labelled with its Nextclade
%% lineage, built once and kept as usher-sars-cov-2. Its hash is the setting usher_tree (gh_config).
-spec usher_sars_cov_2(gh_store:hash(), gh_store:hash(), gh_store:hash()) -> gh_store:hash().
usher_sars_cov_2(Genomes, Refs, Nextclade) ->
    named("usher-sars-cov-2",
          fun() ->
                  Run = fun(T) -> pq_task:run(T, node()) end,
                  #{newick := Nwk, aligned := Al} = Run({pq_task, gh_tree, {tree, Genomes, Refs, <<"NC_045512.2">>, nj}}),
                  Lineages = Run({pq_task, gh_lineage, {lineage, Genomes, Nextclade}}),
                  Clades = [{Q, P} || #{query := Q, pango := P} <- Lineages, P =/= <<>>],
                  #{mat := Mat} = Run({pq_task, gh_usher, {usher_build, Al, Nwk, Clades}}),
                  Mat
          end).

-spec refseq_viral() -> gh_store:hash().
refseq_viral() ->
    named("refseq_viral", fun() -> build_refseq_viral(gh_fetch:cached(refseq_url())) end).

refseq_url() -> gh_ncbi:genome_download_url("10239", #{"refseq_only" => "true", "complete_only" => "true"}).

proteins_url() -> lists:flatten(string:replace(refseq_url(), "include_sequence=GENOME", "include_sequence=PROTEIN")).

%% the RefSeq bundle of an NCBI Datasets download (in the store)
build_refseq_viral(Zip) ->
        gh_store:with_tmp(fun(Dir) ->
            [Fasta, Reports, Tax, Sketch] = [filename:join(Dir, F) || F <- ["refs.fasta", "reports.jsonl",
                                                                             "taxonomy.tsv", "refs.sketch"]],
            unzip(gh_store:path(Zip), Fasta, Reports),
            taxonomy_tsv(Reports, Tax),
            _ = gh_tool:bash("samtools faidx \"$1\"", [Fasta]),
            _ = gh_tool:gh2k_must(["sketch", ?K, ?S, Fasta, Sketch]),
            gh_refs:bundle(#{"refs.fasta" => Fasta, "refs.fasta.fai" => Fasta ++ ".fai", "refs.sketch" => Sketch,
                             "taxonomy.tsv" => Tax, "ncbi_dataset.zip" => gh_store:path(Zip)})
        end).

%% Every protein of the complete RefSeq viral genomes, as a DIAMOND database (proteins.dmnd), and each protein's
%% taxonomy (proteins.tsv: protein, taxid, species, genus, family, organism), from its organism's entry in the
%% RefSeq bundle's taxonomy.
-spec viral_proteins() -> gh_store:hash().
viral_proteins() ->
    named("refseq_viral_proteins", fun() -> build_viral_proteins(refseq_viral(), gh_fetch:cached(proteins_url())) end).

%% the protein bundle of an NCBI Datasets protein download, its proteins labelled from the RefSeq bundle Refs
build_viral_proteins(Refs, Zip) ->
        ByOrganism = maps:from_list([{maps:get(organism, T), T} || T <- maps:values(gh_refs:taxonomy(Refs, node()))]),
        gh_store:with_tmp(fun(Dir) ->
            [Faa, Tsv, Db] = [filename:join(Dir, F) || F <- ["proteins.faa", "proteins.tsv", "proteins"]],
            _ = gh_tool:bash("unzip -p \"$1\" ncbi_dataset/data/protein.faa > \"$2\"", [gh_store:path(Zip), Faa]),
            {ok, B0} = file:read_file(Faa),
            %% For genes without a protein record (e.g. the rabies and Zaire ebolavirus RefSeq genomes), NCBI's
            %% protein file holds the coding sequence itself (a header "<genome>:<range> CDS: ..."): those are
            %% translated here (standard code), and listed in translated.txt
            Recs = [R || R <- binary:split(B0, <<"\n>">>, [global]), R =/= <<>>],
            {Prot, Nuc} = lists:partition(fun protein_letters/1, Recs),
            Fix = fun(R) -> case R of <<">", X/binary>> -> X; X -> X end end,
            B = iolist_to_binary([[$>, Fix(R), $\n] || R <- Prot]
                                 ++ [begin
                                         [H | Ls] = binary:split(Fix(R), <<"\n">>, [global]),
                                         [$>, H, $\n, translate(iolist_to_binary(Ls)), $\n]
                                     end || R <- Nuc]),
            ok = file:write_file(Faa, B),
            ok = file:write_file(filename:join(Dir, "translated.txt"),
                                 [[hd(binary:split(Fix(R), <<"\n">>)), $\n] || R <- Nuc]),
            Rows = [begin
                        [Acc | _] = binary:split(H, [<<" ">>]),
                        Org = case re:run(H, "\\[organism=([^\\]]*)\\]", [{capture, [1], binary}]) of
                                  {match, [O]} -> O;
                                  nomatch -> <<>>
                              end,
                        T = maps:get(Org, ByOrganism, #{taxid => 0, species => <<>>, genus => <<>>, family => <<>>}),
                        [Acc, $\t, integer_to_binary(maps:get(taxid, T)), $\t, maps:get(species, T), $\t,
                         maps:get(genus, T), $\t, maps:get(family, T), $\t, Org, $\n]
                    end || <<">", H/binary>> <- binary:split(B, <<"\n">>, [global])],
            ok = file:write_file(Tsv, [<<"#accession\ttaxid\tspecies\tgenus\tfamily\torganism\n">> | Rows]),
            _ = gh_tool:bash("diamond makedb --quiet --in \"$1\" -d \"$2\"", [Faa, Db]),
            gh_refs:bundle(#{"proteins.dmnd" => Db ++ ".dmnd", "taxonomy.tsv" => Tsv,
                             "translated.txt" => filename:join(Dir, "translated.txt")})
        end).

%%% updates of the reference data from NCBI (FS 3.3: public data, fetched and cached; plan phase E)

%% Downloads NCBI's current RefSeq viral genomes (not from the cache). The same download as the site's bundle:
%% unchanged. A new download whose references, taxonomy and sequences are all the same (NCBI's archive changes with
%% its metadata): unchanged as well, and nothing is staged, so results keep naming the same bundle. Otherwise the new
%% bundle is saved as refseq_viral.next, with a report (refseq_viral.next.json) of what changed.
%% {changed, Report} | unchanged | {unchanged, same_content}
-spec check_update() -> unchanged | {unchanged, same_content} | {changed, map()}.
check_update() ->
    Current = current("refseq_viral"),
    #{hash := Zip} = gh_fetch:run({fetch_public, refseq_url()}, #{}),
    case maps:get("ncbi_dataset.zip", gh_refs:manifest(Current, node())) of
        Zip -> unchanged;
        _ ->
            New = build_refseq_viral(Zip),
            Old = gh_refs:taxonomy(Current, node()),
            Now = gh_refs:taxonomy(New, node()),
            Changed = [A || {A, T} <- maps:to_list(Now), is_map_key(A, Old), maps:get(A, Old) =/= T],
            SeqOld = gh_fasta:seq_hashes(gh_refs:file(Current, "refs.fasta", node())),
            SeqNew = gh_fasta:seq_hashes(gh_refs:file(New, "refs.fasta", node())),
            SeqChanged = [A || {A, H} <- maps:to_list(SeqNew), is_map_key(A, SeqOld), maps:get(A, SeqOld) =/= H],
            Report = #{current => Current, next => New, checked => erlang:system_time(millisecond),
                       references => #{current => maps:size(Old), next => maps:size(Now)},
                       added => lists:sort(maps:keys(Now) -- maps:keys(Old)),
                       removed => lists:sort(maps:keys(Old) -- maps:keys(Now)),
                       taxonomy_changed => lists:sort(Changed), sequence_changed => lists:sort(SeqChanged)},
            case Report of
                #{added := [], removed := [], taxonomy_changed := [], sequence_changed := []} -> {unchanged, same_content};
                _ ->
                    ok = write_bundle("refseq_viral.next", New),
                    ok = file:write_file(bundle_file("refseq_viral.next.json"), json:encode(Report)),
                    {changed, Report}
            end
    end.

%% Makes refseq_viral.next the site's RefSeq bundle, keeping the one before as refseq_viral.previous, and rebuilds the
%% protein bundle from the new genomes' current protein download. {ok, #{refseq_viral, refseq_viral_proteins,
%% previous}} | {error, nothing_to_apply}. Results made before keep their bundles' hashes in their provenance; the
%% old bundles stay in the store.
-spec apply_update() -> {ok, map()} | {error, nothing_to_apply}.
apply_update() ->
    case file:read_file(bundle_file("refseq_viral.next")) of
        {error, enoent} -> {error, nothing_to_apply};
        {ok, N} ->
            New = string:trim(N),
            Prev = current("refseq_viral"),
            #{hash := PZip} = gh_fetch:run({fetch_public, proteins_url()}, #{}),
            Proteins = build_viral_proteins(New, PZip),
            ok = write_bundle("refseq_viral.previous", Prev),
            case file:read_file(bundle_file("refseq_viral_proteins")) of
                {ok, P} -> ok = write_bundle("refseq_viral_proteins.previous", string:trim(P));
                {error, enoent} -> ok
            end,
            ok = write_bundle("refseq_viral", New),
            ok = write_bundle("refseq_viral_proteins", Proteins),
            ok = file:delete(bundle_file("refseq_viral.next")),
            %% the report of what changed is kept as the last applied update's
            _ = file:rename(bundle_file("refseq_viral.next.json"), bundle_file("refseq_viral.applied.json")),
            {ok, #{refseq_viral => New, refseq_viral_proteins => Proteins, previous => Prev}}
    end.

%% the hash of the site's bundle Name; there must be one (built by the site's first run)
current(Name) ->
    case file:read_file(bundle_file(Name)) of
        {ok, H} -> string:trim(H);
        {error, enoent} -> error({no_bundle_yet, Name})
    end.

bundle_file(Name) -> filename:join([application:get_env(genhub2, data_dir, "data"), "bundles", Name]).

write_bundle(Name, Hash) ->
    F = bundle_file(Name),
    ok = filelib:ensure_dir(F),
    Tmp = F ++ ".part",
    ok = file:write_file(Tmp, Hash),
    file:rename(Tmp, F).

%% A coding sequence translated with the standard genetic code; a final stop is left off, other stops and codons with
%% other letters than A, C, G, T become X.
translate(Seq0) ->
    Seq = binary:replace(string:uppercase(Seq0), [<<"U">>, <<"\r">>], <<>>, [global]),
    Aa = << <<(codon(C))>> || <<C:3/binary>> <= Seq >>,
    case Aa of
        <<>> -> <<>>;
        _ -> case binary:last(Aa) of
                 $* -> binary:replace(binary:part(Aa, 0, byte_size(Aa) - 1), <<"*">>, <<"X">>, [global]);
                 _ -> binary:replace(Aa, <<"*">>, <<"X">>, [global])
             end
    end.

codon(C) ->
    Bases = "TCAG",
    Table = <<"FFLLSSSSYY**CC*WLLLLPPPPHHQQRRRRIIIMTTTTNNKKSSRRVVVVAAAADDEEGGGG">>,
    case [string:chr(Bases, B) || <<B>> <= C] of
        [I, J, K] when I > 0, J > 0, K > 0 -> binary:at(Table, (I - 1) * 16 + (J - 1) * 4 + (K - 1));
        _ -> $X
    end.

%% a protein record with at least one letter that is not also a nucleotide letter
protein_letters(R) ->
    [_ | Lines] = binary:split(R, <<"\n">>, [global]),
    Seq = iolist_to_binary(Lines),
    Seq =/= <<>> andalso binary:match(string:uppercase(Seq), [<<"A">>, <<"C">>, <<"G">>, <<"T">>, <<"U">>, <<"N">>, <<"\r">>]) =/= nomatch
        andalso re:run(Seq, "[^ACGTUNacgtun\r]") =/= nomatch.

%% Hostile's index (Constantinides et al. 2023, doi:10.1093/bioinformatics/btad728) from the directory
%% "hostile index fetch --minimap2" filled: Index.fa.gz and Index.mmi, kept under hostile/ as Hostile expects
-spec hostile(file:filename()) -> gh_store:hash().
hostile(Dir) ->
    named("hostile", fun() ->
        gh_refs:bundle(maps:from_list([{"hostile/" ++ filename:basename(F), F}
                                       || F <- filelib:wildcard(filename:join(Dir, "*"))]))
    end).

%% A primer scheme (BED with the primers' sequences) for amplicon sequencing, e.g. ARTIC's
-spec primers(string(), string()) -> gh_store:hash().
primers(Name, Url) ->
    named("primers-" ++ Name, fun() ->
        gh_store:with_tmp(fun(Dir) ->
            F = filename:join(Dir, "primers.bed"),
            ok = file:write_file(F, gh_fetch:get(Url)),
            gh_refs:bundle(#{"primers.bed" => F})
        end)
    end).

%% A prebuilt Kraken 2 database with Bracken's k-mer distributions (Lu et al. 2022, doi:10.1038/s41596-022-00738-y),
%% unpacked under kraken/
-spec kraken(string()) -> gh_store:hash().
kraken(Url) ->
    named("kraken-" ++ filename:basename(Url, ".tar.gz"), fun() ->
        Tgz = gh_fetch:cached(Url),
        gh_store:with_tmp(fun(Dir) ->
            _ = gh_tool:bash("tar -xzf \"$1\" -C \"$2\"", [gh_store:path(Tgz), Dir]),
            Files = [F || F <- filelib:wildcard(filename:join(Dir, "**")), filelib:is_regular(F)],
            gh_refs:bundle(maps:from_list([{"kraken/" ++ filename:basename(F), F} || F <- Files]))
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

%% Every dataset of ?NEXTCLADE_DATASETS at its latest tag on the day the bundle is built, SARS-CoV-2's at the pinned
%% tag, and Nextclade's minimizer index, by which nextclade sort sends each genome to its dataset. datasets.tsv
%% records each dataset's name, tag and file, so the bundle says exactly what it holds.
-spec nextclade_datasets() -> gh_store:hash().
nextclade_datasets() ->
    named("nextclade-datasets-v2", fun() ->
        Sars = nextclade("2026-10-28--15-04-26Z"),
        gh_store:with_tmp(fun(Dir) ->
            Index = filename:join(Dir, "minimizer_index.json"),
            ok = file:write_file(Index, gh_fetch:get("https://data.clades.nextstrain.org/v3/minimizer_index.json")),
            SarsZip = gh_refs:file(Sars, "dataset.zip", node()),
            Got = [{"nextstrain/sars-cov-2/wuhan-hu-1/orfs", SarsZip}
                   | [begin
                          Zip = filename:join(Dir, file_name(N)),
                          _ = gh_tool:bash("nextclade dataset get --name \"$1\" --output-zip \"$2\" >/dev/null 2>&1", [N, Zip]),
                          filelib:file_size(Zip) > 0 orelse error({empty_download, nextclade, N}),
                          {N, Zip}
                      end || N <- ?NEXTCLADE_DATASETS]],
            Rows = [[N, $\t, tag(Z), $\t, file_name(N), $\n] || {N, Z} <- Got],
            Tsv = filename:join(Dir, "datasets.tsv"),
            ok = file:write_file(Tsv, ["#name\ttag\tfile\n" | Rows]),
            gh_refs:bundle(maps:from_list([{"minimizer_index.json", Index}, {"datasets.tsv", Tsv}
                                           | [{file_name(N), Z} || {N, Z} <- Got]]))
        end)
    end).

file_name(Name) -> lists:flatten(string:replace(Name, "/", "__", all)) ++ ".zip".

tag(Zip) ->
    J = json:decode(gh_tool:bash("unzip -p \"$1\" pathogen.json", [Zip])),
    maps:get(<<"tag">>, maps:get(<<"version">>, J, #{}), <<"unknown">>).

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
