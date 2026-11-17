%% Accounts, roles and sessions (FS 3.1 user account management, 3.4 access control, 6.2 role-based access).
%%
%% Roles:
%%   admin       the lab's administrator: everything, and the users and the audit log
%%   analyst     the lab's analysts: uploads, analyses, trees, results and exports, monitoring
%%   researcher  an external researcher: the site's aggregated counts (and, with sharing, the datasets shared with
%%               them)
%%
%% A login needs the password and a one-time code from the user's authenticator app (gh_totp: multi-factor). Passwords
%% are kept only as PBKDF2-HMAC-SHA256 hashes, 600,000 iterations, 16-byte salt (OWASP's recommendation for PBKDF2;
%% RFC 8018, doi:10.17487/RFC8018). Five failed logins in a row lock an account for 15 minutes. A code is accepted
%% once. A session is a random 32-byte token, given to the browser as a cookie; the site keeps only its SHA-256. A
%% session ends after 30 minutes without use, 12 hours after login, at logout, or when its user is disabled.
%%
%% Tables (this site only): gh_user (disc copies), gh_session (memory: a restart ends every session).
-module(gh_accounts).
-export([tables/0, create/3, users/0, disable/1, login/3, session/1, logout/1, roles/0, count/0]).

-record(gh_user, {name, role, salt, hash, totp, last_step = -1, failures = 0, locked_until = 0, disabled = false,
                  created}).
-record(gh_session, {token_hash, user, role, created, seen}).

-define(ITERATIONS, 600000).
-define(MIN_PASSWORD, 12).
-define(MAX_FAILURES, 5).
-define(LOCK_MS, 15 * 60 * 1000).
-define(IDLE_MS, 30 * 60 * 1000).
-define(MAX_MS, 12 * 3600 * 1000).

-type role() :: admin | analyst | researcher.
-export_type([role/0]).

-spec roles() -> [role()].
roles() -> [admin, analyst, researcher].

-spec tables() -> ok.
tables() ->
    [case mnesia:create_table(T, Opts) of
         {atomic, ok} -> ok;
         {aborted, {already_exists, T}} -> ok
     end || {T, Opts} <- [{gh_user, [{attributes, record_info(fields, gh_user)}, {disc_copies, [node()]}]},
                           {gh_session, [{attributes, record_info(fields, gh_session)}, {ram_copies, [node()]}]}]],
    ok = mnesia:wait_for_tables([gh_user, gh_session], 60000).

-spec count() -> non_neg_integer().
count() -> mnesia:table_info(gh_user, size).

%% A new user: {ok, TotpSecret}, the secret to show the user once (gh_totp:uri/3), or {error, Why}.
-spec create(binary(), role(), binary()) -> {ok, binary()} | {error, term()}.
create(Name, Role, Password) ->
    Valid = re:run(Name, "^[a-z][a-z0-9._-]{1,31}$", [{capture, none}]) =:= match,
    if
        not Valid -> {error, bad_name};
        byte_size(Password) < ?MIN_PASSWORD -> {error, password_too_short};
        true ->
            case lists:member(Role, roles()) of
                false -> {error, bad_role};
                true ->
                    Salt = crypto:strong_rand_bytes(16),
                    Secret = gh_totp:new_secret(),
                    U = #gh_user{name = Name, role = Role, salt = Salt, hash = pbkdf2(Password, Salt), totp = Secret,
                                 created = erlang:system_time(millisecond)},
                    case mnesia:transaction(fun() ->
                                                    case mnesia:read(gh_user, Name, write) of
                                                        [] -> mnesia:write(U);
                                                        _ -> mnesia:abort(exists)
                                                    end
                                            end) of
                        {atomic, ok} -> {ok, Secret};
                        {aborted, exists} -> {error, exists}
                    end
            end
    end.

