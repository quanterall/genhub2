%% Trees spread over tasks (gh_phylo) and over nodes: tiles, bootstrap and support give what one task gives, and a
%% second Erlang node (a peer with its own store) computes the same results as this one.
-module(gh_phylo_tests).
-include_lib("eunit/include/eunit.hrl").

placement_test() ->
    %% the steps that read a lab's raw data stay on the coordinating node
    [?assertEqual(home, gh_pipeline:placement(S)) || S <- [validate, dehost, kraken, screen, consensus]],
    [?assertEqual(spread, gh_pipeline:placement(S))
     || S <- [classify, protein, mutations, lineage, knowledge, align, distance, tree, bootstrap, support]],
    %% every step of every job kind has a placement
    [_ = gh_pipeline:placement(S) || K <- [genome, reads, tree], S <- gh_pipeline:steps(K)].

tiles_cover_every_pair_once_test() ->
    [begin
         Pairs = [{I, J} || {I0, I1, J0, J1} <- gh_phylo:tiles(N, Size), I <- lists:seq(I0, I1 - 1),
                            J <- lists:seq(J0, J1 - 1), I < J],
         ?assertEqual(lists:usort(Pairs), lists:sort(Pairs)),
         ?assertEqual(N * (N - 1) div 2, length(Pairs))
     end || {N, Size} <- [{1, 4}, {5, 2}, {9, 4}, {10, 3}, {128, 128}, {129, 128}]].

phylo_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(#{aligned := A} = S) ->
             [{"tiles give gh2k nj's tree", fun() -> tiles_equal_nj(A) end},
              {"replicates are seeded", fun() -> replicates(A) end},
              {"support labels the tree", fun() -> support(A) end},
              {"a second node gives the same results", {timeout, 120, fun() -> two_nodes(S) end}}]
     end}.

setup() ->
    Dir = filename:join("/tmp", "gh-phylo-" ++ os:getpid()),
    _ = application:load(genhub2),
    ok = application:set_env(genhub2, data_dir, filename:join(Dir, "home")),
    pq_task:allow(gh_phylo),
    #{dir => Dir, aligned => gh_store:put_binary(alignment(23, 400))}.

cleanup(#{dir := Dir}) -> file:del_dir_r(Dir).

run(T) -> pq_task:run({pq_task, gh_phylo, T}, node()).

%% N sequences of Len columns that descend from one another, with gaps and Ns, deterministic
alignment(N, Len) ->
    rand:seed(exsss, {1, 2, 3}),
    Root = [lists:nth(rand:uniform(4), "ACGT") || _ <- lists:seq(1, Len)],
    Seqs = lists:foldl(fun(_, [Prev | _] = Acc) -> [mutate(lists:nth(rand:uniform(length(Acc)), Acc ++ [Prev])) | Acc] end,
                       [Root], lists:seq(2, N)),
    [[">s", integer_to_list(K), "\n", S, "\n"] || {K, S} <- lists:enumerate(lists:reverse(Seqs))].

mutate(S) ->
    [case rand:uniform(100) of
         1 -> lists:nth(rand:uniform(4), "ACGT");
         2 -> $N;
         3 -> $-;
         _ -> C
     end || C <- S].

tree_by_tiles(A, Size, Exec) ->
    Tiles = pq_rexec:map([{pq_task, gh_phylo, {distance_block, A, I0, I1, J0, J1}} || {I0, I1, J0, J1} <- gh_phylo:tiles(23, Size)],
                         Exec, #{}),
    #{newick := T} = run({njtiles, A, Tiles}),
    gh_store:read(T).

tiles_equal_nj(A) ->
    Whole = gh_tool:gh2k_must(["nj", gh_store:path(A)]),
    [?assertEqual(Whole, tree_by_tiles(A, Size, local)) || Size <- [1, 5, 8, 23]],
    #{sequences := 23, columns := 400} = run({njtiles, A, [run({distance_block, A, 0, 23, 0, 23})]}).

replicates(A) ->
    R1 = run({bootstrap, A, 1}),
    ?assertEqual(R1, run({bootstrap, A, 1})),
    ?assertNotEqual(R1, run({bootstrap, A, 2})).

support(A) ->
    #{newick := T} = run({njtiles, A, [run({distance_block, A, 0, 23, 0, 23})]}),
    #{newick := S, replicates := 20} = run({support, T, [run({bootstrap, A, K}) || K <- lists:seq(1, 20)]}),
    Labels = [binary_to_integer(L) || {node, [_ | _], L, _} <- subtrees(gh_export:newick(gh_store:read(S))), L =/= <<>>],
    ?assertEqual(20, length(Labels)),     % an unrooted binary tree of 23 leaves has 20 internal branches
    ?assert(lists:all(fun(L) -> L >= 0 andalso L =< 100 end, Labels)),
    ?assert(lists:max(Labels) > 50).

subtrees({node, Kids, _, _} = T) -> [T | lists:append([subtrees(K) || K <- Kids])].

%% a peer node with this node's code and a store of its own: it fetches the alignment from this node by hash
two_nodes(#{dir := Dir, aligned := A}) ->
    _ = os:cmd("epmd -daemon"),
    _ = net_kernel:start(gh_phylo_test, #{name_domain => shortnames}),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(gh_worker),
                                         args => lists:append([["-pa", P] || P <- code:get_path()])}),
    try
        ok = erpc:call(Node, application, load, [genhub2]),
        ok = erpc:call(Node, application, set_env, [genhub2, data_dir, filename:join(Dir, "worker")]),
        ok = erpc:call(Node, pq_task, allow, [gh_phylo]),
        ?assertNot(erpc:call(Node, gh_store, has, [A])),
        Local = tree_by_tiles(A, 5, local),
        Spread = tree_by_tiles(A, 5, {nodes, [node(), Node]}),
        ?assertEqual(Local, Spread),
        ?assert(erpc:call(Node, gh_store, has, [A])),          % it fetched the alignment and checked its hash
        Reps = [{pq_task, gh_phylo, {bootstrap, A, K}} || K <- lists:seq(1, 8)],
        ?assertEqual(pq_rexec:map(Reps, local, #{}), pq_rexec:map(Reps, {nodes, [Node]}, #{}))
    after
        peer:stop(Peer)
    end.
