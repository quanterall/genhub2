%% Trees spread over many tasks (FS 5.2, plan section 3.3: distance blocks and bootstrap replicates are independent
%% tasks, so a tree job uses every node the executor has). A tree job's steps (gh_pipeline):
%%   align      genomes in chunks, each aligned to the reference      {align, ChunkHash, RefBundle, Accession, First}
%%                                                                    -> #{rows, sequences, columns}
%%   distance   tiles of the Jukes-Cantor distance matrix (gh2k dist)  {distance_block, AlignedHash, I0, I1, J0, J1}
%%                                                                    -> TileHash
%%   tree       neighbour-joining on the tiles (gh2k njtiles)          {njtiles, AlignedHash, [TileHash]}
%%              (maximum likelihood: gh_tree's {ml, ...})              -> #{newick, aligned, sequences, columns, method}
%%   bootstrap  replicates (gh2k boot; Felsenstein 1985,               {bootstrap, AlignedHash, Seed} -> NewickHash
%%              doi:10.1111/j.1558-5646.1985.tb00420.x), in batches   {bootstraps, AlignedHash, First, Count}
%%              of one task each (gh2k boots)                          -> Hash (one tree a line, seeds First..)
%%   support    the tree with each branch's support (gh2k support)    {support, NewickHash, [NewickHash]}
%%                                                                    -> #{newick, replicates}
%% Each result is a pure function of its task, and the tiling only says which tasks compute which pairs: the tree is
%% byte for byte gh2k nj's on the whole alignment, however the tiles were spread.
%%
%% distance_block, bootstrap and bootstraps also have a container form (container/1, result/2): the same gh2k command in the
%% genhub2-task image, inputs and outputs by hash, for the federation executor (gh_fedexec). Its result is the same
%% file, so the same hash, as run/2's.
-module(gh_phylo).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1, container/1, result/2]).
-export([chunks/2, join/1, tiles/2, shape/1]).

run({align, Chunk, Refs, Acc, First}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              {[RefRow | Rows], N, Columns} = gh_tree:aligned_rows(gh_store:ensure(Chunk, Home), Refs, Acc, Home, Dir),
              Out = case First of true -> [RefRow | Rows]; false -> Rows end,
              #{rows => gh_store:put_binary(Out), sequences => N, columns => Columns}
      end);
run({distance_block, Aligned, I0, I1, J0, J1}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              Tile = filename:join(Dir, "tile"),
              <<>> = gh_tool:gh2k_must(["dist", gh_store:ensure(Aligned, Home) | [integer_to_list(X) || X <- [I0, I1, J0, J1]]]
                                       ++ [Tile], 1),
              gh_store:move_file(Tile)
      end);
