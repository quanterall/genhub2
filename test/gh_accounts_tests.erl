%% Accounts, one-time codes and the audit log: RFC 6238's test vectors; logins that need the password and a code, a
%% code used once, lockout, sessions; an audit chain that shows a changed or removed record.
-module(gh_accounts_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC 6238, appendix B (SHA-1, secret "12345678901234567890"): the last six digits of its 8-digit codes
totp_rfc6238_test() ->
    S = <<"12345678901234567890">>,
    [?assertEqual(Code, gh_totp:code(S, gh_totp:step(T)))
     || {T, Code} <- [{59, <<"287082">>}, {1111111109, <<"081804">>}, {1111111111, <<"050471">>},
                      {1234567890, <<"005924">>}, {2000000000, <<"279037">>}, {20000000000, <<"353130">>}]].

base32_test() ->
    S = gh_totp:new_secret(),
    ?assertEqual(32, byte_size(gh_totp:base32(S))),
    ?assertEqual(S, gh_totp:unbase32(gh_totp:base32(S))),
    ?assertEqual(<<"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ">>, gh_totp:base32(<<"12345678901234567890">>)).

accounts_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_) ->
             [{"a login needs the password and a code", {timeout, 60, fun login/0}},
              {"a code is accepted once", {timeout, 60, fun replay/0}},
              {"five failures lock the account", {timeout, 120, fun lockout/0}},
              {"sessions end at logout and when the user is disabled", {timeout, 60, fun sessions/0}},
              {"names, roles and passwords are checked", {timeout, 60, fun create_checks/0}},
              {"the audit chain shows a changed or removed record", fun audit_chain/0}]
     end}.

setup() ->
    Dir = filename:join("/tmp", "gh-accounts-" ++ os:getpid()),
    ok = application:set_env(mnesia, dir, Dir),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    ok = gh_accounts:tables(),
    ok = gh_audit:tables(),
    {ok, Pid} = gh_audit:start_link(),
    unlink(Pid),
    #{dir => Dir, audit => Pid}.

cleanup(#{dir := Dir, audit := Pid}) ->
    exit(Pid, kill),
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    file:del_dir_r(Dir).

now_code(Secret) -> gh_totp:code(Secret, gh_totp:step(erlang:system_time(second))).
next_code(Secret) -> gh_totp:code(Secret, gh_totp:step(erlang:system_time(second)) + 1).

login() ->
    {ok, S} = gh_accounts:create(<<"ana">>, analyst, <<"correct horse battery">>),
    ?assertEqual({error, denied}, gh_accounts:login(<<"ana">>, <<"wrong password!">>, now_code(S))),
    ?assertEqual({error, denied}, gh_accounts:login(<<"ana">>, <<"correct horse battery">>, <<"000000">>)),
    ?assertEqual({error, denied}, gh_accounts:login(<<"nobody">>, <<"correct horse battery">>, now_code(S))),
    {ok, Token, analyst} = gh_accounts:login(<<"ana">>, <<"correct horse battery">>, now_code(S)),
    ?assertEqual({ok, <<"ana">>, analyst}, gh_accounts:session(Token)),
    ?assertEqual(error, gh_accounts:session(<<"not a token">>)).

replay() ->
    {ok, S} = gh_accounts:create(<<"ben">>, admin, <<"another long password">>),
    Code = now_code(S),
    {ok, _, admin} = gh_accounts:login(<<"ben">>, <<"another long password">>, Code),
    ?assertEqual({error, denied}, gh_accounts:login(<<"ben">>, <<"another long password">>, Code)),
    %% the next step's code is still accepted (clock drift), once
    {ok, _, admin} = gh_accounts:login(<<"ben">>, <<"another long password">>, next_code(S)).

lockout() ->
    {ok, S} = gh_accounts:create(<<"cara">>, researcher, <<"yet another password">>),
    [?assertEqual({error, denied}, gh_accounts:login(<<"cara">>, <<"guess number ", (integer_to_binary(I))/binary>>, now_code(S)))
     || I <- lists:seq(1, 5)],
    %% locked: even the right password and code are refused
    ?assertEqual({error, locked}, gh_accounts:login(<<"cara">>, <<"yet another password">>, now_code(S))),
    [#{locked := true}] = [U || #{name := <<"cara">>} = U <- gh_accounts:users()].

sessions() ->
    {ok, S} = gh_accounts:create(<<"dan">>, analyst, <<"a password of length">>),
    {ok, T1, _} = gh_accounts:login(<<"dan">>, <<"a password of length">>, now_code(S)),
    ok = gh_accounts:logout(T1),
    ?assertEqual(error, gh_accounts:session(T1)),
    {ok, T2, _} = gh_accounts:login(<<"dan">>, <<"a password of length">>, next_code(S)),
    ok = gh_accounts:disable(<<"dan">>),
    ?assertEqual(error, gh_accounts:session(T2)),
    ?assertEqual({error, denied}, gh_accounts:login(<<"dan">>, <<"a password of length">>, now_code(S))).

create_checks() ->
    ?assertEqual({error, bad_name}, gh_accounts:create(<<"Eve Smith">>, analyst, <<"long enough password">>)),
    ?assertEqual({error, password_too_short}, gh_accounts:create(<<"eve">>, analyst, <<"short">>)),
    ?assertEqual({error, bad_role}, gh_accounts:create(<<"eve">>, root, <<"long enough password">>)),
    {ok, _} = gh_accounts:create(<<"eve">>, analyst, <<"long enough password">>),
    ?assertEqual({error, exists}, gh_accounts:create(<<"eve">>, admin, <<"long enough password">>)).

audit_chain() ->
    {ok, N0} = gh_audit:verify(),
    [ok = gh_audit:log(<<"ana">>, job_view, integer_to_binary(I), ok) || I <- lists:seq(1, 3)],
    ?assertEqual({ok, N0 + 3}, gh_audit:verify()),
    [R] = mnesia:dirty_read(gh_audit, N0 + 2),
    ok = mnesia:dirty_write(setelement(5, R, <<"mallory">>)),
    ?assertEqual({broken, N0 + 2}, gh_audit:verify()),
    ok = mnesia:dirty_write(R),
    ?assertEqual({ok, N0 + 3}, gh_audit:verify()),
    ok = mnesia:dirty_delete(gh_audit, N0 + 2),
    ?assertEqual({broken, N0 + 3}, gh_audit:verify()),
    ok = mnesia:dirty_write(R).
