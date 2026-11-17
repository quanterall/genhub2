%% Time-based one-time passwords, the second factor of a login (FS 3.1, 3.4: multi-factor authentication): TOTP,
%% RFC 6238 (doi:10.17487/RFC6238), over HOTP, RFC 4226 (doi:10.17487/RFC4226), with HMAC-SHA1, 30-second steps and
%% 6 digits, the parameters every authenticator app uses. Secrets are 20 random bytes, shown to the user once in
%% base32 (RFC 4648) and as an otpauth:// URI.
-module(gh_totp).
-export([new_secret/0, code/2, step/1, check/3, base32/1, unbase32/1, uri/3]).

-define(STEP, 30).
-define(DIGITS, 6).

-spec new_secret() -> binary().
new_secret() -> crypto:strong_rand_bytes(20).

%% the code for Secret at time step Step
-spec code(binary(), non_neg_integer()) -> binary().
code(Secret, Step) -> hotp(Secret, Step, ?DIGITS).

hotp(Secret, Counter, Digits) ->
    Mac = crypto:mac(hmac, sha, Secret, <<Counter:64>>),
    Offset = binary:last(Mac) band 16#0f,
    <<_:Offset/binary, P:32, _/binary>> = Mac,
    N = (P band 16#7fffffff) rem pow10(Digits),
    iolist_to_binary(io_lib:format("~*..0B", [Digits, N])).

pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

%% the time step of a Unix time in seconds
-spec step(integer()) -> non_neg_integer().
step(Unix) -> Unix div ?STEP.

%% {ok, Step} if Code is Secret's code for the current step or one step either side (clock drift), and that step is
%% later than LastUsed (a code is accepted once); error otherwise
-spec check(binary(), binary(), integer()) -> {ok, non_neg_integer()} | error.
check(Secret, Code, LastUsed) ->
    Now = step(erlang:system_time(second)),
    case [S || S <- [Now - 1, Now, Now + 1], S > LastUsed, crypto:hash_equals(code(Secret, S), pad(Code))] of
        [S | _] -> {ok, S};
        [] -> error
    end.

%% a code of another length is never equal; hash_equals needs equal sizes
pad(Code) when byte_size(Code) =:= ?DIGITS -> Code;
pad(_) -> <<"xxxxxx">>.

-spec base32(binary()) -> binary().
base32(Bin) -> << <<(lists:nth(X + 1, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"))>> || <<X:5>> <= pad5(Bin) >>.

pad5(Bin) ->
    Pad = (5 - byte_size(Bin) rem 5) rem 5,
    case Pad of
        0 -> Bin;
        _ -> binary:part(<<Bin/binary, 0:(Pad * 8)>>, 0, byte_size(Bin) + Pad)
    end.

-spec unbase32(binary()) -> binary().
unbase32(B32) ->
    Bits = << <<(index(C)):5>> || <<C>> <= string:uppercase(B32), C =/= $= >>,
    N = bit_size(Bits) div 8,
    <<Out:N/binary, _/bitstring>> = Bits,
    Out.

index(C) when C >= $A, C =< $Z -> C - $A;
index(C) when C >= $2, C =< $7 -> C - $2 + 26.

%% the otpauth:// URI an authenticator app reads (as text, or from a QR code made of it)
-spec uri(binary(), binary(), binary()) -> binary().
uri(Issuer, Account, Secret) ->
    E = fun(S) -> uri_string:quote(S) end,
    iolist_to_binary(["otpauth://totp/", E(Issuer), ":", E(Account), "?secret=", base32(Secret), "&issuer=", E(Issuer),
                      "&algorithm=SHA1&digits=6&period=30"]).
