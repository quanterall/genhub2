%% The analyses of FS 4.4 as steps of PQCF tasks. A job is a genome upload ({genome, [FileHash]}) or a read-pair
%% upload ({reads, [R1Hash, R2Hash]}); each step's tasks are built from the job and the earlier steps' results, and
%% run by PQCF's executor (gh_jobs). Every task's result is a pure function of the task, so a step that was
%% interrupted is simply run again.
%%   genome: validate, classify, protein, mutations, lineage, knowledge
%%   reads:  validate, dehost, kraken, screen, consensus, classify, protein, mutations, lineage, knowledge
%% kraken runs when the site has a Kraken 2 database (params kraken); consensus trims primers when the job names a
%% primer scheme (params primers).
%% protein runs only for the sequences MinHash classified with low confidence or not at all (gh_protein).
%%   tree:   align, distance, tree, bootstrap, support: a tree of the genomes of earlier jobs ({tree, [GenomesHash]},
%%           params reference, method and bootstrap, the number of replicates; gh_phylo). Distance tiles and
%%           replicates are for neighbour-joining; a maximum-likelihood tree is one task.
%%
%% Placement (FS 3.3): the steps that read a lab's raw data (the upload, its reads) run on the coordinating node
%% (home), the others on whichever nodes the site's executor has (spread). Only results and genomes leave the
%% home node, and only to the lab's own nodes.
%% Params: #{refs := ViralRefBundle, host := HostBundle, nextclade := DatasetBundle, min_depth := N}
-module(gh_pipeline).
-export([steps/1, placement/1, tasks/3, genome/2]).

-define(SARS_COV_2_REF, <<"NC_045512.2">>).
%% genomes per align task, rows per distance tile
-define(ALIGN_CHUNK, 100).
-define(TILE_ROWS, 128).
%% bootstrap replicates per task
-define(BOOT_BATCH, 10).

-spec steps(genome | reads | tree) -> [atom()].
steps(genome) -> [validate, classify, protein, mutations, lineage, knowledge];
steps(reads) -> [validate, dehost, kraken, screen, consensus, classify, protein, mutations, lineage, knowledge];
steps(tree) -> [align, distance, tree, bootstrap, support].

