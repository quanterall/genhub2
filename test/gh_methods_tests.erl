-module(gh_methods_tests).
-include_lib("eunit/include/eunit.hrl").

rf_identical_and_different_test() ->
    A = <<"((a:1,b:1):1,(c:1,d:1):1,e:1);">>,
    B = <<"((a:1,c:1):1,(b:1,d:1):1,e:1);">>,
    ?assertMatch(#{rf := 0}, gh_treecmp:rf(A, A, 1.0e-5)),
    %% the same tree written from another side
    ?assertMatch(#{rf := 0}, gh_treecmp:rf(A, <<"(e:1,(d:1,c:1):1,(b:1,a:1):1);">>, 1.0e-5)),
    ?assertMatch(#{rf := 4, splits_a := 2, splits_b := 2}, gh_treecmp:rf(A, B, 1.0e-5)).

rf_collapses_short_branches_test() ->
    %% two resolutions of three identical sequences differ only in branches of length 0
    A = <<"(((a:0,b:0):0,c:0):1,d:1,e:1);">>,
    B = <<"(((a:0,c:0):0,b:0):1,d:1,e:1);">>,
    ?assertMatch(#{rf := 2}, gh_treecmp:rf(A, B, -1.0)),
    ?assertMatch(#{rf := 0}, gh_treecmp:rf(A, B, 1.0e-5)).

vcf_test() ->
    V = iolist_to_binary(gh_usher:vcf({<<"ref">>, <<"ACGT">>}, [{<<"s1">>, <<"ACTT">>}, {<<"s2">>, <<"NCGA">>},
                                                              {<<"s3">>, <<"ACCT">>}])),
    [_, Header, P3, P4] = binary:split(V, <<"\n">>, [global, trim_all]),
    ?assertEqual(<<"#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2\ts3">>, Header),
    ?assertEqual(<<"ref\t3\t.\tG\tC,T\t.\t.\t.\tGT\t2\t0\t1">>, P3),
    ?assertEqual(<<"ref\t4\t.\tT\tA\t.\t.\t.\tGT\t0\t1\t0">>, P4).
