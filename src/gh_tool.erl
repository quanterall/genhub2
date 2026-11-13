%% External programs (FS 4.2): every tool runs as a separate OS process, so a tool's crash fails one task and never
%% the node. Arguments are passed as a list (no shell quoting); pipelines run under bash with the arguments as $1..$n.
-module(gh_tool).
-export([run/2, must/2, bash/2, gh2k/1, gh2k_must/1, threads/0]).

%% {ExitStatus, Stdout}; standard error goes to the node's own.
-spec run(string(), [string() | binary()]) -> {non_neg_integer(), binary()}.
run(Exe, Args) ->
    Path = case filename:pathtype(Exe) of
               absolute -> Exe;
               _ -> os:find_executable(Exe)
           end,
    Path =/= false orelse error({tool_not_found, Exe}),
    Port = open_port({spawn_executable, Path}, [{args, Args}, exit_status, binary, use_stdio, hide]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, [D | Acc]);
        {Port, {exit_status, S}} -> {S, iolist_to_binary(lists:reverse(Acc))}
    end.

%% Stdout, or error({tool_failed, Exe, Status, LastBytesOfStdout}).
-spec must(string(), [string() | binary()]) -> binary().
must(Exe, Args) ->
    case run(Exe, Args) of
        {0, Out} -> Out;
        {S, Out} -> error({tool_failed, Exe, S, tail(Out)})
    end.

%% A bash script with -euo pipefail, its arguments as $1..$n; its stdout, or error({tool_failed, Script, Status,
%% Stdout, Stderr}) with the tails of both outputs.
-spec bash(string(), [string() | binary()]) -> binary().
bash(Script, Args) ->
    Err = filename:join(os:getenv("TMPDIR", "/tmp"), "genhub2-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try run("/bin/bash", ["-c", "set -euo pipefail\nexec 2>\"$0\"\n" ++ Script, Err | Args]) of
        {0, Out} -> Out;
        {S, Out} ->
            Stderr = case file:read_file(Err) of {ok, E} -> tail(E); _ -> <<>> end,
            error({tool_failed, Script, S, tail(Out), Stderr})
    after
        _ = file:delete(Err)
    end.

%% GenHub2's Rust kernels (native/gh2k): {Status, Stdout}.
-spec gh2k([string() | binary()]) -> {non_neg_integer(), binary()}.
gh2k(Args) ->
    run(filename:absname(filename:join(code:priv_dir(genhub2), "gh2k")), Args).

-spec gh2k_must([string() | binary()]) -> binary().
gh2k_must(Args) ->
    case gh2k(Args) of
        {0, Out} -> Out;
        {S, Out} -> error({tool_failed, gh2k, S, tail(Out)})
    end.

%% threads a tool may use: the application's setting, or 4
-spec threads() -> pos_integer().
threads() -> application:get_env(genhub2, tool_threads, 4).

tail(B) when byte_size(B) > 2000 -> binary:part(B, byte_size(B), -2000);
tail(B) -> B.
