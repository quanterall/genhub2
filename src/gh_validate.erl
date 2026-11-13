%% Task validate (FS 3.1, 3.2): an uploaded FASTA/FASTQ file (gzipped or not) checked and normalised by gh2k
%% validate: upper case, RNA as cDNA. Runs at the lab holding the file.
%%   {validate, FileHash} -> #{ok := true, report := Report, output := Hash} | #{ok := false, report := Report}
-module(gh_validate).
-behaviour(pq_task).
-export([run/2, describe/1]).

run({validate, In}, #{home := Home}) ->
    Src = gh_store:ensure(In, Home),
    gh_store:with_tmp(
      fun(Dir) ->
              Plain = plain(Src, Dir),
              Out = filename:join(Dir, "normalised"),
              case gh_tool:gh2k(["validate", Plain, Out]) of
                  {0, Json} -> #{ok => true, report => json:decode(Json), output => gh_store:move_file(Out)};
                  {2, Json} -> #{ok => false, report => json:decode(Json)};
                  {S, Out2} -> error({tool_failed, gh2k, S, Out2})
              end
      end).

plain(Src, Dir) ->
    {ok, Fd} = file:open(Src, [read, raw, binary]),
    Magic = file:read(Fd, 2),
    ok = file:close(Fd),
    case Magic of
        {ok, <<16#1f, 16#8b>>} ->
            Out = filename:join(Dir, "input"),
            _ = gh_tool:bash("gzip -dc \"$1\" > \"$2\"", [Src, Out]),
            Out;
        _ -> Src
    end.

describe({validate, _}) -> #{task => validate, tool => gh2k}.