%% where a step's tasks run: home (the coordinating node: the lab's raw data) or spread (the site's executor)
-spec placement(atom()) -> home | spread.
placement(S) when S =:= validate; S =:= dehost; S =:= kraken; S =:= screen; S =:= consensus -> home;
placement(_) -> spread.

%% The step's tasks; Done: Step => [Result] of the steps before it.
-spec tasks(atom(), map(), #{atom() => [term()]}) -> [pq_task:task()].
tasks(align, #{inputs := [Genomes], params := #{refs := Refs, reference := Acc}}, _) ->
    [{pq_task, gh_phylo, {align, C, Refs, Acc, K =:= 1}} || {K, C} <- lists:enumerate(gh_phylo:chunks(Genomes, ?ALIGN_CHUNK))];
tasks(distance, #{params := #{method := nj}}, #{align := A}) ->
    Aligned = gh_phylo:join(A),
    N = 1 + lists:sum([S || #{sequences := S} <- A]),
    [{pq_task, gh_phylo, {distance_block, Aligned, I0, I1, J0, J1}} || {I0, I1, J0, J1} <- gh_phylo:tiles(N, ?TILE_ROWS)];
tasks(distance, _Job, _Done) -> [];
tasks(tree, #{params := #{method := nj}}, #{align := A, distance := Tiles}) ->
    [{pq_task, gh_phylo, {njtiles, gh_phylo:join(A), Tiles}}];
tasks(tree, #{params := #{method := M}}, #{align := A}) ->
    [{pq_task, gh_tree, {ml, gh_phylo:join(A), M}}];
tasks(bootstrap, #{params := #{method := nj} = P}, #{align := A}) ->
    N = maps:get(bootstrap, P, 0),
    Aligned = gh_phylo:join(A),
    [{pq_task, gh_phylo, {bootstraps, Aligned, First, min(?BOOT_BATCH, N - First + 1)}} || First <- lists:seq(1, N, ?BOOT_BATCH)];
tasks(bootstrap, _Job, _Done) -> [];
tasks(support, _Job, #{bootstrap := []}) -> [];
tasks(support, _Job, #{tree := [#{newick := T}], bootstrap := Reps}) ->
    [{pq_task, gh_phylo, {support, T, Reps}}];
tasks(validate, #{inputs := Files}, _) ->
    [{pq_task, gh_validate, {validate, F}} || F <- Files];
tasks(dehost, #{params := #{host := Host}}, #{validate := V}) ->
    [R1, R2] = [valid(R) || R <- V],
    [{pq_task, gh_dehost, {dehost, R1, R2, Host}}];
tasks(kraken, #{params := #{kraken := K}}, #{dehost := [#{r1 := R1, r2 := R2}], validate := [V1 | _]})
  when K =/= undefined ->
    #{report := #{<<"max_length">> := Len}} = V1,
    [{pq_task, gh_kraken, {kraken, R1, R2, K, Len}}];
tasks(kraken, _Job, _Done) -> [];
tasks(screen, #{params := #{refs := Refs}}, #{dehost := [#{r1 := R1, r2 := R2}]}) ->
    [{pq_task, gh_screen, {screen, R1, R2, Refs, 5}}];
tasks(consensus, #{params := #{refs := Refs} = P}, #{dehost := [#{r1 := R1, r2 := R2}], screen := [S]}) ->
    case maps:get(<<"hits">>, S) of
        [] -> error(no_viral_reference_found);
        [#{<<"ref">> := Acc} | _] ->
            [{pq_task, gh_consensus, {consensus, R1, R2, Refs, Acc, maps:get(min_depth, P, 10), maps:get(primers, P, none)}}]
    end;
tasks(classify, #{params := #{refs := Refs}} = Job, Done) ->
    [{pq_task, gh_classify, {classify, genome(Job, Done), Refs, 10}}];
tasks(protein, #{params := #{proteins := Proteins}} = Job, #{classify := [Calls]} = Done) when Proteins =/= undefined ->
    Weak = [Q || #{<<"query">> := Q, <<"call">> := #{<<"confidence">> := C}} <- Calls,
                 C =:= <<"low">> orelse C =:= <<"unclassified">>],
    case Weak of
        [] -> [];
        _ -> [{pq_task, gh_protein, {protein, subset(genome(Job, Done), Weak), Proteins}}]
    end;
tasks(protein, _Job, _Done) -> [];
tasks(mutations, #{params := #{refs := Refs}} = Job, #{classify := [Calls]} = Done) ->
    [{pq_task, gh_mutations, {mutations, G, Refs, Acc}} || {Acc, G} <- by_reference(genome(Job, Done), Calls)];
tasks(lineage, #{params := #{nextclade := Dataset}} = Job, #{classify := [Calls]} = Done) ->
    case is_map_key("minimizer_index.json", gh_refs:manifest(Dataset, node())) of
        true -> [{pq_task, gh_lineage, {lineage, genome(Job, Done), Dataset}}];     % nextclade sort picks datasets
        false -> [{pq_task, gh_lineage, {lineage, G, Dataset}}
                  || {Acc, G} <- by_reference(genome(Job, Done), Calls), Acc =:= ?SARS_COV_2_REF]
    end;
tasks(knowledge, _Job, #{classify := [Calls]}) ->
    lists:usort([{pq_task, gh_knowledge, {knowledge, maps:get(<<"taxid">>, C), maps:get(<<"organism">>, C)}}
                 || #{<<"call">> := C} <- Calls, is_map_key(<<"taxid">>, C)]).

valid(#{ok := true, output := H}) -> H;
valid(#{ok := false, report := R}) -> error({invalid_input, maps:get(<<"problems">>, R)}).

%% the job's genome file: the validated upload, or the consensus from its reads
-spec genome(map(), map()) -> gh_store:hash().
genome(#{kind := genome}, #{validate := [V]}) -> valid(V);
genome(#{kind := reads}, #{consensus := [#{genome := G}]}) -> G.

%% a file of the named records of a FASTA file in the store
subset(Genome, Ids) ->
    gh_store:put_binary([[<<">">>, Id, string:trim(R, trailing, "\n"), <<"\n">>]
                         || {Id, R} <- gh_fasta:records(gh_store:path(Genome)), lists:member(Id, Ids)]).

%% The genomes grouped by the reference of their call: [{Accession, FileHash}], each file the group's records.
by_reference(Genome, Calls) ->
    Refs = [{Q, R} || #{<<"query">> := Q, <<"call">> := #{<<"ref">> := R}} <- Calls],
    case lists:usort([R || {_, R} <- Refs]) of
        [] -> [];
        [Only] -> [{Only, Genome}];
        Accs ->
            Recs = gh_fasta:records(gh_store:path(Genome)),
            Of = maps:from_list(Refs),
            [{Acc, gh_store:put_binary([[<<">">>, Id, string:trim(Rest, trailing, "\n"), <<"\n">>] || {Id, Rest} <- Recs, maps:get(Id, Of, none) =:= Acc])}
             || Acc <- Accs]
    end.