run({njtiles, Aligned, Tiles}, #{home := Home}) ->
    A = gh_store:ensure(Aligned, Home),
    Newick = gh_tool:gh2k_must(["njtiles", A | [gh_store:ensure(T, Home) || T <- Tiles]]),
    {N, Columns} = shape(A),
    #{newick => gh_store:put_binary(Newick), aligned => Aligned, sequences => N, columns => Columns, method => nj};
run({bootstrap, Aligned, Seed}, #{home := Home}) ->
    gh_store:put_binary(gh_tool:gh2k_must(["boot", gh_store:ensure(Aligned, Home), integer_to_list(Seed)], 1));
run({bootstraps, Aligned, First, Count}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              Out = filename:join(Dir, "trees.nwk"),
              <<>> = gh_tool:gh2k_must(["boots", gh_store:ensure(Aligned, Home), integer_to_list(First),
                                        integer_to_list(Count), Out], 1),
              gh_store:move_file(Out)
      end);
run({support, Newick, Reps}, #{home := Home}) ->
    gh_store:with_tmp(
      fun(Dir) ->
              All = filename:join(Dir, "replicates.nwk"),
              Trees = [gh_store:read_from(R, Home) || R <- Reps],
              ok = file:write_file(All, Trees),
              Out = gh_tool:gh2k_must(["support", gh_store:ensure(Newick, Home), All]),
              %% the replicate trees, one a line, whether each file holds one (bootstrap) or a batch (bootstraps)
              N = length(binary:split(iolist_to_binary(Trees), <<"\n">>, [global, trim_all])),
              #{newick => gh_store:put_binary(Out), replicates => N}
      end).

%% the task as a container command (gh_fed:run/2): only for the tasks that need nothing but gh2k
-spec container(term()) -> map() | none.
container({distance_block, Aligned, I0, I1, J0, J1}) ->
    #{name => <<"distance block">>,
      description => <<"Jukes-Cantor distances between aligned viral genomes (a block of the matrix for a phylogenetic tree)">>,
      inputs => [{<<"/work/in/aligned.fa">>, Aligned}], outputs => [<<"/work/out/tile">>],
      command => [<<"gh2k">>, <<"dist">>, <<"/work/in/aligned.fa">> | [integer_to_binary(X) || X <- [I0, I1, J0, J1]]]
          ++ [<<"/work/out/tile">>],
      resources => #{cpu => 1, ram_gb => 2, disk_gb => 1}};
container({bootstrap, Aligned, Seed}) ->
    #{name => <<"bootstrap replicate">>,
      description => <<"one bootstrap replicate of a neighbour-joining tree of aligned viral genomes">>,
      inputs => [{<<"/work/in/aligned.fa">>, Aligned}], outputs => [<<"/work/out/tree.nwk">>],
      command => [<<"gh2k">>, <<"boot">>, <<"/work/in/aligned.fa">>, integer_to_binary(Seed), <<"/work/out/tree.nwk">>],
      resources => #{cpu => 1, ram_gb => 2, disk_gb => 1}};
container({bootstraps, Aligned, First, Count}) ->
    #{name => <<"bootstrap replicates">>,
      description => <<"a batch of bootstrap replicates of a neighbour-joining tree of aligned viral genomes">>,
      inputs => [{<<"/work/in/aligned.fa">>, Aligned}], outputs => [<<"/work/out/trees.nwk">>],
      command => [<<"gh2k">>, <<"boots">>, <<"/work/in/aligned.fa">>, integer_to_binary(First), integer_to_binary(Count),
                  <<"/work/out/trees.nwk">>],
      resources => #{cpu => 2, ram_gb => 2, disk_gb => 1}};
container(_) -> none.

%% the task's result from its container outputs (Path => Hash): run/2's result
-spec result(term(), #{binary() => gh_store:hash()}) -> term().
result({distance_block, _, _, _, _, _}, #{<<"/work/out/tile">> := H}) -> H;
result({bootstrap, _, _}, #{<<"/work/out/tree.nwk">> := H}) -> H;
result({bootstraps, _, _, _}, #{<<"/work/out/trees.nwk">> := H}) -> H.

resources({align, _, _, _, _}) -> #{cpu => gh_tool:threads()};
resources(_) -> #{cpu => 1}.

describe({align, _, Refs, Acc, _}) -> #{task => align, tools => [minimap2], refs => Refs, reference => Acc};
describe({distance_block, _, I0, I1, J0, J1}) -> #{task => distance_block, tools => [gh2k], rows => [I0, I1], columns => [J0, J1]};
describe({njtiles, _, Tiles}) -> #{task => tree, tools => [gh2k], method => nj, tiles => length(Tiles)};
describe({bootstrap, _, Seed}) -> #{task => bootstrap, tools => [gh2k], seed => Seed};
describe({bootstraps, _, First, Count}) -> #{task => bootstrap, tools => [gh2k], seeds => [First, First + Count - 1]};
describe({support, _, Reps}) -> #{task => support, tools => [gh2k], replicates => length(Reps)}.

%%% for building a tree job's tasks (gh_pipeline), on the coordinating node

%% the FASTA file Genomes as files of at most Size records each, in order
-spec chunks(gh_store:hash(), pos_integer()) -> [gh_store:hash()].
chunks(Genomes, Size) ->
    Recs = gh_fasta:records(gh_store:path(Genomes)),
    [gh_store:put_binary([[<<">">>, Id, string:trim(R, trailing, "\n"), <<"\n">>] || {Id, R} <- C])
     || C <- split(Recs, Size)].

split([], _) -> [];
split(L, Size) when length(L) =< Size -> [L];
split(L, Size) -> {A, B} = lists:split(Size, L), [A | split(B, Size)].

%% the alignment: the align tasks' rows, in order (the first chunk's begin with the reference)
-spec join([map()]) -> gh_store:hash().
join(Aligned) -> gh_store:put_binary([gh_store:read(R) || #{rows := R} <- Aligned]).

%% tiles of Size rows covering every pair of an N x N matrix once (the diagonal blocks and those above them)
-spec tiles(non_neg_integer(), pos_integer()) -> [{non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}].
tiles(N, Size) ->
    Bs = [{S, min(S + Size, N)} || S <- lists:seq(0, N - 1, Size)],
    [{I0, I1, J0, J1} || {I0, I1} <- Bs, {J0, J1} <- Bs, J0 >= I0].

%% {sequences, columns} of an alignment file
-spec shape(file:filename()) -> {non_neg_integer(), non_neg_integer()}.
shape(Aligned) ->
    {ok, B} = file:read_file(Aligned),
    Lines = binary:split(B, <<"\n">>, [global, trim]),
    Seqs = [L || L <- Lines, binary:first(L) =/= $>],
    {length(Seqs), case Seqs of [S | _] -> byte_size(S); [] -> 0 end}.
