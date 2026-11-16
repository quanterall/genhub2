%% Phase B's acceptance test (plan section 5, FS 6.3): a lab's work spread over its own nodes with PQCF's {nodes, ...}
%% executor. Done when the results are identical to one node's and the speed-up is measured.
%%
%%   0. The worker: one of the lab's further nodes (role worker, its own store). Its first tasks fetch the reference
%%      bundles from this node by hash; the time and size are recorded.
%%   1. Workloads, each run on this node alone (local) and on this node and the worker ({nodes, ...}), alternately,
%%      twice each: classification of 1,593 genomes (MinHash), of the 593 held-out genomes by proteins (DIAMOND),
%%      mutations and lineages of 1,000 SARS-CoV-2 genomes, and a tree of the 1,000 and the reference in its parts
%%      (align, distance tiles, neighbour-joining, 100 bootstrap replicates, support). The results of all runs must be
%%      identical, and the tree byte for byte phase A's (one task, gh2k nj on the whole alignment).
%%   2. Jobs through the job service with executor {nodes, ...}: a tree job with 100 replicates gives the tree and
%%      support of part 1; a genome job's validate step (the lab's upload) runs on this node.
%%
%% Results: acceptance/results/phase-b-<host>-<date>.json; exit status 0 when every check holds.
%%   sh acceptance/run_phase_b.sh
-module(gh_phase_b).
-export([main/1]).

-define(NEXTCLADE_TAG, "2026-10-28--15-04-26Z").
-define(REF, <<"NC_045512.2">>).
-define(REPLICATES, 100).
-define(PHASE_A, "acceptance/results/phase-a-dgx-spark-2026-11-14T0031Z.json").

