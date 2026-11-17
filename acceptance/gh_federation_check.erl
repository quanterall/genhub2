%% GenHub2 on the FVLLMP federation (FS 4.5, plan section 5 phase C): tasks sent to the FVLLMP node GenHub2 runs on,
%% which runs them on itself or on a peer, with results identical to this node's.
%%
%%   1. The client (gh_fed), with the image the node allows every application for tests (alpine): a file of
%%      GenHub2's store uploaded by its hash, a task that reads it, its output downloaded and checked; where it ran;
%%      GenHub2's usage.
%%   2. GenHub2's own tasks through the federation executor (gh_fedexec), with the genhub2-task image once the nodes'
%%      owners allow it: distance tiles and a batch of bootstrap replicates of the 1,000 SARS-CoV-2 genomes and the
%%      reference.
%%      Each result must be the local executor's, byte for byte, and the tree from the federation's tiles phase A's.
%%   3. Classification (MinHash, gh2k) of the 1,593 genomes of phase A (the 1,000 SARS-CoV-2 and the 593 held-out)
%%      and mutations (minimap2) of the 1,000 SARS-CoV-2 genomes, through the federation executor: the same results as
%%      this node's, call for call and mutation for mutation.
%%   4. A genome job through the job service with executor federation: its upload validated on this node (the lab's
%%      data), its classification and mutations through the federation, the same results as a job on this node.
%%      Without the image setting, parts 2-4 are skipped and said so.
%%
%% Results: acceptance/results/federation-<host>-<date>.json; exit status 0 when every check holds.
%%   sh acceptance/run_federation.sh [genhub2-task@sha256:...]
-module(gh_federation_check).
-export([main/1]).

-define(ALPINE, "alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc").
-define(REF, <<"NC_045512.2">>).
-define(PHASE_A_NJ, <<"b06e5e9fd95a7a5161ac4cf488f937df7f1e223c5591ad5bc63c39a8623b93cb">>).
-define(REPLICATES, 10).

