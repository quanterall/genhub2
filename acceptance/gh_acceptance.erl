%% Phase A's acceptance test (plan section 5, FS 6.3): GenHub2 on one node, with PQCF's local executor.
%%
%%   1. The SARS-CoV-2 example (FS 13): the reference genome NC_045512.2 uploaded as a genome; and reads simulated
%%      from a Bulgarian SARS-CoV-2 genome with human reads mixed in, uploaded as read pairs. Both through the job
%%      service (Mnesia), every step a PQCF task with its provenance.
%%   2. A held-out set from NCBI Virus: GenBank genomes (not RefSeq, none identical to a RefSeq genome) of 30 viruses
%%      that matter to Bulgarian labs, 20 a virus, classified against the RefSeq database; accuracy at species, genus
%%      and family, per confidence level.
%%   3. 1,000 SARS-CoV-2 genomes (the 138 from Bulgaria in GenBank, and the rest from five publication months
%%      2020-2024): mutations against Wuhan-Hu-1 compared with Nextclade's, genome by genome.
%%   4. The specification's targets (FS 3.5), measured: a 10 MB upload processed in under 5 s; 1,000 sequences
%%      classified in under 60 s; a tree of 1,000 genomes in under 5 minutes (neighbour-joining and FastTree).
%%
%% The accessions are kept in acceptance/*.tsv, so the test reruns on the same genomes. Results:
%% acceptance/results/phase-a-<host>-<date>.json; exit status 0 when every check holds.
%%   sh acceptance/run.sh HOST_INDEX GRCH38_FASTA [cpuset]     every check (20)
%%   sh acceptance/run.sh --reduced [cpuset]                   without the human reference: part 1's reads example (6
%%                                                             checks) is skipped and said so; the other 14 run
-module(gh_acceptance).
-export([main/1]).
%% for looking into a part of the test from a shell
-export([sars_cov_2/0, mutations_vs_nextclade/2, held_out/1, classification/2, protein_vs_minhash/3]).

-define(NEXTCLADE_TAG, "2026-10-28--15-04-26Z").
-define(HUMAN_REGION, "chr1:150000000-160000000").

-define(HELD_OUT, [{"SARS-CoV-2", 2697049}, {"Influenza A virus", 11320}, {"Influenza B virus", 11520},
                   {"Respiratory syncytial virus", 11250}, {"Human metapneumovirus", 162145},
                   {"Measles virus", 11234}, {"Mumps virus", 2560602}, {"Rubella virus", 11041},
                   {"Hepatitis A virus", 12092}, {"Hepatitis B virus", 10407}, {"Hepatitis C virus", 3052230},
                   {"Hepatitis E virus", 291484}, {"HIV-1", 11676}, {"Dengue virus", 12637}, {"Zika virus", 64320},
                   {"West Nile virus", 11082}, {"Tick-borne encephalitis virus", 11084},
                   {"Crimean-Congo haemorrhagic fever virus", 3052518}, {"Dobrava-Belgrade virus", 3052477},
                   {"Chikungunya virus", 37124}, {"Ebola virus", 3052462}, {"Rabies virus", 11292},
                   {"Norovirus GII", 122929}, {"Rotavirus A", 28875}, {"Enterovirus A71", 39054},
                   {"Enterovirus D68", 42789}, {"Human papillomavirus 16", 333760}, {"Herpes simplex virus 1", 10298},
                   {"Human adenovirus C", 129951}, {"Mpox virus", 10244}]).
-define(PER_VIRUS, 20).

-spec main([string()]) -> no_return().
%% Args: [HostIndex (minimap2 -x sr index of GRCh38), Grch38Fasta (indexed), OutJson], or ["--reduced", OutJson]
main(["--reduced", Out]) -> run(none, none, Out);
main([HostIndex, Grch38, Out]) -> run(HostIndex, Grch38, Out).

-spec run(string() | none, string() | none, string()) -> no_return().
run(HostIndex, Grch38, Out) ->
    {ok, _} = application:ensure_all_started(genhub2),
    T0 = erlang:monotonic_time(millisecond),
    log("reference bundles"),
    Refs = gh_refdb:refseq_viral(),
    Host = case HostIndex of none -> null; _ -> gh_refdb:host(HostIndex) end,
    Next = gh_refdb:nextclade(?NEXTCLADE_TAG),
    Proteins = gh_refdb:viral_proteins(),
    Params0 = #{refs => Refs, proteins => Proteins, nextclade => Next, min_depth => 10},
    Params = case Host of null -> Params0; _ -> Params0#{host => Host} end,
    log("data: held-out set and SARS-CoV-2 genomes"),
    Held = held_out(Refs),
    Sars = sars_cov_2(),
    log("3. mutations and lineages of the 1,000 SARS-CoV-2 genomes"),
    Mut = mutations_vs_nextclade(Sars, Params),
    log("1. the SARS-CoV-2 example"),
    ExGenome = example_genome(Params),
    ExReads = case Grch38 of
                  none -> log("   the reads example skipped: no human reference (--reduced)"), skipped;
                  _ -> example_reads(Params, Sars, Mut, Grch38)
              end,
    log("2. held-out classification"),
    Class = classification(Held, Refs),
    log("2b. held-out classification by proteins"),
    Prot = protein_vs_minhash(Held, Refs, Proteins),
    log("4. targets"),
    Targets = targets(Params, Sars),
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out ++ ".partial", term_to_binary({ExGenome, ExReads, Class, Prot, Mut, Targets})),
    Checks = checks(ExGenome, ExReads, Class, Mut, Targets) ++ protein_checks(Class, Prot),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), cpus => erlang:system_info(schedulers_online),
          pqcf => <<"2a90a1f">>, nextclade_dataset => list_to_binary(?NEXTCLADE_TAG),
          bundles => #{refseq_viral => Refs, refseq_viral_proteins => Proteins, host => Host, nextclade => Next},
          reduced => Grch38 =:= none,
          skipped => case ExReads of
                         skipped -> [<<"part 1, the reads example (6 checks): it needs the human reference, GRCh38">>];
                         _ -> []
                     end,
          references => length(maps:keys(gh_refs:taxonomy(Refs, node()))),
          example_genome => ExGenome, example_reads => case ExReads of skipped -> null; _ -> ExReads end,
          held_out => Class, held_out_protein => Prot,
          sars_cov_2_1000 => Mut,
          targets => Targets, checks => Checks,
          seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = file:write_file(Out, json:format(jsonable(R))),
    ok = file:delete(Out ++ ".partial"),
    Failed = [C || #{ok := false} = C <- Checks],
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    [io:format("skip part 1's reads example (6 checks): no human reference, a reduced run~n") || ExReads =:= skipped],
    io:format("written ~s~n", [Out]),
    halt(case Failed of [] -> 0; _ -> 1 end).

log(S) -> io:format("~s ~s~n", [calendar:system_time_to_rfc3339(erlang:system_time(second)), S]).

secs(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = F(),
    {R, (erlang:monotonic_time(microsecond) - T0) / 1.0e6}.

%%% data

%% The held-out genomes: {FastaHash, Accession => Truth, Excluded}. Accessions from acceptance/held-out.tsv, or
%% chosen (choose/1) and saved.
held_out(Refs) ->
    Tsv = "acceptance/held-out.tsv",
    Rows = case file:read_file(Tsv) of
               {ok, B} -> [list_to_tuple(binary:split(L, <<"\t">>)) || L <- binary:split(B, <<"\n">>, [global, trim_all]),
                                                                       binary:first(L) =/= $#];
               {error, enoent} ->
                   Chosen = lists:append([[{list_to_binary(Name), A} || A <- choose(TaxId)] || {Name, TaxId} <- ?HELD_OUT]),
                   ok = file:write_file(Tsv, ["#virus\taccession\n" | [[N, $\t, A, $\n] || {N, A} <- Chosen]]),
                   Chosen
           end,
    gh_store:with_tmp(fun(Dir) ->
        {Fasta, TaxTsv} = gh_refdb:genomes([A || {_, A} <- Rows], Dir),
        Truth0 = truth(TaxTsv),
        Virus = maps:from_list([{A, N} || {N, A} <- Rows]),
        RefHashes = maps:from_list([{H, Id} || {Id, H} <- maps:to_list(gh_fasta:seq_hashes(gh_refs:file(Refs, "refs.fasta", node())))]),
        Mine = gh_fasta:seq_hashes(Fasta),
        Identical = [Id || {Id, H} <- maps:to_list(Mine), is_map_key(H, RefHashes)],
        Keep = [{Id, R} || {Id, R} <- gh_fasta:records(Fasta), not lists:member(Id, Identical)],
        H = gh_store:put_binary([[<<">">>, Id, string:trim(R, trailing, "\n"), <<"\n">>] || {Id, R} <- Keep]),
        Truth = maps:map(fun(A, T) -> T#{virus => maps:get(A, Virus, <<>>)} end, Truth0),
        #{fasta => H, truth => Truth, identical_to_refseq => lists:sort(Identical), records => length(Keep),
          requested => length(Rows)}
    end).

%% GenBank records (RefSeq excluded) titled as complete genomes or complete sequences (segments) of the taxon, from
%% Entrez; 20 evenly over the first 1,000 accessions sorted
choose(TaxId) ->
    Term = "txid" ++ integer_to_list(TaxId) ++ "[Organism:exp] AND (\"complete genome\"[Title] OR "
        "\"complete sequence\"[Title]) NOT refseq[filter]",
    Accs = lists:sort(gh_ncbi:esearch(Term, 1000)),
    N = length(Accs),
    case N =< ?PER_VIRUS of
        true -> Accs;
        false -> [lists:nth(1 + (I * N) div ?PER_VIRUS, Accs) || I <- lists:seq(0, ?PER_VIRUS - 1)]
    end.

truth(TaxTsv) ->
    {ok, B} = file:read_file(TaxTsv),
    maps:from_list([begin
                        [A, T, S, G, F, O] = binary:split(L, <<"\t">>, [global]),
                        {A, #{taxid => binary_to_integer(T), species => S, genus => G, family => F, organism => O}}
                    end || L <- binary:split(B, <<"\n">>, [global, trim_all]), binary:first(L) =/= $#]).

%% 1,000 SARS-CoV-2 genomes: {FastaHash, [{Set, Accession}]}; acceptance/sars-cov-2.tsv, or chosen and saved
sars_cov_2() ->
    Tsv = "acceptance/sars-cov-2.tsv",
    Rows = case file:read_file(Tsv) of
               {ok, B} -> [list_to_tuple(binary:split(L, <<"\t">>)) || L <- binary:split(B, <<"\n">>, [global, trim_all]),
                                                                       binary:first(L) =/= $#];
               {error, enoent} ->
                   Base = "txid2697049[Organism:exp] AND 29000:31000[SLEN]",
                   Bg = [{<<"Bulgaria">>, A} || A <- lists:sort(gh_ncbi:esearch(Base ++ " AND Bulgaria[All Fields]", 1000))],
                   Per = (1000 - length(Bg)) div 5,
                   Months = [{<<"2020-06">>, "2020/06"}, {<<"2021-06">>, "2021/06"}, {<<"2022-06">>, "2022/06"},
                             {<<"2023-06">>, "2023/06"}, {<<"2024-06">>, "2024/06"}],
                   Others = lists:append(
                              [begin
                                   Got = lists:sort(gh_ncbi:esearch(Base ++ " AND " ++ M ++ "/01:" ++ M ++ "/30[PDAT]",
                                                                    Per * 2)),
                                   [{Set, A} || A <- lists:sublist(Got -- [X || {_, X} <- Bg], Per)]
                               end || {Set, M} <- Months]),
                   Extra = 1000 - length(Bg) - length(Others),
                   More = [{<<"2024-06">>, A} || A <- lists:sublist(
                                                        lists:sort(gh_ncbi:esearch(Base ++ " AND 2024/07/01:2024/07/31[PDAT]", 200))
                                                        -- [X || {_, X} <- Bg ++ Others], Extra)],
                   All = Bg ++ Others ++ More,
                   ok = file:write_file(Tsv, ["#set\taccession\n" | [[S, $\t, A, $\n] || {S, A} <- All]]),
                   All
           end,
    gh_store:with_tmp(fun(Dir) ->
        {Fasta, _} = gh_refdb:genomes([A || {_, A} <- Rows], Dir),
        #{fasta => gh_store:put_file(Fasta), sets => Rows, records => length(gh_fasta:records(Fasta))}
    end).

%%% 1. the SARS-CoV-2 example

example_genome(Params = #{refs := Refs}) ->
    G = gh_store:with_tmp(fun(Dir) ->
                                  F = filename:join(Dir, "NC_045512.2.fasta"),
                                  gh_mutations:reference(Refs, <<"NC_045512.2">>, node(), F),
                                  gh_store:put_file(F)
                          end),
    {Job, Secs} = secs(fun() -> Id = gh_jobs:submit(genome, [G], Params), {Id, gh_jobs:wait(Id, 600000)} end),
    {Id, #{state := State}} = Job,
    Steps = gh_jobs:steps(Id),
    [[Call]] = results(Steps, classify),
    [[Mut]] = results(Steps, mutations),
    [[Lin]] = results(Steps, lineage),
    #{job => Id, state => State, seconds => Secs, call => maps:get(<<"call">>, Call),
      substitutions => length(maps:get(substitutions, Mut)), clade => maps:get(clade, Lin), pango => maps:get(pango, Lin),
      knowledge => results(Steps, knowledge), step_seconds => step_seconds(Steps),
      provenance => [P || {_, P} <- element(1, maps:get(classify, Steps))]}.

results(Steps, Step) -> [R || {R, _Prov} <- element(1, maps:get(Step, Steps, {[], 0}))].

step_seconds(Steps) -> maps:map(fun(_, {_, S}) -> S end, Steps).

%% Reads from a Bulgarian genome that Nextclade passes as good, with human reads mixed in.
example_reads(Params, #{fasta := Fasta, sets := Sets}, #{per_genome := PerGenome}, Grch38) ->
    Bg = [A || {<<"Bulgaria">>, A} <- Sets],
    Good = [A || A <- Bg, #{qc := <<"good">>, total_missing := <<"0">>} <- [maps:get(A, PerGenome, #{})]],
    Source = hd(Good ++ Bg),
    #{pango := Pango} = maps:get(Source, PerGenome),
    gh_store:with_tmp(fun(Dir) ->
        [Src, Human, Prefix] = [filename:join(Dir, F) || F <- ["source.fa", "human.fa", "sample"]],
        Recs = gh_fasta:records(gh_store:path(Fasta)),
        {_, Rest} = lists:keyfind(Source, 1, Recs),
        ok = file:write_file(Src, [<<">">>, Source, string:trim(Rest, trailing, "\n"), <<"\n">>]),
        _ = gh_tool:bash("samtools faidx \"$1\" \"$2\" > \"$3\"", [Grch38, ?HUMAN_REGION, Human]),
        Sim = json:decode(gh_tool:gh2k_must(["simulate", Src, "20000", "150", "300", "0.002", "42", Prefix, Human, "20000"])),
        [R1, R2] = [gh_store:put_file(Prefix ++ S) || S <- [".R1.fastq", ".R2.fastq"]],
        {Job, Secs} = secs(fun() -> Id = gh_jobs:submit(reads, [R1, R2], Params), {Id, gh_jobs:wait(Id, 1800000)} end),
        {Id, #{state := State} = J} = Job,
        Steps = gh_jobs:steps(Id),
        case State of
            done -> ok;
            _ -> io:format("reads job: ~p~n", [J])
        end,
        [#{r1 := K1, pairs_in := In, pairs_kept := Kept}] = results(Steps, dehost),
        Names = [N || <<"@", N/binary>> <- lines(gh_store:read(K1))],
        KeptV = length([N || <<"v", _/binary>> = N <- Names]),
        KeptH = length([N || <<"h", _/binary>> = N <- Names]),
        [Cons] = results(Steps, consensus),
        Diff = consensus_vs_source(maps:get(genome, Cons), Src, Dir),
        [[Call]] = results(Steps, classify),
        [[Lin]] = results(Steps, lineage),
        #{job => Id, state => State, seconds => Secs, source => Source, source_pango => Pango, simulated => Sim,
          pairs_in => In, pairs_kept => Kept, viral_kept => KeptV, human_kept => KeptH,
          screen => hd(maps:get(<<"hits">>, hd(results(Steps, screen)))),
          consensus => maps:remove(genome, Cons), consensus_vs_source => Diff, call => maps:get(<<"call">>, Call),
          pango => maps:get(pango, Lin), clade => maps:get(clade, Lin), step_seconds => step_seconds(Steps)}
    end).

lines(B) -> binary:split(B, <<"\n">>, [global, trim_all]).

%% the consensus aligned to the genome the reads came from: differences at called bases, and bases called
consensus_vs_source(Cons, Src, _Dir) ->
    Best = gh_cs:best(gh_tool:bash("minimap2 -c -x asm5 --cs=long \"$1\" \"$2\" 2>/dev/null", [Src, gh_store:path(Cons)])),
    [{_, {TLen, Segs}}] = maps:to_list(Best),
    #{substitutions := S, insertions := I, deletions := D, missing := M} = gh_cs:mutations(Segs, TLen),
    #{substitutions => length(S), insertions => length(I), deletions => length(D), n_bases => M,
      source_covered => lists:sum([TE - TS || {TS, TE, _} <- Segs]) / TLen}.

%%% 2. held-out classification

classification(#{fasta := Fasta, truth := Truth} = Held, Refs) ->
    Chunks = split(Fasta, 100),
    {Results, Secs} = secs(fun() ->
        lists:append(pq_rexec:map([{pq_task, gh_classify, {classify, C, Refs, 10}} || C <- Chunks], local, #{}))
    end),
    Rows = [row(Q, maps:get(maps:get(<<"query">>, Q), Truth)) || Q <- Results],
    Rank = fun(K, Rs) -> score([R || R <- Rs, maps:get({truth, K}, R) =/= <<>>], K) end,
    ByConf = [{C, #{n => length(Rs), species => Rank(species, Rs), genus => Rank(genus, Rs), family => Rank(family, Rs)}}
              || C <- [<<"high">>, <<"medium">>, <<"low">>, <<"unclassified">>],
                 Rs <- [[R || R <- Rows, maps:get(confidence, R) =:= C]]],
    ByVirus = [{V, #{n => length(Rs), species => Rank(species, Rs), family => Rank(family, Rs),
                     confidence => count([maps:get(confidence, R) || R <- Rs])}}
               || V <- lists:usort([maps:get(virus, R) || R <- Rows]), Rs <- [[R || R <- Rows, maps:get(virus, R) =:= V]]],
    Wrong = [maps:with([query, virus, confidence, ani, {truth, species}, {call, species}], R)
             || R <- Rows, maps:get({truth, species}, R) =/= <<>>, maps:get({call, species}, R) =/= maps:get({truth, species}, R)],
    #{genomes => length(Rows), requested => maps:get(requested, Held), identical_to_refseq => maps:get(identical_to_refseq, Held),
      seconds => Secs, species => Rank(species, Rows), genus => Rank(genus, Rows), family => Rank(family, Rows),
      by_confidence => maps:from_list(ByConf), by_virus => maps:from_list(ByVirus), misclassified => Wrong}.

row(Q, T) ->
    C = maps:get(<<"call">>, Q),
    #{query => maps:get(<<"query">>, Q), virus => maps:get(virus, T), confidence => maps:get(<<"confidence">>, C),
      ani => maps:get(<<"ani">>, C, 0.0),
      {truth, species} => maps:get(species, T), {truth, genus} => maps:get(genus, T), {truth, family} => maps:get(family, T),
      {call, species} => maps:get(<<"species">>, C, none), {call, genus} => maps:get(<<"genus">>, C, none),
      {call, family} => maps:get(<<"family">>, C, none)}.

score(Rows, K) ->
    N = length(Rows),
    Right = length([R || R <- Rows, maps:get({call, K}, R) =:= maps:get({truth, K}, R)]),
    #{right => Right, total => N, accuracy => case N of 0 -> null; _ -> Right / N end}.

count(L) -> lists:foldl(fun(X, M) -> maps:update_with(X, fun(C) -> C + 1 end, 1, M) end, #{}, L).

%% the FASTA file in the store as files of N records each
split(Fasta, N) ->
    Recs = gh_fasta:records(gh_store:path(Fasta)),
    [gh_store:put_binary([[<<">">>, Id, string:trim(R, trailing, "\n"), <<"\n">>] || {Id, R} <- C]) || C <- chunks(Recs, N)].

chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].

%%% 2b. classification by proteins, against MinHash and combined

%% Every held-out genome classified by MinHash and by proteins (gh_protein); scored alone and as GenHub2 combines
%% them (the protein call replaces MinHash's low-confidence and unclassified calls), by MinHash's confidence.
protein_vs_minhash(#{fasta := Fasta, truth := Truth}, Refs, Proteins) ->
    Chunks = split(Fasta, 100),
    Mh = lists:append(pq_rexec:map([{pq_task, gh_classify, {classify, C, Refs, 10}} || C <- Chunks], local, #{})),
    {Pr0, Secs} = secs(fun() ->
        lists:append(pq_rexec:map([{pq_task, gh_protein, {protein, C, Proteins}} || C <- Chunks], local,
                                  #{workers => 3}))
    end),
    Pr = maps:from_list([{maps:get(query, P), maps:get(call, P)} || P <- Pr0]),
    Rows = [begin
                Q = maps:get(<<"query">>, M),
                T = maps:get(Q, Truth),
                MC = maps:get(<<"call">>, M),
                PC = maps:get(Q, Pr),
                Conf = maps:get(<<"confidence">>, MC),
                Use = case (Conf =:= <<"low">> orelse Conf =:= <<"unclassified">>)
                           andalso maps:get(confidence, PC) =/= unclassified of
                          true -> protein;
                          false -> minhash
                      end,
                #{query => Q, virus => maps:get(virus, T), minhash_confidence => Conf,
                  protein_confidence => maps:get(confidence, PC), used => Use,
                  truth => maps:with([species, genus, family], T),
                  minhash => #{species => maps:get(<<"species">>, MC, none), genus => maps:get(<<"genus">>, MC, none),
                               family => maps:get(<<"family">>, MC, none)},
                  protein => maps:with([species, genus, family, aa_identity], PC)}
            end || M <- Mh],
    Score = fun(Rs, Who, K) ->
                    Rs2 = [R || R <- Rs, maps:get(K, maps:get(truth, R)) =/= <<>>],
                    Right = length([R || R <- Rs2, maps:get(K, maps:get(pick(R, Who), R), none) =:= maps:get(K, maps:get(truth, R))]),
                    #{right => Right, total => length(Rs2)}
            end,
    Table = fun(Rs) -> maps:from_list([{W, maps:from_list([{K, Score(Rs, W, K)} || K <- [species, genus, family]])}
                                       || W <- [minhash, protein, combined]]) end,
    Buckets = [<<"high">>, <<"medium">>, <<"low">>, <<"unclassified">>],
    #{genomes => length(Rows), protein_seconds => Secs, all => Table(Rows),
      by_minhash_confidence => maps:from_list([{B, Table([R || R <- Rows, maps:get(minhash_confidence, R) =:= B])}
                                               || B <- Buckets]),
      protein_used => length([R || #{used := protein} = R <- Rows]),
      changed => [maps:with([query, virus, minhash, protein, truth, used], R)
                  || R <- Rows, maps:get(species, maps:get(minhash, R)) =/= maps:get(species, maps:get(protein, R), none)]}.

pick(_, minhash) -> minhash;
pick(_, protein) -> protein;
pick(#{used := U}, combined) -> U.

protein_checks(Class, Prot) ->
    #{all := #{minhash := #{species := MS}, combined := #{species := CS}}} = Prot,
    Low = maps:get(<<"low">>, maps:get(by_minhash_confidence, Prot)),
    #{minhash := #{species := LM}, combined := #{species := LC}} = Low,
    [check(<<"held-out: proteins + MinHash right for at least as many species as MinHash alone">>,
           maps:get(right, CS) >= maps:get(right, MS), [fmt(MS), <<" -> ">>, fmt(CS)]),
     check(<<"held-out: species of MinHash's low-confidence calls, MinHash -> combined (measured)">>,
           true, [fmt(LM), <<" -> ">>, fmt(LC)]),
     check(<<"held-out: MinHash alone unchanged by the protein step">>,
           maps:get(right, MS) =:= maps:get(right, maps:get(species, Class)), fmt(MS))].

%%% 3. mutations against Wuhan-Hu-1, ours and Nextclade's

mutations_vs_nextclade(#{fasta := Fasta}, #{refs := Refs, nextclade := Next}) ->
    Chunks = split(Fasta, 100),
    {Ours, S1} = secs(fun() -> lists:append(pq_rexec:map([{pq_task, gh_mutations, {mutations, C, Refs, <<"NC_045512.2">>}}
                                                         || C <- Chunks], local, #{})) end),
    {Theirs, S2} = secs(fun() -> lists:append(pq_rexec:map([{pq_task, gh_lineage, {lineage, C, Next}} || C <- Chunks],
                                                          local, #{})) end),
    T = maps:from_list([{maps:get(query, L), L} || L <- Theirs]),
    Cmp = [begin
               Q = maps:get(query, O),
               L = maps:get(Q, T),
               Mine = case O of
                          #{aligned := true, substitutions := Ss} ->
                              lists:sort([<<R/binary, (integer_to_binary(P))/binary, A/binary>> || [P, R, A] <- Ss]);
                          _ -> []
                      end,
               NC = lists:sort(maps:get(substitutions, L)),
               Diff = (Mine -- NC) ++ (NC -- Mine),
               {Q, Mine =:= NC, length(Diff), maps:get(qc, L), [kind(D, O) || D <- Diff]}
           end || O <- Ours],
    Same = [Q || {Q, true, _, _, _} <- Cmp],
    GoodCmp = [C || {_, _, _, <<"good">>, _} = C <- Cmp],
    #{genomes => length(Cmp), identical_substitutions => length(Same),
      nextclade_good => length(GoodCmp), identical_among_good => length([Q || {Q, true, _, _, _} <- GoodCmp]),
      differences_among_good => count(lists:append([K || {_, _, _, _, K} <- GoodCmp])),
      differing => [#{query => Q, differences => D, qc => QC, kinds => K} || {Q, false, D, QC, K} <- Cmp],
      mutations_seconds => S1, nextclade_seconds => S2,
      lineages => count([maps:get(pango, L) || L <- Theirs]),
      per_genome => maps:map(fun(_, L) -> maps:with([clade, pango, qc, total_missing], L) end, T)}.

%% Where a difference between the two callers lies: at a genome end (the first or last 100 bases of the reference,
%% or outside our alignment: minimap2 clips mismatches at the ends, Nextclade aligns to the end), next to an indel
%% (within 10 bases of one of our insertions or deletions, where the aligners may place a change differently), or
%% elsewhere ("other").
kind(<<_, Rest/binary>>, O) ->
    Pos = binary_to_integer(binary:part(Rest, 0, byte_size(Rest) - 1)),
    Near = fun(P, L) -> Pos >= P - 10 andalso Pos =< P + L + 10 end,
    {Start, End} = {maps:get(ref_start, O, 1), maps:get(ref_end, O, 29903)},
    if Pos =< 100; Pos > 29903 - 100; Pos < Start; Pos > End -> genome_end;
       true ->
           case [x || [P, L] <- maps:get(deletions, O, []), Near(P, L)]
                ++ [x || [P, _] <- maps:get(insertions, O, []), Near(P, 0)] of
               [] -> other;
               _ -> next_to_indel
           end
    end.

%%% 4. targets

targets(Params = #{refs := Refs}, #{fasta := Fasta}) ->
    Recs = gh_fasta:records(gh_store:path(Fasta)),
    %% a 10 MB upload: SARS-CoV-2 genomes up to 10 MB, through the genome job (validate .. knowledge)
    {Ten, _} = lists:foldl(fun({Id, R}, {Acc, Size}) ->
                                   B = iolist_to_binary([<<">">>, Id, string:trim(R, trailing, "\n"), <<"\n">>]),
                                   case Size + byte_size(B) =< 10000000 of
                                       true -> {[B | Acc], Size + byte_size(B)};
                                       false -> {Acc, 10000001}
                                   end
                           end, {[], 0}, Recs),
    TenH = gh_store:put_binary(lists:reverse(Ten)),
    {TenJob, TenSecs} = secs(fun() -> Id = gh_jobs:submit(genome, [TenH], Params), gh_jobs:wait(Id, 600000) end),
    TenSteps = gh_jobs:steps(maps:get(id, TenJob)),
    %% 1,000 sequences classified: 10 tasks of 100 on the local executor
    Chunks = split(Fasta, 100),
    {Calls, ClassSecs} = secs(fun() -> lists:append(pq_rexec:map([{pq_task, gh_classify, {classify, C, Refs, 10}}
                                                                 || C <- Chunks], local, #{})) end),
    %% trees of the 1,000 genomes and the reference
    Trees = [begin
                 {#{newick := N, sequences := S}, Secs} =
                     secs(fun() -> pq_task:run({pq_task, gh_tree, {tree, Fasta, Refs, <<"NC_045512.2">>, M}}, node()) end),
                 {M, #{seconds => Secs, sequences => S, newick => N, leaves => count_leaves(gh_store:read(N))}}
             end || M <- [nj, fasttree]],
    #{ten_mb => #{bytes => iolist_size(Ten), genomes => length(Ten), seconds => TenSecs, state => maps:get(state, TenJob),
                  step_seconds => step_seconds(TenSteps)},
      classify_1000 => #{sequences => length(Calls), seconds => ClassSecs,
                         species => count([maps:get(<<"species">>, maps:get(<<"call">>, C), none) || C <- Calls])},
      trees => maps:from_list(Trees)}.

%% names in a Newick tree: the labels before ':' that follow '(' or ','
count_leaves(Nwk) ->
    case re:run(Nwk, "[(,][^(),:;]+:", [global]) of
        {match, L} -> length(L);
        nomatch -> 0
    end.

%%% checks

checks(G, R, C, M, T) ->
    Sp = <<"Betacoronavirus pandemicum">>,
    [check(<<"example genome: job done">>, maps:get(state, G) =:= done, maps:get(state, G)),
     check(<<"example genome: SARS-CoV-2 species">>, maps:get(<<"species">>, maps:get(call, G)) =:= Sp,
           maps:get(<<"species">>, maps:get(call, G))),
     check(<<"example genome: no mutations against itself">>, maps:get(substitutions, G) =:= 0, maps:get(substitutions, G)),
     check(<<"example genome: lineage B, clade 19A">>, {maps:get(pango, G), maps:get(clade, G)} =:= {<<"B">>, <<"19A">>},
           [maps:get(pango, G), <<" ">>, maps:get(clade, G)])]
    ++ case R of skipped -> []; _ -> reads_checks(R, Sp) end
    ++ [check(<<"held-out: species accuracy at high confidence >= 95%">>,
              acc(maps:get(species, maps:get(<<"high">>, maps:get(by_confidence, C)))) >= 0.95,
              maps:get(species, maps:get(<<"high">>, maps:get(by_confidence, C)))),
        check(<<"held-out: family accuracy >= 95%">>, acc(maps:get(family, C)) >= 0.95, maps:get(family, C)),
        check(<<"SARS-CoV-2 1,000: substitutions = Nextclade's in genomes it rates good, except at genome ends and next to indels">>,
              maps:get(other, maps:get(differences_among_good, M), 0) =:= 0,
              [integer_to_binary(maps:get(identical_among_good, M)), <<" of ">>, integer_to_binary(maps:get(nextclade_good, M)),
               <<" identical; differences ">>, fmt(maps:get(differences_among_good, M))]),
        check(<<"target: 10 MB processed in < 5 s">>, maps:get(seconds, maps:get(ten_mb, T)) < 5, maps:get(seconds, maps:get(ten_mb, T))),
        check(<<"target: 1,000 sequences classified in < 60 s">>, maps:get(seconds, maps:get(classify_1000, T)) < 60,
              maps:get(seconds, maps:get(classify_1000, T))),
        check(<<"target: tree of 1,000 in < 300 s, all leaves (neighbour-joining)">>, tree_ok(nj, T, 300),
              maps:get(nj, maps:get(trees, T))),
        %% the maximum-likelihood tree is measured, not held to the target: FastTree takes 8-11 minutes on 10 cores for
        %% 1,000 SARS-CoV-2 genomes whatever its options (acceptance/RESULTS.md)
        check(<<"maximum-likelihood tree of 1,000 (FastTree): all leaves; time measured">>, tree_ok(fasttree, T, infinity),
              maps:get(fasttree, maps:get(trees, T)))].

%% part 1's reads example: the only checks that need the human reference (a reduced run skips them)
reads_checks(R, Sp) ->
    [check(<<"example reads: job done">>, maps:get(state, R) =:= done, maps:get(state, R)),
     check(<<"example reads: human pairs removed (>= 99%)">>, maps:get(human_kept, R) =< 200, maps:get(human_kept, R)),
     check(<<"example reads: viral pairs kept (>= 99%)">>, maps:get(viral_kept, R) >= 19800, maps:get(viral_kept, R)),
     check(<<"example reads: consensus = source at every called base">>,
           maps:get(substitutions, maps:get(consensus_vs_source, R)) =:= 0, maps:get(consensus_vs_source, R)),
     check(<<"example reads: SARS-CoV-2 species">>, maps:get(<<"species">>, maps:get(call, R)) =:= Sp,
           maps:get(<<"species">>, maps:get(call, R))),
     check(<<"example reads: lineage of the source genome">>, maps:get(pango, R) =:= maps:get(source_pango, R),
           [maps:get(pango, R), <<" vs ">>, maps:get(source_pango, R)])].

tree_ok(M, T, Limit) ->
    #{seconds := S, sequences := N, leaves := L} = maps:get(M, maps:get(trees, T)),
    (Limit =:= infinity orelse S < Limit) andalso L =:= N.

acc(#{accuracy := null}) -> 0;
acc(#{accuracy := A}) -> A.

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => fmt(Value)}.

fmt(V) when is_binary(V) -> V;
fmt(V) when is_list(V) -> iolist_to_binary([fmt(X) || X <- V]);
fmt(V) -> iolist_to_binary(io_lib:format("~0p", [V])).

%% maps with tuple keys and atoms as JSON
jsonable(M) when is_map(M) -> maps:from_list([{key(K), jsonable(V)} || {K, V} <- maps:to_list(M)]);
jsonable(L) when is_list(L) -> [jsonable(X) || X <- L];
jsonable(T) when is_tuple(T) -> [jsonable(X) || X <- tuple_to_list(T)];
jsonable(A) when is_atom(A), A =/= true, A =/= false, A =/= null -> atom_to_binary(A);
jsonable(X) -> X.

key({A, B}) -> <<(key(A))/binary, "_", (key(B))/binary>>;
key(A) when is_atom(A) -> atom_to_binary(A);
key(B) when is_binary(B) -> B;
key(I) when is_integer(I) -> integer_to_binary(I).
