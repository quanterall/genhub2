%% The site's content-addressed file store (FS 3.2: large data stays in the store and is referred to by hash). A file
%% is kept at <data_dir>/store/<first two hex digits>/<sha256 hex> and is never changed, so a hash names its content
%% everywhere: in tasks, results, provenance records and MQTT messages. Files are added as hard links where possible;
%% those GenHub2 wrote itself (in with_tmp/1's directories) are made read-only, so a write through another link fails
%% instead of changing the store. (A file added from elsewhere, e.g. a lab's genome index, keeps its owner's mode.)
%%
%% A task running on another of the owner's nodes fetches what it needs from the coordinating node's store
%% (ensure/2); between sites, the FVLLMP data route will do the same (FS 4.5).
-module(gh_store).
-export([root/0, path/1, put_file/1, move_file/1, put_binary/1, read/1, read_from/2, ensure/2, has/1, file_hash/1,
         with_tmp/1]).

-type hash() :: binary().
-export_type([hash/0]).

-spec root() -> file:filename().
root() ->
    filename:join(application:get_env(genhub2, data_dir, "data"), "store").

-spec path(hash()) -> file:filename().
path(<<A, B, _/binary>> = Hash) ->
    filename:join([root(), [A, B], binary_to_list(Hash)]).

-spec has(hash()) -> boolean().
has(Hash) -> filelib:is_regular(path(Hash)).

%% The file's content into the store (a hard link when possible, otherwise a copy); its hash.
-spec put_file(file:filename()) -> hash().
put_file(Src) ->
    Hash = file_hash(Src),
    Dst = path(Hash),
    case filelib:is_regular(Dst) andalso filelib:file_size(Dst) =:= filelib:file_size(Src) of
        true -> ok;
        false ->
            ok = filelib:ensure_dir(Dst),
            Tmp = Dst ++ ".part" ++ integer_to_list(erlang:unique_integer([positive])),
            case file:make_link(Src, Tmp) of
                ok -> ok;
                {error, _} -> {ok, _} = file:copy(Src, Tmp), ok
            end,
            ok = file:rename(Tmp, Dst),
            case lists:prefix(filename:absname(filename:join(root(), "tmp")), filename:absname(Src)) of
                true -> ok = file:change_mode(Dst, 8#444);
                false -> ok
            end
    end,
    Hash.

%% A file a task wrote (in with_tmp/1's directory) into the store, moved; its hash. (An entry already there is
%% kept only if its size matches: a partial earlier write is replaced.)
-spec move_file(file:filename()) -> hash().
move_file(Src) ->
    Hash = file_hash(Src),
    Dst = path(Hash),
    case filelib:is_regular(Dst) andalso filelib:file_size(Dst) =:= filelib:file_size(Src) of
        true -> ok = file:delete(Src);
        false -> ok = filelib:ensure_dir(Dst), ok = file:rename(Src, Dst), ok = file:change_mode(Dst, 8#444)
    end,
    Hash.

-spec put_binary(iodata()) -> hash().
put_binary(Data) ->
    with_tmp(fun(Dir) ->
                     F = filename:join(Dir, "data"),
                     ok = file:write_file(F, Data),
                     move_file(F)
             end).

-spec read(hash()) -> binary().
read(Hash) ->
    {ok, B} = file:read_file(ensure(Hash, node())),
    B.

%% the content of Hash, fetched first from Home's store if this node does not have it
-spec read_from(hash(), node()) -> binary().
read_from(Hash, Home) ->
    {ok, B} = file:read_file(ensure(Hash, Home)),
    B.

%% The local path of Hash, fetched first from Home's store if this node does not have it; the content is checked
%% against its hash.
-spec ensure(hash(), node()) -> file:filename().
ensure(Hash, Home) ->
    P = path(Hash),
    case filelib:is_regular(P) of
        true -> P;
        false when Home =:= node() -> error({not_in_store, Hash});
        false ->
            {ok, Bin} = erpc:call(Home, file, read_file, [erpc:call(Home, ?MODULE, path, [Hash])], 3600000),
            Hash = put_binary(Bin),
            P
    end.

-spec file_hash(file:filename()) -> hash().
file_hash(F) ->
    {ok, Fd} = file:open(F, [read, raw, binary, read_ahead]),
    try hash_loop(Fd, crypto:hash_init(sha256))
    after ok = file:close(Fd)
    end.

hash_loop(Fd, Ctx) ->
    case file:read(Fd, 4 bsl 20) of
        {ok, B} -> hash_loop(Fd, crypto:hash_update(Ctx, B));
        eof -> binary:encode_hex(crypto:hash_final(Ctx), lowercase)
    end.

%% Fun(Dir) with a fresh directory under the store, removed afterwards (the store's own file system, so results move
%% into the store without copying).
-spec with_tmp(fun((file:filename()) -> T)) -> T.
with_tmp(Fun) ->
    %% random: an OS process id and Erlang's unique integers repeat between runs in a container, and a directory
    %% left by a crashed run may hold hard links into the store
    Dir = filename:join([root(), "tmp", binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))]),
    ok = filelib:ensure_path(filename:dirname(Dir)),
    ok = file:make_dir(Dir),
    try Fun(Dir)
    after _ = file:del_dir_r(Dir)
    end.
