%% The added methods, each measured against what it adds to, on the data of phase A's acceptance test:
%%
%%   trees      VeryFastTree against FastTree on the 1,000 SARS-CoV-2 genomes: time, and the Robinson-Foulds distance
%%              between their trees (and neighbour-joining's), short branches collapsed
%%   usher      UShER: a mutation-annotated tree of 900 of the genomes, labelled with their Nextclade lineages; the
%%              other 100 placed into it; their placed clade against their Nextclade lineage
%%   lineages   Nextclade with nextclade sort over many datasets, on the held-out genomes: which genomes reach a
%%              dataset, and whether it is their virus's
%%   dehost     Hostile (T2T + HLA, masked for viruses) against GRCh38 with minimap2, on SARS-CoV-2, Epstein-Barr
%%              virus and human reads: GRCh38's analysis set contains the EBV genome
%%   primers    iVar primer trimming on amplicons simulated from ARTIC V4.1 over a BQ.1.1 genome, whose primer sites
%%              differ from the primers in places: the consensus with and without trimming, against the genome
%%   kraken     Kraken 2 + Bracken on a simulated mixture of three viruses at known shares, with human reads
%%
%% Results: acceptance/results/methods-<host>-<date>.json.
%%   sh acceptance/run_methods.sh
-module(gh_methods_check).
-export([main/1]).
%% for running one part from a shell
-export([source_genome/2, dehost/5, primers/3, kraken/4, lineages/2, containment/2]).

-define(NEXTCLADE_TAG, "2026-10-28--15-04-26Z").

-spec main([string()]) -> no_return().
main([HostIndex, Grch38, Out]) ->
    ok = application:load(genhub2),
    ok = application:set_env(genhub2, http, undefined),
    {ok, _} = application:ensure_all_started(genhub2),
    T0 = erlang:monotonic_time(millisecond),
    Refs = gh_refdb:refseq_viral(),
    Next = gh_refdb:nextclade(?NEXTCLADE_TAG),
    Multi = gh_refdb:nextclade_datasets(),          % nextclade-datasets-v2
    Grch = gh_refdb:host(HostIndex),
    Hostile = bundle("hostile"),
    Primers = bundle("primers-artic-v4.1"),
    Kraken = bundle("kraken-k2_viral_20241228"),
    Params = #{refs => Refs, nextclade => Next},
    log("data"),
    Held = gh_acceptance:held_out(Refs),
    Sars = gh_acceptance:sars_cov_2(),
    Mut = gh_acceptance:mutations_vs_nextclade(Sars, Params),
    log("trees"), Trees = trees(Sars, Refs),
    log("usher"), Usher = usher(Sars, Refs, Mut),
    log("lineages"), Lin = lineages(Held, Multi),
    Source = source_genome(Sars, Mut),
    log("dehost"), Dehost = dehost(Refs, Source, Grch38, Grch, Hostile),
    log("primers"), Prim = primers(Refs, Source, Primers),
    log("kraken"), Kr = kraken(Held, Source, Grch38, Kraken),
    Checks = checks(Trees, Usher, Lin, Dehost, Prim, Kr),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), cpus => erlang:system_info(schedulers_online),
          bundles => #{refseq_viral => Refs, nextclade_datasets => Multi, grch38 => Grch, hostile => Hostile,
                       primers_artic_v4_1 => Primers, kraken => Kraken},
          trees => Trees, usher => Usher, lineages => Lin, dehost => Dehost, primers => Prim, kraken => Kr,
          checks => Checks, seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(gh_json:term(R))),
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    io:format("written ~s~n", [Out]),
    halt(case [C || #{ok := false} = C <- Checks] of [] -> 0; _ -> 1 end).

log(S) -> io:format("~s ~s~n", [calendar:system_time_to_rfc3339(erlang:system_time(second)), S]).

bundle(Name) ->
    {ok, H} = file:read_file(filename:join([application:get_env(genhub2, data_dir, "data"), "bundles", Name])),
    string:trim(H).

secs(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = F(),
    {R, (erlang:monotonic_time(microsecond) - T0) / 1.0e6}.

task(T) -> pq_task:run(T, node()).

%%% trees

trees(#{fasta := Fasta}, Refs) ->
    Run = fun(M) -> secs(fun() -> task({pq_task, gh_tree, {tree, Fasta, Refs, <<"NC_045512.2">>, M}}) end) end,
    Res = maps:from_list([{M, Run(M)} || M <- [nj, fasttree, veryfasttree]]),
    Nwk = fun(M) -> {#{newick := H}, _} = maps:get(M, Res), gh_store:read(H) end,
    %% half a substitution on a 29,903-base genome: shorter branches join identical genomes in an arbitrary order
    Min = 1.0e-5,
    #{seconds => maps:map(fun(_, {_, S}) -> S end, Res),
      newick => maps:map(fun(_, {#{newick := H}, _}) -> H end, Res),
      rf_veryfasttree_fasttree => gh_treecmp:rf(Nwk(veryfasttree), Nwk(fasttree), Min),
      rf_nj_fasttree => gh_treecmp:rf(Nwk(nj), Nwk(fasttree), Min),
      collapse_below => Min,
      fasttree_splits_found => containment(Nwk(fasttree), [{veryfasttree, Nwk(veryfasttree)}, {nj, Nwk(nj)}])}.

%% How many of FastTree's splits each other tree has, branches shorter than 1e-5, 5e-5 and 1e-4 collapsed.
%% VeryFastTree writes no branch that short, so its tree resolves near-identical genomes in an arbitrary order and
%% has more splits; containment, not the Robinson-Foulds distance, says whether it agrees with FastTree's.
containment(Ref, Others) ->
    [#{collapse_below => Min, fasttree => sets:size(gh_treecmp:splits(Ref, Min)),
       found => maps:from_list([{K, sets:size(sets:intersection(gh_treecmp:splits(Ref, Min), gh_treecmp:splits(T, Min)))}
                                || {K, T} <- Others])}
     || Min <- [1.0e-5, 5.0e-5, 1.0e-4]].

%%% UShER

usher(#{fasta := Fasta}, Refs, #{per_genome := PerGenome}) ->
    Recs = gh_fasta:records(gh_store:path(Fasta)),
    Indexed = lists:zip(lists:seq(1, length(Recs)), Recs),
    Out = [R || {I, R} <- Indexed, I rem 10 =:= 0],
    In = [R || {I, R} <- Indexed, I rem 10 =/= 0],
    Put = fun(Rs) -> gh_store:put_binary([[<<">">>, Id, string:trim(X, trailing, "\n"), <<"\n">>] || {Id, X} <- Rs]) end,
    {InHash, OutHash} = {Put(In), Put(Out)},
    {#{newick := Nwk, aligned := Al}, TreeSecs} =
        secs(fun() -> task({pq_task, gh_tree, {tree, InHash, Refs, <<"NC_045512.2">>, nj}}) end),
    Clades = [{Id, maps:get(pango, maps:get(Id, PerGenome))} || {Id, _} <- In, is_map_key(Id, PerGenome)],
    {#{mat := Mat}, BuildSecs} = secs(fun() -> task({pq_task, gh_usher, {usher_build, Al, Nwk, Clades}}) end),
    {Placed, PlaceSecs} = secs(fun() -> task({pq_task, gh_usher, {usher_place, OutHash, Mat, Refs, <<"NC_045512.2">>}}) end),
    Rows = [P#{nextclade => maps:get(pango, maps:get(Q, PerGenome, #{}), <<>>)} || #{query := Q} = P <- Placed],
    Same = [R || #{clade := C, nextclade := N} = R <- Rows, C =:= N, C =/= <<>>],
    %% the same lineage or one of its ancestors/descendants by name (BA.5 and BA.5.2.1)
    Related = [R || #{clade := C, nextclade := N} = R <- Rows, C =/= <<>>, N =/= <<>>,
                    lists:prefix(binary_to_list(C) ++ ".", binary_to_list(N) ++ ".")
                    orelse lists:prefix(binary_to_list(N) ++ ".", binary_to_list(C) ++ ".")],
    #{built_from => length(In), placed => length(Rows), tree_seconds => TreeSecs, build_seconds => BuildSecs,
      place_seconds => PlaceSecs, with_clade => length([x || #{clade := C} <- Rows, C =/= <<>>]),
      same_lineage => length(Same), same_or_related_lineage => length(Related),
      rows => [maps:with([query, clade, nextclade, parsimony, placements], R) || R <- Rows]}.

%%% lineages over many datasets

%% the datasets each held-out virus may go to
expected(<<"SARS-CoV-2">>) -> ["nextstrain/sars-cov-2"];
expected(<<"Influenza A virus">>) -> ["nextstrain/flu/h1n1pdm", "nextstrain/flu/h3n2"];
expected(<<"Influenza B virus">>) -> ["nextstrain/flu/vic", "nextstrain/flu/b", "nextstrain/flu/yam"];
expected(<<"Respiratory syncytial virus">>) -> ["nextstrain/rsv"];
expected(<<"Mpox virus">>) -> ["nextstrain/mpox"];
expected(<<"Ebola virus">>) -> ["nextstrain/orthoebolavirus/ebov"];
expected(<<"Measles virus">>) -> ["nextstrain/measles"];
expected(<<"Dengue virus">>) -> ["nextstrain/dengue", "community/v-gen-lab/dengue"];
expected(<<"Human metapneumovirus">>) -> ["nextstrain/hmpv"];
expected(<<"Rubella virus">>) -> ["nextstrain/rubella"];
expected(<<"Mumps virus">>) -> ["nextstrain/mumps"];
expected(<<"West Nile virus">>) -> ["nextstrain/wnv"];
expected(_) -> [].

lineages(#{fasta := Fasta, truth := Truth}, Multi) ->
    {Rows, Secs} = secs(fun() -> task({pq_task, gh_lineage, {lineage, Fasta, Multi}}) end),
    Scored = [begin
                  V = maps:get(virus, maps:get(Q, Truth)),
                  Ok = D =:= <<>> orelse lists:any(fun(P) -> lists:prefix(P, binary_to_list(D)) end, expected(V)),
                  #{query => Q, virus => V, dataset => D, clade => maps:get(clade, R, <<>>), right_dataset => Ok}
              end || #{query := Q, dataset := D} = R <- Rows],
    ByVirus = maps:groups_from_list(fun(#{virus := V}) -> V end, Scored),
    #{genomes => length(Scored), seconds => Secs,
      routed => length([x || #{dataset := D} <- Scored, D =/= <<>>]),
      with_clade => length([x || #{clade := C} <- Scored, C =/= <<>>]),
      wrong_dataset => [S || #{right_dataset := false} = S <- Scored],
      by_virus => maps:map(fun(_, Ss) ->
                                   #{genomes => length(Ss), routed => length([x || #{dataset := D} <- Ss, D =/= <<>>]),
                                     with_clade => length([x || #{clade := C} <- Ss, C =/= <<>>]),
                                     datasets => lists:usort([D || #{dataset := D} <- Ss, D =/= <<>>])}
                           end, ByVirus)}.

%%% simulated samples

%% the genome of phase A's reads example, as {Id, Sequence}: the first Bulgarian record without missing bases that
%% Nextclade rates good, or, as there is none, the first Bulgarian record (PX916490.1, BQ.1.1; gh2k simulate draws
%% no fragment with N)
source_genome(#{fasta := Fasta, sets := Sets}, #{per_genome := PerGenome}) ->
    Bg = [A || {<<"Bulgaria">>, A} <- Sets],
    Good = [A || A <- Bg, #{qc := <<"good">>, total_missing := <<"0">>} <- [maps:get(A, PerGenome, #{})]],
    Id = hd(Good ++ Bg),
    {_, Rest} = lists:keyfind(Id, 1, gh_fasta:records(gh_store:path(Fasta))),
    [_ | Ls] = binary:split(Rest, <<"\n">>, [global]),
    {Id, iolist_to_binary(Ls)}.

write_fasta(F, Recs) -> ok = file:write_file(F, [[$>, Id, $\n, S, $\n] || {Id, S} <- Recs]).

%% paired reads simulated by gh2k from a FASTA, their names starting with Tag (instead of gh2k's v)
simulate(Fasta, Pairs, Seed, Prefix, Tag) ->
    _ = gh_tool:gh2k_must(["simulate", Fasta, integer_to_list(Pairs), "150", "300", "0.002", integer_to_list(Seed), Prefix]),
    [begin
         F = Prefix ++ S,
         {ok, <<"@v", B/binary>>} = file:read_file(F),
         ok = file:write_file(F, [<<"@">>, Tag, binary:replace(B, <<"\n@v">>, <<"\n@", Tag/binary>>, [global])])
     end || S <- [".R1.fastq", ".R2.fastq"]],
    ok.

concat(Out, Files) ->
    ok = file:write_file(Out, [element(2, file:read_file(F)) || F <- Files]).

origins(FastqHash) ->
    Names = [N || <<"@", N/binary>> <- binary:split(gh_store:read(FastqHash), <<"\n">>, [global])],
    lists:foldl(fun(<<T, _/binary>>, M) -> maps:update_with(<<T>>, fun(C) -> C + 1 end, 1, M) end, #{}, Names).

%%% host removal: GRCh38 (minimap2) against Hostile, with Epstein-Barr virus in the sample

dehost(Refs, {SrcId, Src}, Grch38, Grch, Hostile) ->
    gh_store:with_tmp(fun(Dir) ->
        P = fun(F) -> filename:join(Dir, F) end,
        write_fasta(P("sars.fa"), [{SrcId, Src}]),
        gh_mutations:reference(Refs, <<"NC_007605.1">>, node(), P("ebv.fa")),
        _ = gh_tool:bash("samtools faidx \"$1\" chr1:150000000-160000000 > \"$2\"", [Grch38, P("human.fa")]),
        simulate(P("sars.fa"), 10000, 1, P("s"), <<"v">>),
        simulate(P("ebv.fa"), 10000, 2, P("e"), <<"e">>),
        simulate(P("human.fa"), 10000, 3, P("h"), <<"h">>),
        concat(P("R1.fastq"), [P("s.R1.fastq"), P("e.R1.fastq"), P("h.R1.fastq")]),
        concat(P("R2.fastq"), [P("s.R2.fastq"), P("e.R2.fastq"), P("h.R2.fastq")]),
        [R1, R2] = [gh_store:put_file(P(F)) || F <- ["R1.fastq", "R2.fastq"]],
        maps:from_list(
          [{M, begin
                   {#{r1 := K1, pairs_in := In, pairs_kept := Kept}, Secs} =
                       secs(fun() -> task({pq_task, gh_dehost, {dehost, R1, R2, B}}) end),
                   #{pairs_in => In, pairs_kept => Kept, kept_by_origin => origins(K1), seconds => Secs}
               end} || {M, B} <- [{grch38_minimap2, Grch}, {hostile, Hostile}]])
    end).

%%% primer trimming: ARTIC V4.1 amplicons over the BQ.1.1 genome

primers(Refs, {SrcId, Src}, Primers) ->
    gh_store:with_tmp(fun(Dir) ->
        P = fun(F) -> filename:join(Dir, F) end,
        %% the genome in Wuhan-Hu-1's coordinates, as the primer scheme's are
        write_fasta(P("src.fa"), [{SrcId, Src}]),
        gh_mutations:reference(Refs, <<"NC_045512.2">>, node(), P("ref.fa")),
        [{_, {TLen, Segs}}] = maps:to_list(gh_mutations:align(P("ref.fa"), P("src.fa"), Dir)),
        G = gh_cs:aligned(Segs, TLen),
        {ok, Bed} = file:read_file(gh_refs:file(Primers, "primers.bed", node())),
        Prims = [{binary_to_integer(S), binary_to_integer(E), Name, Strand, string:trim(Seq)}
                 || L <- binary:split(Bed, <<"\n">>, [global, trim_all]),
                    [_, S, E, Name, _Pool, Strand, Seq | _] <- [binary:split(L, <<"\t">>, [global])],
                    binary:match(Name, <<"alt">>) =:= nomatch],
        Amplicons = amplicons(Prims),
        %% reads: 50 pairs of 2 x 250 per amplicon, error-free, the primer sites carrying the primers' bases
        {Reads1, Reads2, Used, Mismatches} = lists:foldl(
            fun({N, {LS, LE, LSeq}, {RS, RE, RSeq}}, {A1, A2, U, M}) ->
                    Frag0 = binary:part(G, LS, RE - LS),
                    case binary:match(Frag0, [<<"N">>, <<"-">>]) of
                        nomatch ->
                            Frag = iolist_to_binary([LSeq, binary:part(G, LE, RS - LE), revcomp(RSeq)]),
                            Mm = mism(binary:part(G, LS, LE - LS), LSeq, LS) ++ mism(binary:part(G, RS, RE - RS), revcomp(RSeq), RS),
                            Rl = min(250, byte_size(Frag)),
                            R1 = binary:part(Frag, 0, Rl),
                            R2 = revcomp(binary:part(Frag, byte_size(Frag) - Rl, Rl)),
                            Q = binary:copy(<<"I">>, Rl),
                            Rs1 = [["@a", integer_to_list(N), "_", integer_to_list(K), "/1\n", R1, "\n+\n", Q, "\n"] || K <- lists:seq(1, 50)],
                            Rs2 = [["@a", integer_to_list(N), "_", integer_to_list(K), "/2\n", R2, "\n+\n", Q, "\n"] || K <- lists:seq(1, 50)],
                            {[Rs1 | A1], [Rs2 | A2], U + 1, M ++ Mm};
                        _ -> {A1, A2, U, M}
                    end
            end, {[], [], 0, []}, Amplicons),
        ok = file:write_file(P("R1.fastq"), lists:reverse(Reads1)),
        ok = file:write_file(P("R2.fastq"), lists:reverse(Reads2)),
        [R1h, R2h] = [gh_store:put_file(P(F)) || F <- ["R1.fastq", "R2.fastq"]],
        Run = fun(Pr) ->
                      #{genome := C} = task({pq_task, gh_consensus, {consensus, R1h, R2h, Refs, <<"NC_045512.2">>, 10, Pr}}),
                      ok = file:write_file(P("cons.fa"), gh_store:read(C)),
                      Best = gh_cs:best(gh_tool:bash("minimap2 -c -x asm5 --cs=long \"$1\" \"$2\" 2>/dev/null",
                                                     [P("src.fa"), P("cons.fa")])),
                      [{_, {SL, SSegs}}] = maps:to_list(Best),
                      #{substitutions := S, missing := Mi} = gh_cs:mutations(SSegs, SL),
                      %% wrong bases, and bases the consensus leaves N where reads disagree (a primer's base against
                      %% the overlapping amplicon's)
                      #{differences => length(S), n_where_genome_has_base => Mi}
              end,
        #{amplicons => length(Amplicons), amplicons_used => Used,
          primer_sites_differing_from_genome => length(lists:usort(Mismatches)),
          untrimmed => Run(none), trimmed => Run(Primers)}
    end).

%% {Number, {LeftStart, LeftEnd, LeftSeq}, {RightStart, RightEnd, RightSeq}} for every amplicon of the scheme
amplicons(Prims) ->
    Num = fun(Name) -> {match, [N]} = re:run(Name, "_([0-9]+)_(LEFT|RIGHT)", [{capture, [1], binary}]), binary_to_integer(N) end,
    L = maps:from_list([{Num(N), {S, E, Seq}} || {S, E, N, <<"+">>, Seq} <- Prims]),
    R = maps:from_list([{Num(N), {S, E, Seq}} || {S, E, N, <<"-">>, Seq} <- Prims]),
    %% amplicons whose primers fill their BED intervals (V4.1's 64_LEFT does not: 39 bases for a 25-base primer)
    Fits = fun({S, E, Seq}) -> E - S =:= byte_size(Seq) end,
    [{N, maps:get(N, L), maps:get(N, R)} || N <- lists:sort(maps:keys(L)), is_map_key(N, R),
                                            Fits(maps:get(N, L)), Fits(maps:get(N, R))].

mism(Genome, Primer, Start) ->
    [Start + I || I <- lists:seq(0, min(byte_size(Genome), byte_size(Primer)) - 1),
                  binary:at(Genome, I) =/= binary:at(Primer, I)].

revcomp(B) ->
    << <<(case C of $A -> $T; $C -> $G; $G -> $C; $T -> $A; X -> X end)>> || <<C>> <= list_to_binary(lists:reverse(binary_to_list(B))) >>.

%%% Kraken 2 + Bracken: a mixture of three viruses

kraken(#{fasta := Fasta, truth := Truth}, {SrcId, Src}, Grch38, Kraken) ->
    Recs = gh_fasta:records(gh_store:path(Fasta)),
    Pick = fun(Virus) -> hd([{Id, R} || {Id, R} <- Recs, maps:get(virus, maps:get(Id, Truth, #{virus => none})) =:= Virus]) end,
    {FluId, FluRest} = Pick(<<"Influenza A virus">>),
    {RsvId, RsvRest} = Pick(<<"Respiratory syncytial virus">>),
    Seq = fun(Rest) -> [_ | Ls] = binary:split(Rest, <<"\n">>, [global]), iolist_to_binary(Ls) end,
    Mix = [{<<"s">>, {SrcId, Src}, 6000}, {<<"f">>, {FluId, Seq(FluRest)}, 3000}, {<<"r">>, {RsvId, Seq(RsvRest)}, 1000}],
    gh_store:with_tmp(fun(Dir) ->
        P = fun(F) -> filename:join(Dir, F) end,
        Files = lists:append(
                  [begin
                       Fa = P(binary_to_list(Tag) ++ ".fa"),
                       write_fasta(Fa, [Rec]),
                       simulate(Fa, N, 10 + I, P(binary_to_list(Tag)), Tag),
                       [P(binary_to_list(Tag) ++ ".R1.fastq")]
                   end || {I, {Tag, Rec, N}} <- lists:zip(lists:seq(1, 3), Mix)]),
        _ = gh_tool:bash("samtools faidx \"$1\" chr1:150000000-160000000 > \"$2\"", [Grch38, P("human.fa")]),
        simulate(P("human.fa"), 2000, 20, P("h"), <<"h">>),
        concat(P("R1.fastq"), Files ++ [P("h.R1.fastq")]),
        concat(P("R2.fastq"), [lists:flatten(string:replace(F, ".R1.", ".R2.")) || F <- Files] ++ [P("h.R2.fastq")]),
        [R1, R2] = [gh_store:put_file(P(F)) || F <- ["R1.fastq", "R2.fastq"]],
        {Res0, Secs} = secs(fun() -> task({pq_task, gh_kraken, {kraken, R1, R2, Kraken, 150}}) end),
        %% the database's taxonomy is from its build (December 2024): species named as NCBI names them today
        Now = gh_ncbi:taxonomy([maps:get(taxid, S) || S <- maps:get(species, Res0)]),
        Res = Res0#{species := [S#{name => case maps:get(species, maps:get(T, Now, #{}), <<>>) of
                                                <<>> -> N;
                                                Cur -> Cur
                                            end, name_in_database => N}
                                || #{taxid := T, name := N} = S <- maps:get(species, Res0)]},
        Expected = [{maps:get(species, maps:get(Id, Truth, #{species => <<"Betacoronavirus pandemicum">>})), N / 10000}
                    || {_, {Id, _}, N} <- Mix],
        Res#{seconds => Secs, mixture => [#{virus => Id, pairs => N} || {_, {Id, _}, N} <- Mix],
             expected_shares => maps:from_list(Expected)}
    end).

%%% checks

checks(Trees, Usher, Lin, Dehost, Prim, Kr) ->
    #{seconds := TS} = Trees,
    #{hostile := H, grch38_minimap2 := G} = Dehost,
    Kept = fun(M, T) -> maps:get(T, maps:get(kept_by_origin, M), 0) end,
    Shares = maps:from_list([{maps:get(name, S), maps:get(share, S)} || S <- maps:get(species, Kr)]),
    Exp = maps:get(expected_shares, Kr),
    [check(<<"VeryFastTree: a maximum-likelihood tree of the 1,000 genomes in < 300 s">>, maps:get(veryfasttree, TS) < 300,
           TS),
     check(<<"VeryFastTree's tree against FastTree's: Robinson-Foulds distance (measured)">>, true,
           maps:get(rf_veryfasttree_fasttree, Trees)),
     check(<<"UShER: every left-out genome placed">>, maps:get(placed, Usher) =:= 100, maps:get(placed, Usher)),
     check(<<"UShER: placed clade = Nextclade lineage, or a parent or child of it (measured)">>, true,
           maps:with([same_lineage, same_or_related_lineage, with_clade, place_seconds], Usher)),
     check(<<"lineages: no held-out genome sent to another virus's dataset">>, maps:get(wrong_dataset, Lin) =:= [],
           maps:with([routed, with_clade, wrong_dataset], Lin)),
     check(<<"dehost: Hostile keeps the EBV pairs (>= 99%), GRCh38 removes them">>,
           Kept(H, <<"e">>) >= 9900 andalso Kept(G, <<"e">>) =< 100, [Kept(H, <<"e">>), <<" vs ">>, Kept(G, <<"e">>)]),
     check(<<"dehost: both remove the human pairs (>= 99%) and keep the SARS-CoV-2 pairs (>= 99%)">>,
           lists:all(fun(M) -> Kept(M, <<"h">>) =< 100 andalso Kept(M, <<"v">>) >= 9900 end, [H, G]),
           #{hostile => maps:get(kept_by_origin, H), grch38 => maps:get(kept_by_origin, G)}),
     check(<<"primers: trimmed consensus has no wrong base, and fewer wrong or missing bases than untrimmed">>,
           maps:get(differences, maps:get(trimmed, Prim)) =:= 0 andalso
           bad(maps:get(trimmed, Prim)) < bad(maps:get(untrimmed, Prim)),
           maps:with([primer_sites_differing_from_genome, trimmed, untrimmed], Prim)),
     check(<<"kraken: each virus's Bracken share within 5 points of the mixture's">>,
           lists:all(fun({Sp, E}) -> abs(maps:get(Sp, Shares, 0.0) - E) =< 0.05 end, maps:to_list(Exp)),
           #{expected => Exp, bracken => maps:with(maps:keys(Exp), Shares)})].

bad(#{differences := D, n_where_genome_has_base := N}) -> D + N.

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => iolist_to_binary(io_lib:format("~0P", [Value, 40]))}.
