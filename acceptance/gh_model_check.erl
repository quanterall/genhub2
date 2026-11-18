%% Phase E's model test (plan sections 3.1 and 5, FS 5.3): a learned model is adopted only if it beats the established
%% methods on held-out data, in a published test. The model: multinomial naive Bayes on canonical 6-mers (gh2k nb, the
%% approach of the RDP classifier, Wang et al. 2007, doi:10.1128/AEM.00062-07), trained on all complete RefSeq viral
%% genomes. K = 6 was fixed before the test; nothing is tuned on the held-out genomes.
%%
%% Held out: phase A's 593 GenBank genomes of 30 viruses (none a RefSeq genome). Every method's call for every genome:
%%   minhash           GenHub2's MinHash call (gh_classify)
%%   protein           DIAMOND blastx against the RefSeq viral proteins (gh_protein)
%%   classical         GenHub2 today: the protein call where MinHash's is low or unclassified, MinHash's elsewhere
%%   model             naive Bayes alone
%%   minhash+model     the model's call where MinHash's is low or unclassified, MinHash's elsewhere
%% scored at species, genus and family against NCBI's taxonomy, as phase A scored them; overall and by MinHash's
%% confidence.
%%
%% The rule, set before the test: adopt the model if minhash+model gets more species right than classical, and no
%% fewer at genus and family; otherwise not.
%%
%% Results: acceptance/results/model-<host>-<date>.json; exit status 0 when the test is complete (every method's call
%% for every genome), whatever the verdict.
%%   sh acceptance/run_model.sh      (after acceptance/run.sh, which builds the reference bundles)
-module(gh_model_check).
-export([main/1]).

-define(K, 6).