-spec main([string()]) -> no_return().
main([Image, Out]) ->
    {ok, _} = application:ensure_all_started(genhub2),
    T0 = erlang:monotonic_time(millisecond),
    Fed = gh_fed:config(),
    Info = maps:get(<<"fvllmp">>, gh_fed:service_info()),
    log(io_lib:format("node ~s: accepting ~p, may use peers ~p, free slots ~p, room ~p GB",
                      [maps:get(<<"node">>, Info), maps:get(<<"accepting">>, Info), maps:get(<<"federate">>, Info),
                       maps:get(<<"free_slots">>, Info), maps:get(<<"room_gb">>, Info)])),
    log("1. the client, with the test image"),
    Client = client(Fed),
    {Own, Analyses, Job} =
        case Image of
            "none" -> log("2-4. skipped: no genhub2-task image allowed yet"), {skipped, skipped, skipped};
            _ ->
                F = Fed#{image => Image},
                log("2. GenHub2's trees through the federation executor"),
                O = own(F),
                log("3. classification and mutations through the federation executor"),
                A = analyses(F),
                log("4. a genome job with executor federation"),
                {O, A, job(F)}
        end,
    Usage = gh_fed:usage(),
    Checks = checks(Client, Own) ++ analyses_checks(Analyses) ++ job_checks(Job),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), node => maps:get(<<"node">>, Info), service_info => Info,
          image => list_to_binary(Image), client => Client, genhub2_tasks => Own, analyses => Analyses, genome_job => Job,
          usage => Usage, checks => Checks,
          skipped => case Own of skipped -> [<<"parts 2-4: the genhub2-task image is not allowed on the nodes yet">>]; _ -> [] end,
          seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(R)),
    Failed = [C || #{ok := false} = C <- Checks],
    [io:format("~s ~s: ~s~n", [case Ok of true -> "ok  "; false -> "FAIL" end, N, V])
     || #{name := N, ok := Ok, value := V} <- Checks],
    [io:format("skip parts 2-4: the genhub2-task image is not allowed on the nodes yet~n") || Own =:= skipped],
    io:format("~b of ~b checks hold~nwritten ~s~n", [length(Checks) - length(Failed), length(Checks), Out]),
    halt(case Failed of [] -> 0; _ -> 1 end).

log(S) -> io:format("~s ~s~n", [calendar:system_time_to_rfc3339(erlang:system_time(second)), S]).

%% 1. a stored file, a task that counts its bytes and lines, the result checked
client(Fed) ->
    application:set_env(genhub2, federation, Fed#{image => ?ALPINE}),
    Data = iolist_to_binary([">s", integer_to_list(erlang:system_time(millisecond)), "\nACGTTTGACCAGT\n"]),
    H = gh_store:put_binary(Data),
    Expected = iolist_to_binary(io_lib:format("~b ~b~n", [byte_size(Data), 2])),
    #{outputs := #{<<"/work/out/count">> := OutH}, id := Id, ran_on := RanOn, seconds := Secs} =
        gh_fed:run(#{name => <<"genhub2 federation check">>,
                     description => <<"count the bytes and lines of a small test file (GenHub2's federation check)">>,
                     inputs => [{<<"/work/in/data.fa">>, H}], outputs => [<<"/work/out/count">>],
                     command => [<<"sh">>, <<"-c">>,
                                 <<"echo $(wc -c < /work/in/data.fa) $(wc -l < /work/in/data.fa) > /work/out/count">>],
                     resources => #{cpu => 1, ram_gb => 1, disk_gb => 1}}, 1200000),
    Got = gh_store:read(OutH),
    log(io_lib:format("   task ~s ran on ~s in ~.1f s: ~s", [Id, RanOn, Secs, string:trim(Got)])),
    application:set_env(genhub2, federation, Fed),
    #{input => H, output => OutH, expected => Expected, got => Got, ran_on => RanOn, seconds => Secs,
      uploaded_held => gh_fed:has(H)}.

%% 2. tiles and replicates, local and through the federation
own(Fed) ->
    application:set_env(genhub2, federation, Fed),
    Refs = gh_refdb:refseq_viral(),
    #{fasta := Sars} = gh_acceptance:sars_cov_2(),
    A = pq_rexec:map([{pq_task, gh_phylo, {align, C, Refs, ?REF, K =:= 1}}
                      || {K, C} <- lists:enumerate(gh_phylo:chunks(Sars, 100))], local, #{}),
    Aligned = gh_phylo:join(A),
    N = 1 + lists:sum([S || #{sequences := S} <- A]),
    Tasks = [{pq_task, gh_phylo, {distance_block, Aligned, I0, I1, J0, J1}} || {I0, I1, J0, J1} <- gh_phylo:tiles(N, 256)]
        ++ [{pq_task, gh_phylo, {bootstraps, Aligned, 1, ?REPLICATES}}],
    {Local, SL} = secs(fun() -> pq_rexec:map(Tasks, local, #{}) end),
    log(io_lib:format("   ~b tasks here: ~.1f s", [length(Tasks), SL])),
    {Traced, SF} = secs(fun() -> gh_fedexec:map_traced(Tasks, #{}) end),
    Remote = [R || {R, _} <- Traced],
    Where = lists:foldl(fun({_, #{node := W}}, M) -> maps:update_with(W, fun(K) -> K + 1 end, 1, M) end, #{}, Traced),
    log(io_lib:format("   ~b tasks through the federation: ~.1f s, ran on ~p", [length(Tasks), SF, Where])),
    NTiles = length(gh_phylo:tiles(N, 256)),
    #{newick := Nwk} = pq_task:run({pq_task, gh_phylo, {njtiles, Aligned, lists:sublist(Remote, NTiles)}}, node()),
    #{tasks => length(Tasks), identical => Local =:= Remote, local_seconds => SL, federation_seconds => SF,
      ran_on => Where, newick => Nwk, aligned => Aligned}.

%% 3. classification and mutations, here and through the federation
analyses(Fed) ->
    application:set_env(genhub2, federation, Fed),
    Refs = gh_refdb:refseq_viral(),
    #{fasta := Sars} = gh_acceptance:sars_cov_2(),
    #{fasta := Held} = gh_acceptance:held_out(Refs),
    Tasks = [{pq_task, gh_classify, {classify, C, Refs, 10}} || G <- [Sars, Held], C <- gh_phylo:chunks(G, 200)]
        ++ [{pq_task, gh_mutations, {mutations, C, Refs, ?REF}} || C <- gh_phylo:chunks(Sars, 200)],
    {Local, SL} = secs(fun() -> pq_rexec:map(Tasks, local, #{}) end),
    log(io_lib:format("   ~b tasks here: ~.1f s", [length(Tasks), SL])),
    {Traced, SF} = secs(fun() -> gh_fedexec:map_traced(Tasks, #{}) end),
    Remote = [R || {R, _} <- Traced],
    Where = lists:foldl(fun({_, #{node := W}}, M) -> maps:update_with(W, fun(K) -> K + 1 end, 1, M) end, #{}, Traced),
    log(io_lib:format("   ~b tasks through the federation: ~.1f s, ran on ~p", [length(Tasks), SF, Where])),
    Calls = lists:append([R || {{pq_task, gh_classify, _}, R} <- lists:zip(Tasks, Remote)]),
    Muts = lists:append([R || {{pq_task, gh_mutations, _}, R} <- lists:zip(Tasks, Remote)]),
    #{tasks => length(Tasks), identical => Local =:= Remote, local_seconds => SL, federation_seconds => SF,
      ran_on => Where, genomes_classified => length(Calls), genomes_with_mutations => length(Muts),
      sars_cov_2_called => length([C || #{<<"call">> := #{<<"species">> := <<"Betacoronavirus pandemicum">>}} = C <- Calls])}.

%% 4. one genome job on this node, the same through the federation
job(Fed) ->
    Params = #{refs => gh_refdb:refseq_viral(), proteins => gh_refdb:viral_proteins(),
               nextclade => gh_refdb:nextclade("2026-10-28--15-04-26Z"), min_depth => 10},
    #{fasta := Sars} = gh_acceptance:sars_cov_2(),
    [Chunk | _] = gh_phylo:chunks(Sars, 20),
    Run = fun(Exec) ->
                  application:set_env(genhub2, executor, Exec),
                  {J, S} = secs(fun() -> Id = gh_jobs:submit(genome, [Chunk], Params), gh_jobs:wait(Id, 1800000) end),
                  application:set_env(genhub2, executor, local),
                  V = gh_jobs:view(maps:get(id, J)),
                  Steps = maps:get(steps, V),
                  #{state => maps:get(state, V), seconds => S,
                    results => maps:map(fun(_, #{results := R}) -> R end, Steps),
                    step_nodes => maps:map(fun(_, #{provenance := P}) -> lists:usort([N || #{node := N} <- P]) end, Steps)}
          end,
    application:set_env(genhub2, federation, Fed),
    Here = Run(local),
    There = Run(federation),
    log(io_lib:format("   genome job here ~.1f s, with the federation ~.1f s", [maps:get(seconds, Here), maps:get(seconds, There)])),
    #{here_state => maps:get(state, Here), state => maps:get(state, There), seconds_here => maps:get(seconds, Here),
      seconds => maps:get(seconds, There), step_nodes => maps:get(step_nodes, There),
      identical => maps:get(results, Here) =:= maps:get(results, There)}.

analyses_checks(skipped) -> [];
analyses_checks(A) ->
    [check(<<"classification and mutations: identical to this node's">>, maps:get(identical, A), maps:get(tasks, A)),
     check(<<"classification and mutations: ran through the federation">>,
           lists:all(fun(W) -> binary:match(W, <<"federation:">>) =/= nomatch end, maps:keys(maps:get(ran_on, A))),
           maps:get(ran_on, A)),
     check(<<"classification: all 1,593 genomes, the 1,000 SARS-CoV-2 called SARS-CoV-2">>,
           maps:get(genomes_classified, A) =:= 1593 andalso maps:get(sars_cov_2_called, A) >= 1000,
           {maps:get(genomes_classified, A), maps:get(sars_cov_2_called, A)})].

job_checks(skipped) -> [];
job_checks(J) ->
    #{step_nodes := SN} = J,
    Fed = fun(St) -> [N || N <- maps:get(St, SN), is_binary(N), binary:match(N, <<"federation:">>) =/= nomatch] =/= [] end,
    [check(<<"genome job: done here and with the federation">>, {maps:get(here_state, J), maps:get(state, J)} =:= {done, done},
           {maps:get(here_state, J), maps:get(state, J)}),
     check(<<"genome job: the same results with the federation">>, maps:get(identical, J), maps:get(identical, J)),
     check(<<"genome job: the upload validated on this node only">>, maps:get(validate, SN) =:= [node()], maps:get(validate, SN)),
     check(<<"genome job: classification and mutations through the federation">>, Fed(classify) andalso Fed(mutations),
           maps:with([classify, mutations], SN))].

secs(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = F(),
    {R, (erlang:monotonic_time(microsecond) - T0) / 1.0e6}.

checks(C, Own) ->
    [check(<<"client: the task's output is the expected one">>, maps:get(got, C) =:= maps:get(expected, C), maps:get(got, C)),
     check(<<"client: the output's hash was checked on download">>,
           maps:get(output, C) =:= gh_store_hash(maps:get(got, C)), maps:get(output, C)),
     check(<<"client: the node holds the uploaded input by its hash">>, maps:get(uploaded_held, C), maps:get(input, C)),
     check(<<"client: the node says where the task ran">>, is_binary(maps:get(ran_on, C)), maps:get(ran_on, C))]
    ++ case Own of
           skipped -> [];
           _ -> [check(<<"genhub2 tasks: identical to this node's">>, maps:get(identical, Own), maps:get(tasks, Own)),
                 check(<<"genhub2 tasks: the tree from the federation's tiles is phase A's">>,
                       maps:get(newick, Own) =:= ?PHASE_A_NJ, maps:get(newick, Own)),
                 check(<<"genhub2 tasks: ran through the federation">>,
                       lists:all(fun(W) -> binary:match(W, <<"federation:">>) =/= nomatch end, maps:keys(maps:get(ran_on, Own))),
                       maps:get(ran_on, Own))]
       end.

gh_store_hash(B) -> binary:encode_hex(crypto:hash(sha256, B), lowercase).

check(Name, Ok, Value) -> #{name => Name, ok => Ok, value => iolist_to_binary(io_lib:format("~0p", [Value]))}.
