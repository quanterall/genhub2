%% FASTQ helpers for the tasks.
-module(gh_fastq).
-export([count/1]).

%% the number of records of a plain FASTQ file
-spec count(file:filename()) -> non_neg_integer().
count(F) ->
    {ok, Fd} = file:open(F, [read, raw, binary, read_ahead]),
    try lines(Fd, 0) div 4
    after ok = file:close(Fd)
    end.

lines(Fd, N) ->
    case file:read(Fd, 8 bsl 20) of
        {ok, B} -> lines(Fd, N + length(binary:matches(B, <<"\n">>)));
        eof -> N
    end.
