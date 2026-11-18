%% Commands for the site's operator, run with the site stopped (they open its Mnesia directory). The first admin is
%% made this way; later users are added on the page or through the API by an admin.
%%
%%   add_user NAME ROLE    the password is read from standard input (one line), never from the command line; prints
%%                         the user's TOTP secret, once, for an authenticator app
%%   audit_verify          whether the audit log's chain is whole
%%   check_references      downloads NCBI's current RefSeq viral genomes; if they changed, builds the new bundle
%%                         beside the site's and reports what changed (gh_refdb:check_update/0)
%%   apply_references      makes the checked bundle the site's, keeping the one before; rebuilds the proteins
%%   viewer_key KID FILE   a new Ed25519 key for the structure viewer (gh_viewer): the private key into FILE (mode 600;
%%                         never overwritten), the public key printed, to register with TechUPGRADE under KID
%%   build_usher_tree FASTA    the site's SARS-CoV-2 tree for placing new genomes (gh_refdb:usher_sars_cov_2/3), from
%%                         the genomes of FASTA (complete SARS-CoV-2 genomes); needs the site's reference bundles
%%
%% scripts/genhub2-admin.sh runs these in GenHub2's image.
-module(gh_cli).
-export([main/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    %% loaded, so the command line's -genhub2 settings (data_dir) apply
    ok = application:load(genhub2),
    ok = mnesia:start(),
    ok = case mnesia:table_info(schema, storage_type) of
             disc_copies -> ok;
             ram_copies -> {atomic, ok} = mnesia:change_table_copy_type(schema, node(), disc_copies), ok
         end,
    ok = gh_accounts:tables(),
    ok = gh_audit:tables(),
    {ok, _} = gh_audit:start_link(),
    Status = run(Args),
    %% Mnesia writes its log to disc in the background: stop it, so nothing written above is lost at halt
    stopped = mnesia:stop(),
    halt(Status).

run(["add_user", Name, Role]) ->
    case io:get_line("") of
        eof -> io:format(standard_error, "no password on standard input~n", []), 2;
        Line ->
            Pw = string:trim(unicode:characters_to_binary(Line), trailing, "\r\n"),
            N = list_to_binary(Name),
            R = case lists:member(Role, ["admin", "analyst", "researcher"]) of
                    true -> list_to_existing_atom(Role);
                    false -> bad_role
                end,
            case gh_accounts:create(N, R, Pw) of
                {ok, Secret} ->
                    ok = gh_audit:log(<<"cli">>, user_create, N, ok, #{role => R}),
                    io:format("user ~s (~s) created.~n"
                              "Add this to an authenticator app now; it is not shown again:~n"
                              "  secret ~s~n  ~s~n", [N, R, gh_totp:base32(Secret), gh_totp:uri(<<"GenHub2">>, N, Secret)]),
                    0;
                {error, Why} ->
                    ok = gh_audit:log(<<"cli">>, user_create, N, failed, #{reason => Why}),
                    io:format(standard_error, "not created: ~p~n", [Why]),
                    1
            end
    end;
run(["build_usher_tree", Fasta]) ->
    #{refs := Refs, nextclade := Next} = gh_config:params(),
    Mat = gh_refdb:usher_sars_cov_2(gh_store:put_file(Fasta), Refs, Next),
    ok = gh_audit:log(<<"cli">>, usher_tree_build, Mat, ok, #{fasta => list_to_binary(filename:basename(Fasta))}),
    io:format("the site's SARS-CoV-2 tree: ~s~n", [Mat]),
    0;
run(["check_references"]) ->
    case gh_refdb:check_update() of
        unchanged ->
            ok = gh_audit:log(<<"cli">>, references_check, <<>>, ok, #{result => unchanged}),
            io:format("NCBI's RefSeq viral genomes are unchanged since the site's bundle~n"), 0;
        {unchanged, same_content} ->
            ok = gh_audit:log(<<"cli">>, references_check, <<>>, ok, #{result => same_content}),
            io:format("NCBI's download is new, but its references, taxonomy and sequences are the site's: nothing to "
                      "update~n"), 0;
        {changed, R} ->
            #{added := A, removed := Rm, taxonomy_changed := T, sequence_changed := Sq,
              references := #{current := C, next := N}} = R,
            ok = gh_audit:log(<<"cli">>, references_check, maps:get(next, R), ok,
                              #{added => length(A), removed => length(Rm), taxonomy_changed => length(T),
                                sequence_changed => length(Sq)}),
            io:format("NCBI's RefSeq viral genomes changed: ~b references now, ~b in the site's bundle~n"
                      "  added ~b, removed ~b, taxonomy changed ~b, sequence changed ~b~n"
                      "  the new bundle is ready (refseq_viral.next, report refseq_viral.next.json);~n"
                      "  apply it with: apply_references~n", [N, C, length(A), length(Rm), length(T), length(Sq)]), 0
    end;
run(["apply_references"]) ->
    case gh_refdb:apply_update() of
        {ok, #{refseq_viral := New, refseq_viral_proteins := P, previous := Prev}} ->
            ok = gh_audit:log(<<"cli">>, references_apply, New, ok, #{previous => Prev, proteins => P}),
            io:format("the site's RefSeq bundle is now ~s (before: ~s); proteins ~s~n", [New, Prev, P]), 0;
        {error, nothing_to_apply} ->
            io:format(standard_error, "nothing to apply: run check_references first~n", []), 1
    end;
run(["viewer_key", Kid, File]) ->
    case filelib:is_file(File) of
        true -> io:format(standard_error, "~s exists: not overwritten~n", [File]), 1;
        false ->
            {_Pub, Priv} = gh_viewer:new_key(),
            ok = filelib:ensure_dir(File),
            ok = file:write_file(File, [], [exclusive]),
            ok = file:change_mode(File, 8#600),
            ok = file:write_file(File, base64:encode(Priv, #{mode => urlsafe, padding => false})),
            Pub = gh_viewer:public_key(File),
            ok = gh_audit:log(<<"cli">>, viewer_key, list_to_binary(Kid), ok, #{public_key => Pub}),
            io:format("kid ~s, Ed25519~npublic key (send this to TechUPGRADE; it is not secret): ~s~n"
                      "private key: ~s (mode 600; keep it outside the repository; never send it)~n", [Kid, Pub, File]),
            0
    end;
run(["audit_verify"]) ->
    case gh_audit:verify() of
        {ok, N} -> io:format("the audit chain of ~b records is whole~n", [N]), 0;
        {broken, S} -> io:format("the audit chain is broken at record ~b~n", [S]), 1
    end;
run(_) ->
    io:format(standard_error, "usage: add_user NAME admin|analyst|researcher (password on stdin) | audit_verify | "
              "build_usher_tree FASTA | check_references | apply_references | viewer_key KID FILE~n", []),
    2.
