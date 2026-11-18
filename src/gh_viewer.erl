%% The structure viewer: the TechUPGRADE Digital Twin Platform's view genhub2.structures, opened from GenHub2's results
%% through TechUPGRADE's external integration protocol, version 1 ("TechUPGRADE as an engine in someone else's
%% workflow", 18 November 2026; the EXT-nn requirements cited below are its). A genome's amino-acid changes (Nextclade's,
%% gh_lineage) are drawn on the virus's proteins. Information for experts, not a diagnosis.
%%
%% Setting {structure_viewer, #{base := "https://twin.example.org", mode := push | direct, iss := <<"lab17.example.org">>,
%%                              active := Kid, keys := #{Kid => #{alg := 'Ed25519' | 'HS256', key_file := Path}},
%%                              datasets => [<<"sars-cov-2">>, <<"rsv-a">>, <<"rsv-b">>],
%%                              client_cert => Path, client_key => Path}}; undefined: off.
%%   Ed25519 (EXT-08, preferred): key_file holds the private key (gh_cli viewer_key makes it); TechUPGRADE holds only
%%   the public key. HS256 (EXT-09): key_file holds the shared secret, for a test site. Two keys may be listed during a
%%   rotation (EXT-03); links are signed with the active one. datasets: the viewer's datasets this site opens (all
%%   three by default). client_cert/client_key: mutual TLS for push (EXT-29).
%%
%% The payload (EXT-13..20), exactly these fields:
%%   {"v": 1, "alg", "kid", "iss", "aud": the entry point's full URL, "jti": unique per link, "iat", "exp" (Unix ms,
%%    10 minutes apart), "view": "genhub2.structures", "ref": opaque (logged by GenHub2 with its job, never a name),
%%    "params": {"dataset": "sars-cov-2" | "rsv-a" | "rsv-b", "mutations": ["S:N501Y", ...], "lineage", "clade"}}
%% sent as base64url (no padding) text P with signature S over exactly that text (EXT-10), and the kid outside the
%% payload as well (EXT-14), so the key is chosen before any of the payload is read:
%%   push mode (EXT-21, the default): POST {"kid": Kid, "d": P, "s": S} to <base>/ext/push over TLS, verified against
%%     the public CAs; the reply {"handle", "expires"} opens <base>/ext/open?h=<handle>; a refusal is 400
%%     {"error": "refused"}, its reason only in TechUPGRADE's log (EXT-35). aud is <base>/ext/push.
%%   direct mode (EXT-22): <base>/ext/open?k=Kid&d=P&s=S. aud is <base>/ext/open.
%% verify/3 is a reference verifier of TechUPGRADE's checks, for GenHub2's own tests and the joint test.
-module(gh_viewer).
-export([config/0, link/3, payload/4, sign/3, verify/4, new_key/0, public_key/1, dataset/2]).

-define(TTL_MS, 600000).
-define(SKEW_MS, 60000).
-define(VIEW, <<"genhub2.structures">>).
-define(FIELDS, [<<"v">>, <<"alg">>, <<"kid">>, <<"iss">>, <<"aud">>, <<"jti">>, <<"iat">>, <<"exp">>, <<"view">>,
                 <<"ref">>, <<"params">>]).
-define(MAX_PAYLOAD, 16384).
-define(DATASETS, [<<"sars-cov-2">>, <<"rsv-a">>, <<"rsv-b">>]).

