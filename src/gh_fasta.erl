%% FASTA helpers for the services.
-module(gh_fasta).
-export([records/1, seq_hashes/1]).

%% [{Id, Rest}] of a FASTA file, Rest the remainder of the header line and the sequence lines as they are
-spec records(file:filename()) -> [{binary(), binary()}].
records(F) ->
    {ok, B} = file:read_file(F),
    [begin
         {Id, Rest} = case binary:match(R, [<<" ">>, <<"\t">>, <<"\n">>]) of
                          {P, _} -> {binary:part(R, 0, P), binary:part(R, P, byte_size(R) - P)};
                          nomatch -> {R, <<>>}
                      end,
         {Id, Rest}
     end || R <- tl(binary:split(<<"\n", B/binary>>, <<"\n>">>, [global])), R =/= <<>>].

%% Id => sha256 of the sequence (upper case, without line breaks), for finding identical genomes
-spec seq_hashes(file:filename()) -> #{binary() => binary()}.
seq_hashes(F) ->
    maps:from_list([{Id, crypto:hash(sha256, string:uppercase(binary:replace(Seq, [<<"\n">>, <<"\r">>], <<>>, [global])))}
                    || {Id, Rest} <- records(F),
                       Seq <- [case binary:split(Rest, <<"\n">>) of [_, S] -> S; [_] -> <<>> end]]).