-spec users() -> [map()].
users() ->
    [#{name => N, role => R, disabled => D, locked => L > erlang:system_time(millisecond), created => C}
     || #gh_user{name = N, role = R, disabled = D, locked_until = L, created = C} <- mnesia:dirty_match_object(#gh_user{_ = '_'})].

%% disables a user and ends their sessions
-spec disable(binary()) -> ok | {error, no_such_user}.
disable(Name) ->
    {atomic, R} = mnesia:transaction(
                    fun() ->
                            case mnesia:read(gh_user, Name, write) of
                                [U] ->
                                    mnesia:write(U#gh_user{disabled = true}),
                                    [mnesia:delete_object(S) || S <- mnesia:match_object(#gh_session{user = Name, _ = '_'})],
                                    ok;
                                [] -> {error, no_such_user}
                            end
                    end),
    R.

%% {ok, Token, Role} for the right password and code; {error, denied} otherwise (which part was wrong is not said),
%% {error, locked} while the account is locked
-spec login(binary(), binary(), binary()) -> {ok, binary(), role()} | {error, denied | locked}.
login(Name, Password, Code) ->
    Now = erlang:system_time(millisecond),
    case mnesia:dirty_read(gh_user, Name) of
        [] ->
            _ = pbkdf2(Password, <<0:128>>),    % the same work as for a real user, so timing does not tell
            {error, denied};
        [#gh_user{disabled = true}] -> {error, denied};
        [#gh_user{locked_until = L}] when L > Now -> {error, locked};
        [#gh_user{} = U] ->
            PwOk = crypto:hash_equals(pbkdf2(Password, U#gh_user.salt), U#gh_user.hash),
            case PwOk andalso gh_totp:check(U#gh_user.totp, Code, U#gh_user.last_step) of
                {ok, Step} ->
                    Token = binary:encode_hex(crypto:strong_rand_bytes(32), lowercase),
                    {atomic, ok} = mnesia:transaction(
                                     fun() ->
                                             [U2] = mnesia:read(gh_user, Name, write),
                                             mnesia:write(U2#gh_user{last_step = Step, failures = 0}),
                                             mnesia:write(#gh_session{token_hash = th(Token), user = Name,
                                                                      role = U#gh_user.role, created = Now, seen = Now})
                                     end),
                    {ok, Token, U#gh_user.role};
                _ ->
                    {atomic, _} = mnesia:transaction(
                                    fun() ->
                                            [U2] = mnesia:read(gh_user, Name, write),
                                            F = U2#gh_user.failures + 1,
                                            mnesia:write(case F >= ?MAX_FAILURES of
                                                             true -> U2#gh_user{failures = 0, locked_until = Now + ?LOCK_MS};
                                                             false -> U2#gh_user{failures = F}
                                                         end)
                                    end),
                    {error, denied}
            end
    end.

%% the session of a token: {ok, User, Role}, renewing its idle time; error if none or expired
-spec session(binary()) -> {ok, binary(), role()} | error.
session(Token) when is_binary(Token), byte_size(Token) =:= 64 ->
    Now = erlang:system_time(millisecond),
    H = th(Token),
    case mnesia:dirty_read(gh_session, H) of
        [#gh_session{created = C, seen = S} = Sess] when Now - S < ?IDLE_MS, Now - C < ?MAX_MS ->
            ok = mnesia:dirty_write(Sess#gh_session{seen = Now}),
            {ok, Sess#gh_session.user, Sess#gh_session.role};
        [_] -> ok = mnesia:dirty_delete(gh_session, H), error;
        [] -> error
    end;
session(_) -> error.

-spec logout(binary()) -> ok.
logout(Token) when is_binary(Token) -> mnesia:dirty_delete(gh_session, th(Token));
logout(_) -> ok.

th(Token) -> crypto:hash(sha256, Token).

pbkdf2(Password, Salt) -> crypto:pbkdf2_hmac(sha256, Password, Salt, ?ITERATIONS, 32).
