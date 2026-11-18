%% Encryption at rest (gh_storage), on a fake /proc/self/mountinfo and /sys: LUKS, LVM over LUKS, a partition of an
%% encrypted disk, a plain partition, tmpfs.
-module(gh_storage_tests).
-include_lib("eunit/include/eunit.hrl").

storage_test_() ->
    {setup, fun setup/0, fun(Dir) -> file:del_dir_r(Dir) end,
     fun(Dir) ->
             C = fun(Path) -> gh_storage:check(Path, #{mountinfo => filename:join(Dir, "mountinfo"), sys => filename:join(Dir, "sys")}) end,
             [?_assertEqual({encrypted, <<"253:0">>}, C("/srv/luks/genhub2/data")),
              ?_assertEqual({encrypted, <<"253:2">>}, C("/srv/lvm/data")),
              ?_assertEqual({encrypted, <<"259:5">>}, C("/srv/part")),
              ?_assertEqual({unencrypted, <<"259:2">>}, C("/home/atech/genhub2/data")),
              ?_assertMatch({unknown, _}, C("/tmp/x")),
              %% the longest mount point wins, and /srv/luks is not /srv/luksy
              ?_assertEqual({unencrypted, <<"259:2">>}, C("/srv/luksy")),
              %% a mount point with a space, escaped in mountinfo as \040
              ?_assertEqual({encrypted, <<"253:0">>}, C("/mnt/my data/x")),
              ?_assertMatch({unknown, _}, gh_storage:check("/x", #{mountinfo => filename:join(Dir, "none"), sys => Dir}))]
     end}.

setup() ->
    Dir = filename:join("/tmp", "gh-storage-" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "mountinfo"), [
        "22 1 259:2 / / rw,relatime - ext4 /dev/nvme0n1p2 rw\n",
        "30 22 253:0 / /srv/luks rw - ext4 /dev/mapper/luks-data rw\n",
        "31 22 253:2 / /srv/lvm rw - xfs /dev/mapper/vg-data rw\n",
        "32 22 259:5 / /srv/part rw - ext4 /dev/sdb1 rw\n",
        "33 22 0:45 / /tmp rw - tmpfs tmpfs rw\n",
        "34 22 253:0 / /mnt/my\\040data rw - ext4 /dev/mapper/luks-data rw\n"]),
    Sys = filename:join(Dir, "sys"),
    Block = fun(Dev, Files) ->
                    D = filename:join([Sys, "dev", "block", Dev]),
                    ok = filelib:ensure_path(D),
                    [begin ok = filelib:ensure_dir(filename:join(D, F)), ok = file:write_file(filename:join(D, F), V) end
                     || {F, V} <- Files],
                    D
            end,
    %% LUKS: dm-crypt
    Block("253:0", [{"dm/uuid", "CRYPT-LUKS2-abc-luks-data\n"}]),
    %% LVM over LUKS: 253:2 (LVM) is built on dm-1 (253:1, LUKS)
    Block("253:1", [{"dm/uuid", "CRYPT-LUKS2-def-luks-pv\n"}]),
    L = Block("253:2", [{"dm/uuid", "LVM-xyz\n"}]),
    ok = filelib:ensure_path(filename:join([L, "slaves", "dm-1"])),
    ok = filelib:ensure_dir(filename:join([Sys, "class", "block", "dm-1", "dev"])),
    ok = file:write_file(filename:join([Sys, "class", "block", "dm-1", "dev"]), "253:1\n"),
    %% a partition (259:5) of a disk (259:4) that is itself on dm-crypt (its slave: dm-0, 253:0)
    Disk = Block("259:4", [{"dev", "259:4\n"}]),
    ok = filelib:ensure_path(filename:join([Disk, "slaves", "dm-0"])),
    ok = filelib:ensure_dir(filename:join([Sys, "class", "block", "dm-0", "dev"])),
    ok = file:write_file(filename:join([Sys, "class", "block", "dm-0", "dev"]), "253:0\n"),
    Part = filename:join(Disk, "part5"),
    ok = filelib:ensure_path(Part),
    ok = file:write_file(filename:join(Part, "partition"), "5\n"),
    ok = file:make_symlink(Part, filename:join([Sys, "dev", "block", "259:5"])),
    %% a plain partition
    Block("259:2", [{"partition", "2\n"}]),
    Dir.
