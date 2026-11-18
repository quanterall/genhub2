-module(gh_export_tests).
-include_lib("eunit/include/eunit.hrl").

newick_test() ->
    ?assertEqual({node, [{node, [{node, [], <<"a">>, 1.0}, {node, [], <<"b">>, 2.0}], <<>>, 1.0},
                         {node, [], <<"c">>, 3.0}, {node, [], <<"d/x.1">>, 4.0}], <<>>, 0.0},
                 gh_export:newick(<<"((a:1.000000,b:2):1,c:3e0,d/x.1:4.0);\n">>)).

svg_test() ->
    S = iolist_to_binary(gh_export:svg(<<"((a:1,b:2):1,c:3,d<x>:4);">>)),
    ?assertMatch(<<"<svg ", _/binary>>, S),
    ?assertEqual(4, length(binary:matches(S, <<"<text class=\"leaf\"">>))),     % four leaves, marked for the page
    ?assertNotEqual(nomatch, binary:match(S, <<"d&lt;x&gt;">>)).

job() ->
    #{id => <<"job-1">>, kind => genome, state => done, created => 1794600000000,
      steps => #{classify => #{results => [[#{<<"query">> => <<"s1">>,
                                              <<"call">> => #{<<"species">> => <<"Betacoronavirus pandemicum">>,
                                                              <<"genus">> => <<"Betacoronavirus">>,
                                                              <<"family">> => <<"Coronaviridae">>,
                                                              <<"organism">> => <<"SARS-CoV-2, \"Wuhan\"">>,
                                                              <<"ani">> => 0.999, <<"confidence">> => <<"high">>,
                                                              <<"ref">> => <<"NC_045512.2">>}}]]},
                 lineage => #{results => [[#{query => <<"s1">>, pango => <<"B">>, clade => <<"19A">>}]]},
                 mutations => #{results => [[#{query => <<"s1">>, substitutions => [[241, <<"C">>, <<"T">>]],
                                                insertions => [], deletions => [], missing => 0}]]},
                 knowledge => #{results => [#{links => [#{title => <<"NCBI (Taxonomy)">>, url => <<"https://x">>}]}]}}}.

csv_test() ->
    [Header, Row, <<>>] = binary:split(iolist_to_binary(gh_export:csv(job())), <<"\r\n">>, [global]),
    ?assertMatch(<<"sequence,species,", _/binary>>, Header),
    ?assertEqual(<<"s1,Betacoronavirus pandemicum,Betacoronavirus,Coronaviridae,\"SARS-CoV-2, \"\"Wuhan\"\"\",0.999,high,"
                   "minhash,NC_045512.2,B,19A,1,0,0,0">>, Row).

pdf_test() ->
    P = gh_export:pdf(job()),
    ?assertMatch(<<"%PDF-1.4", _/binary>>, P),
    ?assertNotEqual(nomatch, binary:match(P, <<"(NCBI \\(Taxonomy\\): https://x)">>)),
    %% the cross-reference table points at the objects
    {match, [Start]} = re:run(P, "startxref\\n([0-9]+)", [{capture, [1], binary}]),
    ?assertMatch(<<"xref", _/binary>>, binary:part(P, binary_to_integer(Start), 4)),
    {match, [Off1]} = re:run(P, "0000000000 65535 f \\n([0-9]{10})", [{capture, [1], binary}]),
    ?assertMatch(<<"1 0 obj", _/binary>>, binary:part(P, binary_to_integer(Off1), 7)).
