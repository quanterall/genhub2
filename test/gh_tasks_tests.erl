%% The tasks that need no reference data, run as PQCF runs them (pq_task:run/2), on a store in a temporary directory.
-module(gh_tasks_tests).
-include_lib("eunit/include/eunit.hrl").

tasks_test_() ->
    {setup,
     fun() ->
             Dir = filename:join("/tmp", "gh-tasks-" ++ os:getpid()),
             ok = application:load(genhub2),
             ok = application:set_env(genhub2, data_dir, Dir),
             [pq_task:allow(M) || M <- [gh_validate, gh_knowledge, gh_classify]],
             Dir
     end,
     fun(Dir) -> file:del_dir_r(Dir) end,
     [fun validate_normalises/0, fun validate_rejects/0, fun gzipped/0, fun knowledge_links/0, fun calls/0,
      fun not_allowed/0]}.

run(Task) -> pq_task:run(Task, node()).

validate_normalises() ->
    H = gh_store:put_binary(<<">s1 sample\nacgu\nNNU\n">>),
    #{ok := true, output := O, report := R} = run({pq_task, gh_validate, {validate, H}}),
    ?assertEqual(<<">s1 sample\nACGTNNT\n">>, gh_store:read(O)),
    ?assertMatch(#{<<"type">> := <<"rna">>, <<"records">> := 1, <<"bases">> := 7}, R).

validate_rejects() ->
    H = gh_store:put_binary(<<">s1\nACGTXX\n">>),
    #{ok := false, report := #{<<"problems">> := [P | _]}} = run({pq_task, gh_validate, {validate, H}}),
    ?assertMatch({_, _}, binary:match(P, <<"'X'">>)).

gzipped() ->
    H = gh_store:put_binary(zlib:gzip(<<"@r1\nACGT\n+\nIIII\n">>)),
    #{ok := true, output := O} = run({pq_task, gh_validate, {validate, H}}),
    ?assertEqual(<<"@r1\nACGT\n+\nIIII\n">>, gh_store:read(O)).

knowledge_links() ->
    #{information_only := true, links := Links} =
        run({pq_task, gh_knowledge, {knowledge, 2697049, <<"Severe acute respiratory syndrome coronavirus 2">>}}),
    Urls = [U || #{url := U} <- Links],
    ?assert(lists:member(<<"https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=2697049">>, Urls)),
    ?assert(lists:member(<<"https://clinicaltrials.gov/search?cond=Severe%20acute%20respiratory%20syndrome%20coronavirus%202">>,
                         Urls)).

calls() ->
    Hit = fun(Ani) -> #{<<"ref">> => <<"NC_1">>, <<"ani">> => Ani, <<"species">> => <<"S">>, <<"genus">> => <<"G">>,
                        <<"family">> => <<"F">>, <<"organism">> => <<"O">>, <<"taxid">> => 1}
          end,
    Conf = fun(Hits) -> maps:get(<<"confidence">>, maps:get(<<"call">>, gh_classify:call(#{<<"hits">> => Hits}))) end,
    ?assertEqual(<<"high">>, Conf([Hit(0.99)])),
    ?assertEqual(<<"medium">>, Conf([Hit(0.9)])),
    ?assertEqual(<<"low">>, Conf([Hit(0.8)])),
    ?assertEqual(<<"unclassified">>, Conf([])).

not_allowed() ->
    ?assertError({task_not_allowed, gh_tree}, run({pq_task, gh_tree, {tree, x, y, z, nj}})).
