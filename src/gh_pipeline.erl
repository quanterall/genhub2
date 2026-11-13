%% The analyses of FS 4.4 as steps of PQCF tasks. A job is a genome upload ({genome, [FileHash]}) or a read-pair
%% upload ({reads, [R1Hash, R2Hash]}); each step's tasks are built from the job and the earlier steps' results, and
%% run by PQCF's executor (gh_jobs). Every task's result is a pure function of the task, so a step that was
%% interrupted is simply run again.
%%   genome: validate, classify, mutations, lineage, knowledge
%%   reads:  validate, dehost, screen, consensus, classify, mutations, lineage, knowledge
%%   tree:   tree, of the genomes of earlier jobs ({tree, [GenomesHash]}, params reference and method)
%% Params: #{refs := ViralRefBundle, host := HostBundle, nextclade := DatasetBundle, min_depth := N}
-module(gh_pipeline).
-export([steps/1, tasks/3, genome/2]).

-define(SARS_COV_2_REF, <<"NC_045512.2">>).

-spec steps(genome | reads | tree) -> [atom()].
steps(genome) -> [validate, classify, mutations, lineage, knowledge];
steps(reads) -> [validate, dehost, screen, consensus, classify, mutations, lineage, knowledge];
steps(tree) -> [tree].

%% The step's tasks; Done: Step => [Result] of the steps before it.
-spec tasks(atom(), map(), #{atom() => [term()]}) -> [pq_task:task()].
tasks(tree, #{inputs := [Genomes], params := #{refs := Refs, reference := Acc, method := M}}, _) ->
    [{pq_task, gh_tree, {tree, Genomes, Refs, Acc, M}}];
tasks(validate, #{inputs := Files}, _) ->
    [{pq_task, gh_validate, {validate, F}} || F <- Files];
tasks(dehost, #{params := #{host := Host}}, #{validate := V}) ->
    [R1, R2] = [valid(R) || R <- V],
    [{pq_task, gh_dehost, {dehost, R1, R2, Host}}];
tasks(screen, #{params := #{refs := Refs}}, #{dehost := [#{r1 := R1, r2 := R2}]}) ->
    [{pq_task, gh_screen, {screen, R1, R2, Refs, 5}}];
tasks(consensus, #{params := #{refs := Refs} = P}, #{dehost := [#{r1 := R1, r2 := R2}], screen := [S]}) ->
    case maps:get(<<"hits">>, S) of
        [] -> error(no_viral_reference_found);
        [#{<<"ref">> := Acc} | _] -> [{pq_task, gh_consensus, {consensus, R1, R2, Refs, Acc, maps:get(min_depth, P, 10)}}]
    end;
tasks(classify, #{params := #{refs := Refs}} = Job, Done) ->
    [{pq_task, gh_classify, {classify, genome(Job, Done), Refs, 10}}];
tasks(mutations, #{params := #{refs := Refs}} = Job, #{classify := [Calls]} = Done) ->
    [{pq_task, gh_mutations, {mutations, G, Refs, Acc}} || {Acc, G} <- by_reference(genome(Job, Done), Calls)];
tasks(lineage, #{params := #{nextclade := Dataset}} = Job, #{classify := [Calls]} = Done) ->
    [{pq_task, gh_lineage, {lineage, G, Dataset}}
     || {Acc, G} <- by_reference(genome(Job, Done), Calls), Acc =:= ?SARS_COV_2_REF];
tasks(knowledge, _Job, #{classify := [Calls]}) ->
    lists:usort([{pq_task, gh_knowledge, {knowledge, maps:get(<<"taxid">>, C), maps:get(<<"organism">>, C)}}
                 || #{<<"call">> := C} <- Calls, is_map_key(<<"taxid">>, C)]).

valid(#{ok := true, output := H}) -> H;
valid(#{ok := false, report := R}) -> error({invalid_input, maps:get(<<"problems">>, R)}).

%% the job's genome file: the validated upload, or the consensus from its reads
-spec genome(map(), map()) -> gh_store:hash().
genome(#{kind := genome}, #{validate := [V]}) -> valid(V);
genome(#{kind := reads}, #{consensus := [#{genome := G}]}) -> G.

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
