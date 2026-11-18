%% Encryption at rest (FS 3.4, 6.2: AES-256 for each site's stored data). The analysis tools read the store's files
%% directly, so the encryption belongs under the site's data: an encrypted volume, Linux dm-crypt with LUKS
%% (AES-256-XTS by default), set up by the machine's owner. GenHub2 checks at start that its data directory and its
%% Mnesia directory are on one:
%%   the directory's mount (/proc/self/mountinfo, the longest mount point it is under) gives its block device; the
%%   device is encrypted when it, or a device it is built on (LVM over LUKS, a partition of one), is a dm-crypt
%%   device (/sys/dev/block/<major:minor>/dm/uuid begins with CRYPT-).
%% A filesystem without a block device (tmpfs, overlay, ZFS, NFS) cannot be checked this way: unknown.
%%
%% Setting storage_encryption: required (the default: the node does not start unless both are encrypted), warn
%% (it starts, and logs and audits a warning), off (no check; for development only).
-module(gh_storage).
-export([check/1, check/2, enforce/0, status/0]).

-type result() :: {encrypted | unencrypted, binary()} | {unknown, binary()}.

%% the result for every directory GenHub2 keeps data in, as found at start
-spec status() -> #{binary() => result()} | off.
status() -> persistent_term:get({?MODULE, status}, off).

%% at start: checks the data and Mnesia directories as the setting says; ok, or error({storage_not_encrypted, ...})
-spec enforce() -> ok.
enforce() ->
    case application:get_env(genhub2, storage_encryption, required) of
        off -> persistent_term:put({?MODULE, status}, off), ok;
        Mode when Mode =:= required; Mode =:= warn ->
            Dirs = lists:usort([filename:absname(application:get_env(genhub2, data_dir, "data")),
                                filename:absname(mnesia:system_info(directory))]),
            Status = maps:from_list([{list_to_binary(D), check(D)} || D <- Dirs]),
            persistent_term:put({?MODULE, status}, Status),
            Bad = maps:filter(fun(_, {encrypted, _}) -> false; (_, _) -> true end, Status),
            case {maps:size(Bad), Mode} of
                {0, _} -> ok;
                {_, required} ->
                    logger:critical("GenHub2 will not start: its data is not on an encrypted volume: ~p. Put the data "
                                    "directory on a LUKS volume, or set storage_encryption to warn (not for patients' "
                                    "data).", [Bad]),
                    error({storage_not_encrypted, Bad});
                {_, warn} ->
                    logger:warning("GenHub2's data is not on an encrypted volume: ~p (storage_encryption warn)", [Bad]),
                    ok
            end
    end.

-spec check(file:filename()) -> result().
check(Dir) -> check(Dir, #{mountinfo => "/proc/self/mountinfo", sys => "/sys"}).

%% with the files to read given, for tests
-spec check(file:filename(), #{mountinfo := file:filename(), sys := file:filename()}) -> result().
check(Dir, #{mountinfo := MI, sys := Sys}) ->
    case file:read_file(MI) of
        {ok, B} ->
            Abs = filename:absname(Dir),
            Mounts = [{unescape(MP), Dev} || L <- binary:split(B, <<"\n">>, [global, trim_all]),
                                             [_, _, Dev, _, MP | _] <- [binary:split(L, <<" ">>, [global])]],
            Under = [{byte_size(MP), MP, Dev} || {MP, Dev} <- Mounts, under(list_to_binary(Abs), MP)],
            case lists:reverse(lists:sort(Under)) of
                [] -> {unknown, <<"no mount found">>};
                [{_, MP, <<"0:", _/binary>> = Dev} | _] -> {unknown, <<MP/binary, " has no block device (", Dev/binary, ")">>};
                [{_, _, Dev} | _] ->
                    case crypt(Sys, Dev, 0) of
                        true -> {encrypted, Dev};
                        false -> {unencrypted, Dev}
                    end
            end;
        {error, R} -> {unknown, iolist_to_binary(io_lib:format("~p", [R]))}
    end.

under(Path, <<"/">>) -> binary:first(Path) =:= $/;
under(Path, MP) -> Path =:= MP orelse binary:match(Path, <<MP/binary, "/">>) =:= {0, byte_size(MP) + 1}.

%% mountinfo escapes spaces and the like as \ooo
unescape(B) -> iolist_to_binary(re:replace(B, "\\\\([0-7]{3})", fun_unescape(), [global])).
fun_unescape() -> fun(_, [Oct]) -> <<(binary_to_integer(Oct, 8))>> end.

%% is the block device major:minor, or one it is built on, a dm-crypt device
crypt(_Sys, _Dev, Depth) when Depth > 8 -> false;
crypt(Sys, Dev, Depth) ->
    Base = filename:join([Sys, "dev", "block", binary_to_list(Dev)]),
    case file:read_file(filename:join([Base, "dm", "uuid"])) of
        {ok, <<"CRYPT-", _/binary>>} -> true;
        _ ->
            Slaves = case file:list_dir(filename:join(Base, "slaves")) of
                         {ok, Ns} -> Ns;
                         {error, _} -> []
                     end,
            %% a partition's own dm and slaves are its disk's: look at the parent device too
            Parent = case file:read_file(filename:join(Base, "partition")) of
                         {ok, _} -> parent(Base);
                         {error, _} -> []
                     end,
            lists:any(fun(D) -> crypt(Sys, D, Depth + 1) end,
                      [dev(Sys, N) || N <- Slaves] ++ Parent)
    end.

dev(Sys, Name) ->
    case file:read_file(filename:join([Sys, "class", "block", Name, "dev"])) of
        {ok, D} -> string:trim(D);
        {error, _} -> <<"none">>
    end.

parent(Base) ->
    case file:read_file(filename:join([Base, "..", "dev"])) of
        {ok, D} -> [string:trim(D)];
        {error, _} -> []
    end.
