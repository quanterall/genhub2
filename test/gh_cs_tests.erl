-module(gh_cs_tests).
-include_lib("eunit/include/eunit.hrl").

%% reference positions 11..22 aligned: ACGT, A>G at 15, TT, CC inserted after 17, A, GT deleted at 19-20, CC
-define(CS, <<"=ACGT*ag=TT+cc=A-gt=CC">>).

ops_test() ->
    ?assertEqual([{match, <<"ACGT">>}, {sub, $A, $G}, {match, <<"TT">>}, {ins, <<"CC">>}, {match, <<"A">>},
                  {del, <<"GT">>}, {match, <<"CC">>}], gh_cs:ops(?CS)).

mutations_test() ->
    ?assertEqual(#{substitutions => [[15, <<"A">>, <<"G">>]], insertions => [[17, <<"CC">>]],
                   deletions => [[19, 2]], missing => 0},
                 gh_cs:mutations([{10, 22, gh_cs:ops(?CS)}], 25)).

missing_bases_are_not_mutations_test() ->
    ?assertMatch(#{substitutions := [], missing := 2}, gh_cs:mutations([{0, 5, gh_cs:ops(<<"=AC*an*cn=G">>)}], 5)).

aligned_test() ->
    ?assertEqual(<<"NNNNNNNNNNACGTGTTA--CCNNN">>, gh_cs:aligned([{10, 22, gh_cs:ops(?CS)}], 25)).

split_alignment_test() ->
    %% two segments with a gap between them, as minimap2 reports a genome with a run of N
    Segs = [{0, 4, [{match, <<"AC">>}, {sub, $G, $T}, {match, <<"T">>}]}, {6, 8, [{sub, $A, $C}, {match, <<"A">>}]}],
    ?assertEqual(<<"ACTTNNCA">>, gh_cs:aligned(Segs, 8)),
    ?assertMatch(#{substitutions := [[3, <<"G">>, <<"T">>], [7, <<"A">>, <<"C">>]]}, gh_cs:mutations(Segs, 8)).

best_alignments_per_query_test() ->
    Paf = <<"q1\t100\t0\t50\t+\tr\t200\t10\t60\t50\t50\t60\ttp:A:P\tAS:i:40\tcs:Z:=AC\n"
            "q1\t100\t0\t90\t+\tr\t200\t100\t190\t90\t90\t60\ttp:A:P\tAS:i:80\tcs:Z:=GT\n"
            "q1\t100\t0\t90\t+\tr\t200\t150\t195\t90\t90\t60\ttp:A:P\tAS:i:30\tcs:Z:=GG\n"
            "q1\t100\t0\t99\t+\tr\t200\t0\t99\t99\t99\t0\ttp:A:S\tAS:i:99\tcs:Z:=TT\n"
            "q2\t100\t0\t5\t-\tr\t200\t0\t5\t5\t5\t60\ttp:A:P\tAS:i:5\tcs:Z:=A*ct\n">>,
    %% q1: the two non-overlapping primaries in reference order; the third overlaps a better one; the secondary is out
    ?assertEqual(#{<<"q1">> => {200, [{10, 60, [{match, <<"AC">>}]}, {100, 190, [{match, <<"GT">>}]}]},
                   <<"q2">> => {200, [{0, 5, [{match, <<"A">>}, {sub, $C, $T}]}]}}, gh_cs:best(Paf)).