-spec main([string()]) -> no_return().
main([Worker, Out]) ->
    {ok, _} = application:ensure_all_started(genhub2),
    T0 = erlang:monotonic_time(millisecond),
    W = list_to_atom(Worker),
    ok = connect(W, 120),
    Nodes = {nodes, [node(), W]},
    Slots = #{node() => erlang:system_info(dirty_cpu_schedulers_online),
              W => erpc:call(W, erlang, system_info, [dirty_cpu_schedulers_online])},
    log(io_lib:format("nodes ~p", [Slots])),
    Refs = gh_refdb:refseq_viral(),
    Proteins = gh_refdb:viral_proteins(),
    Next = gh_refdb:nextclade(?NEXTCLADE_TAG),
    log("data: held-out set and SARS-CoV-2 genomes"),
    #{fasta := Held} = gh_acceptance:held_out(Refs),
    #{fasta := Sars} = gh_acceptance:sars_cov_2(),
    log("0. the worker's reference copies"),
    Replica = replicate(W, Refs, Proteins, Next, Sars),
    log("1. workloads"),
    Work = [{classify, fun() -> chunked(Sars, 50, fun(C) -> {gh_classify, {classify, C, Refs, 10}} end)
                                    ++ chunked(Held, 50, fun(C) -> {gh_classify, {classify, C, Refs, 10}} end) end},
            {protein, fun() -> chunked(Held, 60, fun(C) -> {gh_protein, {protein, C, Proteins}} end) end},
            {mutations, fun() -> chunked(Sars, 50, fun(C) -> {gh_mutations, {mutations, C, Refs, ?REF}} end) end},
            {lineage, fun() -> chunked(Sars, 50, fun(C) -> {gh_lineage, {lineage, C, Next}} end) end}],
    Runs = [{Name, [run_tasks(Name, Make(), E) || _ <- [1, 2], E <- [local, Nodes]]} || {Name, Make} <- Work]
        ++ [{tree, [tree(Sars, Refs, E) || _ <- [1, 2], E <- [local, Nodes]]}],
    log("2. jobs on two nodes"),
    Jobs = jobs(Nodes, Sars, Refs, Proteins, Next),
    Summary = [{Name, summary(Rs, W)} || {Name, Rs} <- Runs],
    PhaseA = phase_a_tree(),
    Checks = checks(W, Slots, Replica, Summary, PhaseA, Jobs),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), coordinator => node(), worker => W, slots => Slots,
          pqcf => <<"2a90a1f">>, bundles => #{refseq_viral => Refs, refseq_viral_proteins => Proteins, nextclade => Next},
          genomes => #{sars_cov_2 => Sars, held_out => Held},
          worker_references => Replica, workloads => maps:from_list(Summary), jobs => Jobs,
          phase_a_nj_tree => PhaseA, checks => Checks,
          seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(jsonable(R))),
    Failed = [C || #{ok := false} = C <- Checks],
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    io:format("~b of ~b checks hold~nwritten ~s~n", [length(Checks) - length(Failed), length(Checks), Out]),
    halt(case Failed of [] -> 0; _ -> 1 end).

log(S) -> io:format("~s ~s~n", [calendar:system_time_to_rfc3339(erlang:system_time(second)), S]).

secs(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = F(),
    {R, (erlang:monotonic_time(microsecond) - T0) / 1.0e6}.

connect(W, 0) -> error({no_worker, W});
connect(W, N) ->
    case net_adm:ping(W) of
        pong -> ok;
        pang -> receive after 1000 -> connect(W, N - 1) end
    end.

chunked(Fasta, Size, Task) ->
    [{pq_task, M, A} || C <- gh_phylo:chunks(Fasta, Size), {M, A} <- [Task(C)]].

exec_name(local) -> local;
exec_name({nodes, _}) -> nodes.

%% the tasks on the executor: #{exec, seconds, results (without provenance), per_node}
run_tasks(Name, Tasks, Exec) ->
    {R, S} = secs(fun() -> pq_rexec:map_traced(Tasks, Exec, #{}) end),
    log(io_lib:format("   ~s on ~s: ~b tasks, ~.1f s", [Name, exec_name(Exec), length(Tasks), S])),
    #{exec => exec_name(Exec), seconds => S, tasks => length(Tasks), results => [X || {X, _} <- R],
      per_node => per_node(R)}.

per_node(Traced) ->
    lists:foldl(fun({_, #{node := N}}, M) -> maps:update_with(N, fun(K) -> K + 1 end, 1, M) end, #{}, Traced).

%% 0. the worker fetches the bundles its first tasks need from this node, by hash, and checks them
replicate(W, Refs, Proteins, Next, Sars) ->
    Root = erpc:call(W, gh_store, root, []),
    Size = fun() ->
                   case string:to_integer(erpc:call(W, os, cmd, ["du -sb '" ++ Root ++ "' 2>/dev/null || echo 0"])) of
                       {N, _} when is_integer(N) -> N;
                       _ -> 0
                   end
           end,
    Before = Size(),
    [One | _] = gh_phylo:chunks(Sars, 1),
    Tasks = [{pq_task, gh_classify, {classify, One, Refs, 10}}, {pq_task, gh_protein, {protein, One, Proteins}},
             {pq_task, gh_mutations, {mutations, One, Refs, ?REF}}, {pq_task, gh_lineage, {lineage, One, Next}}],
    {_, S} = secs(fun() -> pq_rexec:map(Tasks, {nodes, [W]}, #{slots => [W]}) end),
    After = Size(),
    log(io_lib:format("   ~.1f GB in ~.1f s", [(After - Before) / 1.0e9, S])),
    #{seconds => S, bytes => After - Before}.

%% the tree of the genomes and the reference in its parts, each part's tasks on the executor
tree(Sars, Refs, Exec) ->
    {A, SA} = secs(fun() -> [X || {X, _} <- pq_rexec:map_traced([{pq_task, gh_phylo, {align, C, Refs, ?REF, K =:= 1}}
                                                                 || {K, C} <- lists:enumerate(gh_phylo:chunks(Sars, 100))],
                                                                Exec, #{})] end),
    Aligned = gh_phylo:join(A),
    N = 1 + lists:sum([S || #{sequences := S} <- A]),
    TileTasks = [{pq_task, gh_phylo, {distance_block, Aligned, I0, I1, J0, J1}} || {I0, I1, J0, J1} <- gh_phylo:tiles(N, 128)],
    {TilesTraced, SD} = secs(fun() -> pq_rexec:map_traced(TileTasks, Exec, #{}) end),
    Tiles = [X || {X, _} <- TilesTraced],
    {[#{newick := Nwk}], SN} = secs(fun() -> pq_rexec:map([{pq_task, gh_phylo, {njtiles, Aligned, Tiles}}], Exec, #{}) end),
    BootTasks = [{pq_task, gh_phylo, {bootstrap, Aligned, Seed}} || Seed <- lists:seq(1, ?REPLICATES)],
    {BootTraced, SB} = secs(fun() -> pq_rexec:map_traced(BootTasks, Exec, #{}) end),
    Reps = [X || {X, _} <- BootTraced],
    {[#{newick := Sup}], SS} = secs(fun() -> pq_rexec:map([{pq_task, gh_phylo, {support, Nwk, Reps}}], Exec, #{}) end),
    Total = SA + SD + SN + SB + SS,
    log(io_lib:format("   tree on ~s: align ~.1f s, ~b tiles ~.1f s, nj ~.1f s, ~b replicates ~.1f s, support ~.1f s",
                      [exec_name(Exec), SA, length(Tiles), SD, SN, ?REPLICATES, SB, SS])),
    #{exec => exec_name(Exec), seconds => Total, tasks => length(A) + length(Tiles) + 2 + ?REPLICATES,
      parts => #{align => SA, distance => SD, nj => SN, bootstrap => SB, support => SS},
      results => #{aligned => Aligned, tiles => Tiles, newick => Nwk, replicates => Reps, support => Sup},
      per_node => per_node(TilesTraced ++ BootTraced)}.

%% per workload: the times of every run, whether all runs agree, the best time per executor and the speed-up
summary(Runs, W) ->
    [First | _] = Runs,
    Same = lists:all(fun(#{results := R}) -> R =:= maps:get(results, First) end, Runs),
    Best = fun(E) -> lists:min([S || #{exec := X, seconds := S} <- Runs, X =:= E]) end,
    NodesRuns = [R || #{exec := nodes} = R <- Runs],
    OnWorker = lists:min([maps:get(W, P, 0) || #{per_node := P} <- NodesRuns]),
    Out = #{runs => [maps:without([results], R) || R <- Runs], identical => Same, best_local => Best(local),
            best_nodes => Best(nodes), speedup => Best(local) / Best(nodes), tasks_on_worker_min => OnWorker,
            tasks => maps:get(tasks, First)},
    case maps:get(results, First) of
        #{newick := N, support := S} -> Out#{newick => N, support => S};
        _ -> Out
    end.

%% 2. jobs through the job service, the steps that may leave this node on both
jobs(Nodes, Sars, Refs, Proteins, Next) ->
    ok = application:set_env(genhub2, executor, Nodes),
    Params = #{refs => Refs, proteins => Proteins, nextclade => Next, min_depth => 10},
    {TreeJob, TS} = secs(fun() ->
                                 Id = gh_jobs:submit(tree, [Sars], Params#{reference => ?REF, method => nj,
                                                                          bootstrap => ?REPLICATES}),
                                 gh_jobs:wait(Id, 3600000)
                         end),
    TreeView = gh_jobs:view(maps:get(id, TreeJob)),
    [One | _] = gh_phylo:chunks(Sars, 1),
    {GenomeJob, GS} = secs(fun() -> Id = gh_jobs:submit(genome, [One], Params), gh_jobs:wait(Id, 600000) end),
    GenomeView = gh_jobs:view(maps:get(id, GenomeJob)),
    ok = application:set_env(genhub2, executor, local),
    #{tree => job_summary(TreeView, TS), genome => job_summary(GenomeView, GS)}.

job_summary(#{id := Id, state := State, steps := Steps}, Secs) ->
    StepNodes = maps:map(fun(_, #{provenance := P}) -> lists:usort([N || #{node := N} <- P]) end, Steps),
    Res = fun(S) -> case Steps of #{S := #{results := [R]}} -> R; _ -> null end end,
    #{id => Id, state => State, seconds => Secs, step_nodes => StepNodes,
      newick => case Res(tree) of #{newick := N} -> N; _ -> null end,
      support => case Res(support) of #{newick := N} -> N; _ -> null end}.

phase_a_tree() ->
    {ok, B} = file:read_file(?PHASE_A),
    #{<<"targets">> := #{<<"trees">> := #{<<"nj">> := #{<<"newick">> := N}}}} = json:decode(B),
    N.

checks(W, Slots, Replica, Summary, PhaseA, #{tree := TJ, genome := GJ}) ->
    S = maps:from_list(Summary),
    Tree = maps:get(tree, S),
    Home = node(),
    [check(<<"two nodes">>, maps:size(Slots) =:= 2, Slots),
     check(<<"the worker fetched its references by hash">>, maps:get(bytes, Replica) > 0, maps:get(bytes, Replica))]
    ++ lists:append(
         [[check(<<(atom_to_binary(N))/binary, ": identical results in all four runs">>, maps:get(identical, X), maps:get(tasks, X)),
           check(<<(atom_to_binary(N))/binary, ": the worker ran tasks">>, maps:get(tasks_on_worker_min, X) > 0,
                 maps:get(tasks_on_worker_min, X))]
          || {N, X} <- Summary])
    ++ [check(<<"tree from tiles = phase A's tree (one task, gh2k nj)">>, maps:get(newick, Tree) =:= PhaseA, PhaseA),
        check(<<"bootstrap and tree faster on two nodes">>, maps:get(speedup, Tree) > 1.0, maps:get(speedup, Tree)),
        check(<<"tree job done">>, maps:get(state, TJ) =:= done, maps:get(state, TJ)),
        check(<<"tree job: the tree of part 1">>, maps:get(newick, TJ) =:= maps:get(newick, Tree), maps:get(newick, TJ)),
        check(<<"tree job: the support of part 1">>, maps:get(support, TJ) =:= maps:get(support, Tree), maps:get(support, TJ)),
        check(<<"tree job: distance tiles and replicates ran on both nodes">>,
              [lists:sort(maps:get(St, maps:get(step_nodes, TJ))) || St <- [distance, bootstrap]] =:= [lists:sort([Home, W]), lists:sort([Home, W])],
              maps:get(step_nodes, TJ)),
        check(<<"genome job done">>, maps:get(state, GJ) =:= done, maps:get(state, GJ)),
        check(<<"genome job: the upload validated on this node only">>,
              maps:get(validate, maps:get(step_nodes, GJ)) =:= [Home], maps:get(step_nodes, GJ))].

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => iolist_to_binary(io_lib:format("~0p", [Value]))}.

jsonable(M) when is_map(M) -> maps:from_list([{key(K), jsonable(V)} || {K, V} <- maps:to_list(M)]);
jsonable(L) when is_list(L) -> [jsonable(X) || X <- L];
jsonable(T) when is_tuple(T) -> [jsonable(X) || X <- tuple_to_list(T)];
jsonable(A) when is_atom(A), A =/= true, A =/= false, A =/= null -> atom_to_binary(A);
jsonable(X) -> X.

key(A) when is_atom(A) -> atom_to_binary(A);
key(B) when is_binary(B) -> B;
key(I) when is_integer(I) -> integer_to_binary(I).
