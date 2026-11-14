%% Task kraken (FS 5.1): what a read set is made of, read by read, for mixed samples (co-infections, metagenomic
%% sequencing): every read pair classified by Kraken 2 (Wood et al. 2019, doi:10.1186/s13059-019-1891-0) against a
%% prebuilt viral database, then the species' shares of the reads re-estimated by Bracken (Lu et al. 2017,
%% doi:10.7717/peerj-cs.104) from the reads Kraken 2 could only place higher in the taxonomy.
%%   {kraken, R1, R2, KrakenBundle, ReadLength} -> #{pairs, classified, species := [#{name, taxid, reads, share}]}
%%   species with a share of at least 0.1%, largest first
-module(gh_kraken).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1]).

run({kraken, R1, R2, Bundle, ReadLength}, #{home := Home}) ->
    Db = filename:join(gh_refs:dir(Bundle, Home), "kraken"),
    gh_store:with_tmp(
      fun(Dir) ->
              [Report, BReport, BOut] = [filename:join(Dir, F) || F <- ["kraken.report", "bracken.report", "bracken.tsv"]],
              _ = gh_tool:bash("kraken2 --db \"$1\" --threads \"$2\" --paired --report \"$3\" --output /dev/null"
                               " \"$4\" \"$5\" 2>/dev/null",
                               [Db, integer_to_list(gh_tool:threads()), Report, gh_store:ensure(R1, Home),
                                gh_store:ensure(R2, Home)]),
              Len = bracken_length(Db, ReadLength),
              _ = gh_tool:bash("bracken -d \"$1\" -i \"$2\" -o \"$3\" -w \"$4\" -r \"$5\" -l S -t 10 >/dev/null 2>&1",
                               [Db, Report, BOut, BReport, integer_to_list(Len)]),
              {ok, K} = file:read_file(Report),
              Rows = [binary:split(L, <<"\t">>, [global]) || L <- binary:split(K, <<"\n">>, [global, trim_all])],
              Unclassified = lists:sum([binary_to_integer(string:trim(N)) || [_, N, _, <<"U">> | _] <- Rows]),
              Pairs = gh_fastq:count(gh_store:ensure(R1, Home)),
              {ok, B} = file:read_file(BOut),
              [_ | BRows] = [binary:split(L, <<"\t">>, [global]) || L <- binary:split(B, <<"\n">>, [global, trim_all])],
              Species = [#{name => N, taxid => binary_to_integer(T), reads => binary_to_integer(Reads), share => num(F)}
                         || [N, T, _Level, _K, _Add, Reads, F] <- BRows],
              Big = [{maps:get(reads, S), S} || S <- Species, maps:get(share, S) >= 0.001],
              #{pairs => Pairs, classified => Pairs - Unclassified, bracken_read_length => Len,
                species => [S || {_, S} <- lists:reverse(lists:keysort(1, Big))]}
      end).

%% the read length of the database's k-mer distributions nearest to the reads'
bracken_length(Db, ReadLength) ->
    Ls = [list_to_integer(L) || F <- filelib:wildcard(filename:join(Db, "database*mers.kmer_distrib")),
                                {match, [L]} <- [re:run(filename:basename(F), "database([0-9]+)mers", [{capture, [1], list}])]],
    element(2, lists:min([{abs(L - ReadLength), L} || L <- Ls])).

num(B) -> try binary_to_float(B) catch error:badarg -> float(binary_to_integer(B)) end.

resources({kraken, _, _, Bundle, _}) -> #{cpu => gh_tool:threads(), memory_mb => 2000, data => [Bundle]}.

describe({kraken, _, _, Bundle, Len}) -> #{task => kraken, tools => [kraken2, bracken], db => Bundle, read_length => Len}.