%% #{enabled, viruses}: what the page needs to know
-spec config() -> map().
config() ->
    case application:get_env(genhub2, structure_viewer) of
        {ok, #{base := _, iss := _, active := _, keys := _}} ->
            #{enabled => true, viruses => [<<"Betacoronavirus pandemicum">>, <<"Orthopneumovirus hominis">>]};
        _ -> #{enabled => false, viruses => []}
    end.

%% the viewer's dataset for a genome, from its species and Nextclade's dataset: sars-cov-2, rsv-a, rsv-b, or none
%% (other viruses are not in the viewer yet)
-spec dataset(binary(), binary()) -> binary() | none.
dataset(<<"Betacoronavirus pandemicum">>, _) -> <<"sars-cov-2">>;
dataset(<<"Orthopneumovirus hominis">>, Nextclade) ->
    L = string:lowercase(Nextclade),
    case {binary:match(L, [<<"rsv/a">>, <<"rsv_a">>, <<"rsv-a">>]), binary:match(L, [<<"rsv/b">>, <<"rsv_b">>, <<"rsv-b">>])} of
        {{_, _}, nomatch} -> <<"rsv-a">>;
        {nomatch, {_, _}} -> <<"rsv-b">>;
        _ -> none
    end;
dataset(_, _) -> none.

%% A link for one genome (Query) of a finished job: {ok, #{url, ref, jti, expires, mutations}} or {error, Why}
-spec link(map(), binary(), binary()) -> {ok, map()} | {error, binary()}.
link(#{steps := Steps} = Job, Query, _Site) ->
    case application:get_env(genhub2, structure_viewer) of
        {ok, #{base := Base, iss := Iss, active := Kid, keys := Keys} = C} ->
            Mode = maps:get(mode, C, push),
            Species = case [S || #{query := Q, species := S} <- gh_export:rows(Job), Q =:= Query] of
                          [S | _] -> S;
                          [] -> <<>>
                      end,
            case [L || L <- results(Steps, lineage), maps:get(query, L) =:= Query] of
                [] -> {error, <<"no lineage result for this genome (Nextclade)">>};
                [L | _] ->
                    Ds = dataset(Species, maps:get(dataset, L, <<>>)),
                    case lists:member(Ds, maps:get(datasets, C, ?DATASETS)) of
                        false -> {error, <<"the viewer does not show this virus here (SARS-CoV-2, RSV-A and RSV-B)">>};
                        true ->
                            Muts = maps:get(aa_substitutions, L, []) ++ maps:get(aa_deletions, L, []),
                            Aud = iolist_to_binary([Base, case Mode of push -> "/ext/push"; direct -> "/ext/open" end]),
                            #{alg := Alg} = Key = maps:get(Kid, Keys),
                            Now = erlang:system_time(millisecond),
                            Ref = <<"r-", (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
                            P = payload(#{alg => Alg, kid => Kid, iss => Iss, aud => Aud, ref => Ref, now => Now},
                                        Ds, Muts, L),
                            Sig = sign(P, Alg, read_key(Key)),
                            #{<<"jti">> := Jti} = json:decode(base64:decode(P, #{mode => urlsafe, padding => false})),
                            case open(Mode, Base, Kid, P, Sig, C) of
                                {ok, Url} -> {ok, #{url => Url, ref => Ref, jti => Jti, expires => Now + ?TTL_MS,
                                                    mutations => Muts}};
                                {error, _} = E -> E
                            end
                    end
            end;
        _ -> {error, <<"no structure viewer configured">>}
    end.

%% the payload's base64url text: exactly the protocol's fields (EXT-20); the virus data under params
-spec payload(map(), binary(), [binary()], map()) -> binary().
payload(#{alg := Alg, kid := Kid, iss := Iss, aud := Aud, ref := Ref, now := Now}, Dataset, Muts, Lineage) ->
    b64(json:encode(#{<<"v">> => 1, <<"alg">> => alg_name(Alg), <<"kid">> => Kid, <<"iss">> => Iss, <<"aud">> => Aud,
                      <<"jti">> => binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
                      <<"iat">> => Now, <<"exp">> => Now + ?TTL_MS, <<"view">> => ?VIEW, <<"ref">> => Ref,
                      <<"params">> => #{<<"dataset">> => Dataset, <<"mutations">> => Muts,
                                        <<"lineage">> => maps:get(pango, Lineage, <<>>),
                                        <<"clade">> => maps:get(clade, Lineage, <<>>)}})).

%% the signature over the payload's exact text (EXT-10), base64url
-spec sign(binary(), 'Ed25519' | 'HS256', binary()) -> binary().
sign(P, 'Ed25519', Priv) -> b64(crypto:sign(eddsa, none, P, [Priv, ed25519]));
sign(P, 'HS256', Secret) -> b64(crypto:mac(hmac, sha256, Secret, P)).

%% push mode: the payload to <base>/ext/push over TLS (public CAs; mutual TLS when configured), the handle back
open(direct, Base, Kid, P, S, _C) ->
    {ok, iolist_to_binary([Base, "/ext/open?k=", uri_string:quote(Kid), "&d=", P, "&s=", S])};
open(push, Base, Kid, P, S, C) ->
    case uri_string:parse(Base) of
        #{scheme := "https"} -> ok;
        _ -> error(structure_viewer_base_must_be_https)                 % EXT-27: never plain HTTP
    end,
    Tls = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {versions, ['tlsv1.3', 'tlsv1.2']},
           {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
        ++ case C of
               #{client_cert := Cert, client_key := K} -> [{certfile, Cert}, {keyfile, K}];
               _ -> []
           end,
    _ = application:ensure_all_started([inets, ssl]),
    case httpc:request(post, {Base ++ "/ext/push", [], "application/json", json:encode(#{kid => Kid, d => P, s => S})},
                       [{ssl, Tls}, {timeout, 10000}, {connect_timeout, 5000}, {autoredirect, false}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case catch json:decode(Body) of
                #{<<"handle">> := H} when is_binary(H) -> {ok, iolist_to_binary([Base, "/ext/open?h=", uri_string:quote(H)])};
                _ -> {error, <<"the viewer did not return a handle">>}
            end;
        {ok, {{_, Code, _}, _, _}} -> {error, iolist_to_binary(io_lib:format("the viewer refused the hand-off (~b)", [Code]))};
        {error, _} -> {error, <<"the viewer could not be reached">>}
    end.

%% A reference verifier of the protocol's checks (EXT-10..20, 41, 43, 44), as TechUPGRADE's entry point makes them:
%% Kid: the kid sent outside the payload, which only chooses the key (EXT-14); Keys: #{Kid => {Alg, PublicKeyOrSecret}};
%% Opts: #{aud := Url, seen => fun(Jti) -> boolean()}. {ok, Payload} | {error, Reason}
-spec verify(binary(), binary(), binary(), map()) -> {ok, map()} | {error, atom()}.
verify(Kid, P, S, #{keys := Keys, aud := Aud} = Opts) ->
    try
        byte_size(P) =< ?MAX_PAYLOAD orelse throw(oversized),
        %% nothing in the payload is read until the signature holds (EXT-12)
        {Alg, Key} = case maps:get(Kid, Keys, none) of none -> throw(unknown_kid); AK -> AK end,
        Text = base64:decode(P, #{mode => urlsafe, padding => false}),
        Sig = base64:decode(S, #{mode => urlsafe, padding => false}),
        Good = case Alg of
                   'Ed25519' -> crypto:verify(eddsa, none, P, Sig, [Key, ed25519]);
                   'HS256' -> W = crypto:mac(hmac, sha256, Key, P),
                              byte_size(W) =:= byte_size(Sig) andalso crypto:hash_equals(W, Sig)
               end,
        Good orelse throw(bad_signature),
        M = json:decode(Text),
        lists:sort(maps:keys(M)) =:= lists:sort(?FIELDS) orelse throw(unknown_or_missing_field),
        maps:get(<<"kid">>, M) =:= Kid orelse throw(kid_mismatch),
        maps:get(<<"v">>, M) =:= 1 orelse throw(unknown_version),
        maps:get(<<"alg">>, M) =:= alg_name(Alg) orelse throw(wrong_alg),
        maps:get(<<"aud">>, M) =:= Aud orelse throw(wrong_aud),
        Now = erlang:system_time(millisecond),
        #{<<"iat">> := Iat, <<"exp">> := Exp} = M,
        (is_integer(Iat) andalso is_integer(Exp)) orelse throw(malformed),
        Iat =< Now + ?SKEW_MS orelse throw(issued_in_the_future),
        Exp > Now orelse throw(expired),
        Exp - Iat =< ?TTL_MS orelse throw(lifetime_over_the_cap),
        Seen = maps:get(seen, Opts, fun(_) -> false end),
        not Seen(maps:get(<<"jti">>, M)) orelse throw(replayed),
        maps:get(<<"view">>, M) =:= ?VIEW orelse throw(unregistered_view),
        case maps:get(<<"params">>, M) of
            #{<<"dataset">> := D, <<"mutations">> := Ms} = Pa when is_list(Ms) ->
                lists:member(D, ?DATASETS) orelse throw(unknown_dataset),
                maps:keys(maps:without([<<"dataset">>, <<"mutations">>, <<"lineage">>, <<"clade">>, <<"protein">>,
                                        <<"segment">>], Pa)) =:= [] orelse throw(unknown_parameter),
                lists:all(fun is_binary/1, Ms) orelse throw(malformed);
            _ -> throw(bad_params)
        end,
        {ok, M}
    catch
        throw:Why -> {error, Why};
        _:_ -> {error, malformed}
    end.

%% a new Ed25519 key pair: {Public, Private}, raw 32-byte keys
-spec new_key() -> {binary(), binary()}.
new_key() -> crypto:generate_key(eddsa, ed25519).

%% the public key of an Ed25519 private key file, base64url: what TechUPGRADE registers for a kid
-spec public_key(file:filename()) -> binary().
public_key(File) ->
    {Pub, _} = crypto:generate_key(eddsa, ed25519, read_key(#{alg => 'Ed25519', key_file => File})),
    b64(Pub).

alg_name('Ed25519') -> <<"Ed25519">>;
alg_name('HS256') -> <<"HS256">>.

%% Ed25519: the 32-byte private key, base64url in the file; HS256: the secret's text (32 bytes or more)
read_key(#{alg := Alg, key_file := F}) ->
    {ok, B} = file:read_file(F),
    T = string:trim(B),
    case Alg of
        'Ed25519' -> K = base64:decode(T, #{mode => urlsafe, padding => false}), 32 = byte_size(K), K;
        'HS256' -> byte_size(T) >= 32 orelse error(structure_viewer_secret_too_short), T
    end.

b64(B) -> base64:encode(iolist_to_binary(B), #{mode => urlsafe, padding => false}).

results(Steps, Step) ->
    case Steps of
        #{Step := #{results := R}} -> lists:append([X || X <- R, is_list(X)]);
        _ -> []
    end.
