%% Commands for the site's operator, run with the site stopped (they open its Mnesia directory). The first admin is
%% made this way; later users are added on the page or through the API by an admin.
%%
%%   add_user NAME ROLE    the password is read from standard input (one line), never from the command line; prints
%%                         the user's TOTP secret, once, for an authenticator app
%%   audit_verify          whether the audit log's chain is whole
%%
%% scripts/genhub2-admin.sh runs these in GenHub2's image.
-module(gh_cli).
-export([main/1]).

-spec main([string()]) -> no_return().
main(Args) ->
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
run(["audit_verify"]) ->
    case gh_audit:verify() of
        {ok, N} -> io:format("the audit chain of ~b records is whole~n", [N]), 0;
        {broken, S} -> io:format("the audit chain is broken at record ~b~n", [S]), 1
    end;
run(_) ->
    io:format(standard_error, "usage: add_user NAME admin|analyst|researcher (password on stdin) | audit_verify~n", []),
    2.
