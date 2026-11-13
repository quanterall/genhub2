%% NCBI Datasets (v2 REST API, https://www.ncbi.nlm.nih.gov/datasets/docs/v2/api/) for the reference database and
%% the acceptance tests: virus genome records and their downloads, and the taxonomy (species, genus, family) of tax
%% ids.
-module(gh_ncbi).
-export([virus_reports/3, taxonomy/1, genome_download_url/2, accession_download_url/1, esearch/2]).

-define(API, "https://api.ncbi.nlm.nih.gov/datasets/v2").

%% The genome records of a virus taxon (an id or a name), up to Max, with the API's filters (e.g.
%% #{"filter.complete_only" => "true"}), in the API's order.
-spec virus_reports(string(), #{string() => string()}, pos_integer()) -> [map()].
virus_reports(Taxon, Filters, Max) ->
    reports(Taxon, Filters, Max, undefined, []).

reports(Taxon, Filters, Max, Token, Acc) ->
    Page = list_to_integer(maps:get("page_size", Filters, "1000")),
    Q = Filters#{"page_size" => integer_to_list(min(Page, Max - length(Acc)))},
    Q2 = case Token of undefined -> Q; _ -> Q#{"page_token" => binary_to_list(Token)} end,
    Url = ?API ++ "/virus/taxon/" ++ uri_string:quote(Taxon) ++ "/dataset_report?" ++ uri_string:compose_query(maps:to_list(Q2)),
    D = json:decode(get_retrying(Url, 4)),
    Acc2 = Acc ++ maps:get(<<"reports">>, D, []),
    case maps:get(<<"next_page_token">>, D, undefined) of
        T when T =/= undefined, length(Acc2) < Max -> reports(Taxon, Filters, Max, T, Acc2);
        _ -> lists:sublist(Acc2, Max)
    end.

%% NCBI's servers answer large queries with 500 now and then, and too many with 429: more tries, a minute apart
get_retrying(Url, 1) -> gh_fetch:get(Url);
get_retrying(Url, N) ->
    try gh_fetch:get(Url)
    catch error:{http, S, _, _} when S >= 500; S =:= 429 -> timer:sleep(60000), get_retrying(Url, N - 1)
    end.

%% tax id => #{species, genus, family, name} (empty binaries for ranks the taxon does not have), 1,000 ids a request
-spec taxonomy([integer()]) -> #{integer() => map()}.
taxonomy(Ids) ->
    lists:foldl(fun(Batch, Acc) -> maps:merge(Acc, taxonomy_batch(Batch)) end, #{}, chunks(lists:usort(Ids), 1000)).

taxonomy_batch(Ids) ->
    Body = json:encode(#{<<"taxons">> => [integer_to_binary(I) || I <- Ids], <<"page_size">> => 1000}),
    {ok, _} = application:ensure_all_started([inets, ssl]),
    {ok, {{_, 200, _}, _, R}} = httpc:request(post, {?API ++ "/taxonomy/dataset_report", [], "application/json", Body},
                                              [{timeout, 600000}, {ssl, [{verify, verify_peer},
                                                                          {cacerts, public_key:cacerts_get()},
                                                                          {customize_hostname_check,
                                                                           [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}],
                                              [{body_format, binary}]),
    maps:from_list([begin
                        T = maps:get(<<"taxonomy">>, Rep),
                        C = maps:get(<<"classification">>, T, #{}),
                        N = fun(K) -> maps:get(<<"name">>, maps:get(K, C, #{}), <<>>) end,
                        {maps:get(<<"tax_id">>, T),
                         #{species => N(<<"species">>), genus => N(<<"genus">>), family => N(<<"family">>),
                           name => maps:get(<<"name">>, maps:get(<<"current_scientific_name">>, T, #{}), <<>>)}}
                    end || Rep <- maps:get(<<"reports">>, json:decode(R), []), is_map_key(<<"taxonomy">>, Rep)]).

chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].

%% The URL of a zip of a taxon's genomes (FASTA and data_report.jsonl), with the API's filters.
-spec genome_download_url(string(), #{string() => string()}) -> string().
genome_download_url(Taxon, Filters) ->
    ?API ++ "/virus/taxon/" ++ uri_string:quote(Taxon) ++ "/genome/download?"
        ++ uri_string:compose_query(maps:to_list(Filters#{"include_sequence" => "GENOME"})).

%% The URL of a zip of the genomes with these accessions.
-spec accession_download_url([binary()]) -> string().
accession_download_url(Accs) ->
    lists:flatten([?API, "/virus/accession/", lists:join(",", [binary_to_list(A) || A <- Accs]),
                   "/genome/download?include_sequence=GENOME"]).

%% The accessions (with versions) of up to Max nucleotide records matching an Entrez query (E-utilities esearch),
%% in Entrez's order.
-spec esearch(string(), pos_integer()) -> [binary()].
esearch(Term, Max) ->
    Url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?"
        ++ uri_string:compose_query([{"db", "nuccore"}, {"retmode", "json"}, {"idtype", "acc"},
                                     {"retmax", integer_to_list(Max)}, {"term", Term}]),
    timer:sleep(400),                       % E-utilities without an API key: at most 3 requests a second
    maps:get(<<"idlist">>, maps:get(<<"esearchresult">>, json:decode(get_retrying(Url, 4)))).
