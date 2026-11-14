%% Task protein (FS 5.1): classification by the viral proteins a genome encodes, for genomes too divergent for
%% nucleotide MinHash (gh_classify's low-confidence and unclassified calls). Every frame of the genome is searched
%% against all RefSeq viral proteins with DIAMOND blastx (Buchfink et al. 2021, doi:10.1038/s41592-021-01101-x);
%% in frameshift mode (-F 15) with range culling, each region of the genome keeps its best hits (within 1% of the
%% best score). Each region's
%% best hit votes for its species with its bit score; the call is the species with the highest total.
%% Confidence from the bit-score-weighted amino-acid identity of the votes for it: high >= 90%, medium >= 70%, low
%% below; no hit: unclassified.
%%   {protein, GenomesHash, ProteinBundle} -> [#{query, call, regions}] in the file's order
-module(gh_protein).
-behaviour(pq_task).
-export([run/2, resources/1, describe/1, call/1]).

run({protein, Genomes, Proteins}, #{home := Home}) ->
    G = gh_store:ensure(Genomes, Home),
    Out = gh_tool:bash("diamond blastx --quiet --threads \"$1\" -d \"$2\" -q \"$3\" -F 15 --range-culling --top 1"
                       " -e 1e-5 --outfmt 6 qseqid sseqid pident length bitscore qstart qend",
                       [integer_to_list(gh_tool:threads()), gh_refs:file(Proteins, "proteins.dmnd", Home), G]),
    Tax = gh_refs:taxonomy(Proteins, Home),
    Hits = lists:foldl(fun(L, M) ->
                               [Q, S, Pid, _Len, Bits, QS, QE] = binary:split(L, <<"\t">>, [global]),
                               H = {S, num(Pid), num(Bits), {binary_to_integer(QS), binary_to_integer(QE)}},
                               maps:update_with(Q, fun(Hs) -> [H | Hs] end, [H], M)
                       end, #{}, binary:split(Out, <<"\n">>, [global, trim_all])),
    [call_of(Q, lists:reverse(maps:get(Q, Hits, [])), Tax) || Q <- gh_mutations:ids(G)].

call_of(Q, [], _Tax) ->
    #{query => Q, regions => 0, call => #{confidence => unclassified, method => protein}};
call_of(Q, Hits, Tax) ->
    %% one vote per region: the best-scoring hit (ties: the first DIAMOND reports)
    Regions = lists:foldl(fun({_, _, B, R} = H, M) ->
                                  case maps:get(R, M, none) of
                                      {_, _, B0, _} when B0 >= B -> M;
                                      _ -> M#{R => H}
                                  end
                          end, #{}, Hits),
    Votes = [{maps:get(S, Tax, #{species => <<>>}), Pid, B, S} || {S, Pid, B, _} <- maps:values(Regions)],
    Score = lists:foldl(fun({T, _, B, _}, M) -> maps:update_with(maps:get(species, T), fun(X) -> X + B end, B, M) end,
                        #{}, Votes),
    {_, Species} = lists:max([{B, Sp} || {Sp, B} <- maps:to_list(Score)]),
    Mine = [V || {T, _, _, _} = V <- Votes, maps:get(species, T) =:= Species],
    Bits = lists:sum([B || {_, _, B, _} <- Mine]),
    Ident = lists:sum([P * B || {_, P, B, _} <- Mine]) / Bits / 100,
    {T, _, _, Best} = hd(lists:reverse(lists:keysort(3, Mine))),
    #{query => Q, regions => maps:size(Regions),
      call => call(#{species => Species, genus => maps:get(genus, T, <<>>), family => maps:get(family, T, <<>>),
                     organism => maps:get(organism, T, <<>>), taxid => maps:get(taxid, T, 0), protein => Best,
                     aa_identity => Ident, bitscore => Bits, share => Bits / lists:sum([B || {_, _, B, _} <- Votes])})}.

%% the confidence of a protein call from its amino-acid identity
-spec call(map()) -> map().
call(#{aa_identity := I} = C) ->
    C#{method => protein, confidence => if I >= 0.9 -> high; I >= 0.7 -> medium; true -> low end}.

num(B) -> try binary_to_float(B) catch error:badarg -> float(binary_to_integer(B)) end.

resources({protein, _, Proteins}) -> #{cpu => gh_tool:threads(), memory_mb => 8000, data => [Proteins]}.

describe({protein, _, Proteins}) -> #{task => protein, tool => diamond, proteins => Proteins}.