-spec main([string()]) -> no_return().
main([Out]) ->
    {ok, _} = application:ensure_all_started(genhub2),
    T0 = erlang:monotonic_time(millisecond),
    Refs = gh_refdb:refseq_viral(),
    Proteins = gh_refdb:viral_proteins(),
    #{fasta := Fasta, truth := Truth} = gh_acceptance:held_out(Refs),
    Chunks = gh_phylo:chunks(Fasta, 100),
    log("MinHash"),
    {MhRows, MhSecs} = secs(fun() -> lists:append(pq_rexec:map([{pq_task, gh_classify, {classify, C, Refs, 10}} || C <- Chunks], local, #{})) end),
    log("proteins"),
    {PrRows, PrSecs} = secs(fun() -> lists:append(pq_rexec:map([{pq_task, gh_protein, {protein, C, Proteins}} || C <- Chunks],
                                                               local, #{workers => 3})) end),
    log(io_lib:format("naive Bayes, K = ~b", [?K])),
    {NbRows, NbSecs} = secs(fun() -> naive_bayes(Refs, Fasta) end),
    Tax = by_species(Refs),
    Mh = maps:from_list([{maps:get(<<"query">>, R), minhash_call(R)} || R <- MhRows]),
    Pr = maps:from_list([{Q, protein_call(C)} || #{query := Q, call := C} <- PrRows]),
    Nb = maps:from_list([{Q, rank_call(S, Tax)} || #{<<"query">> := Q, <<"species">> := S} <- NbRows]),
    Weak = fun(Q) -> lists:member(maps:get(confidence, maps:get(Q, Mh)), [low, unclassified]) end,
    Usable = fun(C) -> maps:get(species, C) =/= <<>> end,
    %% the genomes classified (the held-out file): the truth table also lists the 3 left out as identical to RefSeq
    Queries = lists:sort([Q || {Q, _} <- gh_fasta:records(gh_store:path(Fasta))]),
    Calls = #{minhash => Mh, protein => Pr, model => Nb,
              classical => maps:from_list([{Q, case Weak(Q) andalso Usable(maps:get(Q, Pr)) of
                                                   true -> maps:get(Q, Pr);
                                                   false -> maps:get(Q, Mh)
                                               end} || Q <- Queries]),
              'minhash+model' => maps:from_list([{Q, case Weak(Q) andalso Usable(maps:get(Q, Nb)) of
                                                         true -> maps:get(Q, Nb);
                                                         false -> maps:get(Q, Mh)
                                                     end} || Q <- Queries])},
    Groups = [{all, Queries}] ++ [{C, [Q || Q <- Queries, maps:get(confidence, maps:get(Q, Mh)) =:= C]}
                                  || C <- [high, medium, low, unclassified]],
    Scores = maps:map(fun(_, Cs) -> maps:from_list([{G, score(Qs, Cs, Truth)} || {G, Qs} <- Groups]) end, Calls),
    Right = fun(M, Rank) -> maps:get(right, maps:get(Rank, maps:get(all, maps:get(M, Scores)))) end,
    Adopt = Right('minhash+model', species) > Right(classical, species)
        andalso Right('minhash+model', genus) >= Right(classical, genus)
        andalso Right('minhash+model', family) >= Right(classical, family),
    %% the genomes the two differ on, for the results page
    Differ = [#{query => Q, truth => maps:get(species, maps:get(Q, Truth)), classical => maps:get(species, maps:get(Q, maps:get(classical, Calls))),
                model => maps:get(species, maps:get(Q, Nb)), minhash_confidence => maps:get(confidence, maps:get(Q, Mh))}
              || Q <- Queries, Weak(Q), maps:get(species, maps:get(Q, maps:get(classical, Calls))) =/= maps:get(species, maps:get(Q, Nb))],
    Complete = lists:all(fun(Cs) -> lists:all(fun(Q) -> is_map_key(Q, Cs) end, Queries) end, maps:values(Calls)),
    R = #{date => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
          host => list_to_binary(net_adm:localhost()), k => ?K, genomes => length(Queries),
          references => length(maps:keys(gh_refs:taxonomy(Refs, node()))), species_trained => maps:size(Tax),
          seconds => #{minhash => MhSecs, protein => PrSecs, model => NbSecs},
          scores => Scores, verdict => case Adopt of true -> adopt; false -> do_not_adopt end,
          weak_calls_where_they_differ => Differ, complete => Complete,
          total_seconds => (erlang:monotonic_time(millisecond) - T0) / 1000},
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, json:format(gh_json:term(R))),
    [io:format("~-14s species ~3b/~b  genus ~3b/~b  family ~3b/~b~n",
               [M, Right(M, species), total(M, species, Scores), Right(M, genus), total(M, genus, Scores),
                Right(M, family), total(M, family, Scores)])
     || M <- [minhash, protein, classical, model, 'minhash+model']],
    io:format("verdict: ~s (the rule: minhash+model must get more species right than classical, no fewer genera or "
              "families)~ncomplete: ~p~nwritten ~s~n", [maps:get(verdict, R), Complete, Out]),
    halt(case Complete of true -> 0; false -> 1 end).

log(S) -> io:format("~s ~s~n", [calendar:system_time_to_rfc3339(erlang:system_time(second)), S]).

secs(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = F(),
    {R, (erlang:monotonic_time(microsecond) - T0) / 1.0e6}.

total(M, Rank, Scores) -> maps:get(total, maps:get(Rank, maps:get(all, maps:get(M, Scores)))).

naive_bayes(Refs, Fasta) ->
    Out = gh_tool:gh2k_must(["nb", gh_refs:file(Refs, "refs.fasta", node()), gh_refs:file(Refs, "taxonomy.tsv", node()),
                             gh_store:path(Fasta), integer_to_list(?K)], erlang:system_info(schedulers_online)),
    [json:decode(L) || L <- binary:split(Out, <<"\n">>, [global, trim_all])].

%% species => #{genus, family}, from the bundle's taxonomy
by_species(Refs) ->
    maps:from_list([{maps:get(species, T), #{genus => maps:get(genus, T), family => maps:get(family, T)}}
                    || T <- maps:values(gh_refs:taxonomy(Refs, node())), maps:get(species, T) =/= <<>>]).

rank_call(S, Tax) ->
    T = maps:get(S, Tax, #{genus => <<>>, family => <<>>}),
    #{species => S, genus => maps:get(genus, T), family => maps:get(family, T), confidence => model}.

minhash_call(#{<<"call">> := C}) ->
    #{species => maps:get(<<"species">>, C, <<>>), genus => maps:get(<<"genus">>, C, <<>>),
      family => maps:get(<<"family">>, C, <<>>), confidence => binary_to_atom(maps:get(<<"confidence">>, C))}.

protein_call(#{confidence := unclassified}) -> #{species => <<>>, genus => <<>>, family => <<>>, confidence => unclassified};
protein_call(C) -> maps:with([species, genus, family, confidence], C).

%% per rank: right of those whose truth has the rank (as phase A counted)
score(Qs, Calls, Truth) ->
    maps:from_list([{Rank, begin
                               Scored = [Q || Q <- Qs, maps:get(Rank, maps:get(Q, Truth)) =/= <<>>],
                               #{total => length(Scored),
                                 right => length([Q || Q <- Scored,
                                                       maps:get(Rank, maps:get(Q, Calls)) =:= maps:get(Rank, maps:get(Q, Truth))])}
                           end} || Rank <- [species, genus, family]]).
