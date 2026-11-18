%% The structure viewer (the TechUPGRADE Digital Twin Platform's mutation view), opened from GenHub2's results: a
%% genome's amino-acid changes (Nextclade's, gh_lineage) shown along the genome and on 3D protein structures. GenHub2
%% hands over a signed, short-lived link; the viewer checks it and shows the changes. Information, not diagnosis.
%%
%% Setting {structure_viewer, #{url := "https://viewer.example/genhub2/open", secret_file := Path,
%%                              viruses := [<<"Betacoronavirus pandemicum">>, ...]}}; undefined: off.
%% The secret (32 bytes or more) is shared with the viewer's operator and kept outside the repository.
%%
%% The link: <url>?d=<payload>&s=<signature>
%%   payload    base64url (no padding) of JSON {"v": 1, "issuer": site, "ref": an opaque reference, "virus",
%%              "dataset" (Nextclade's), "lineage", "clade", "mutations": ["S:N501Y", "S:H69-", ...],
%%              "issued", "expires" (Unix ms; 10 minutes later)}
%%   signature  base64url (no padding) of HMAC-SHA256(secret, the payload's base64url text)
%% No sample, job or user names travel: the reference ties a link to its job only in GenHub2's audit log. verify/3 is
%% the check the viewer makes (a reference implementation for it).
-module(gh_viewer).
-export([config/0, link/3, verify/3]).

-define(TTL_MS, 600000).

%% #{enabled, viruses}
-spec config() -> map().
config() ->
    case application:get_env(genhub2, structure_viewer) of
        {ok, #{url := _, secret_file := _, viruses := V}} -> #{enabled => true, viruses => V};
        _ -> #{enabled => false, viruses => []}
    end.

%% A link for one genome (Query) of a finished job: {ok, #{url, ref, expires, mutations}} or {error, Why}
-spec link(map(), binary(), binary()) -> {ok, map()} | {error, binary()}.
link(#{steps := Steps} = Job, Query, Site) ->
    case application:get_env(genhub2, structure_viewer) of
        {ok, #{url := Url, secret_file := F, viruses := Viruses}} ->
            Species = case [S || #{query := Q, species := S} <- gh_export:rows(Job), Q =:= Query] of
                          [S | _] -> S;
                          [] -> <<>>
                      end,
            Lin = [L || L <- results(Steps, lineage), maps:get(query, L) =:= Query],
            case {lists:member(Species, Viruses), Lin} of
                {false, _} -> {error, <<"the viewer does not show this virus">>};
                {true, []} -> {error, <<"no lineage result for this genome (Nextclade)">>};
                {true, [L | _]} ->
                    Muts = maps:get(aa_substitutions, L, []) ++ maps:get(aa_deletions, L, []),
                    Now = erlang:system_time(millisecond),
                    Ref = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
                    P = b64(json:encode(#{v => 1, issuer => Site, ref => Ref, virus => Species,
                                          dataset => maps:get(dataset, L, <<>>), lineage => maps:get(pango, L, <<>>),
                                          clade => maps:get(clade, L, <<>>), mutations => Muts, issued => Now,
                                          expires => Now + ?TTL_MS})),
                    Sig = b64(crypto:mac(hmac, sha256, secret(F), P)),
                    {ok, #{url => iolist_to_binary([Url, "?d=", P, "&s=", Sig]), ref => Ref, expires => Now + ?TTL_MS,
                           mutations => Muts}}
            end;
        _ -> {error, <<"no structure viewer configured">>}
    end.

%% The viewer's check of a link: {ok, Payload} when the signature is right and the link has not expired;
%% {error, bad_signature | expired | malformed}
-spec verify(binary(), binary(), binary()) -> {ok, map()} | {error, atom()}.
verify(P, Sig, Secret) ->
    try
        Want = b64(crypto:mac(hmac, sha256, Secret, P)),
        case byte_size(Want) =:= byte_size(Sig) andalso crypto:hash_equals(Want, Sig) of
            false -> {error, bad_signature};
            true ->
                M = json:decode(base64:decode(P, #{mode => urlsafe, padding => false})),
                case maps:get(<<"expires">>, M) > erlang:system_time(millisecond) of
                    true -> {ok, M};
                    false -> {error, expired}
                end
        end
    catch _:_ -> {error, malformed}
    end.

b64(B) -> base64:encode(iolist_to_binary(B), #{mode => urlsafe, padding => false}).

secret(F) ->
    {ok, S} = file:read_file(F),
    T = string:trim(S),
    byte_size(T) >= 32 orelse error(structure_viewer_secret_too_short),
    T.

results(Steps, Step) ->
    case Steps of
        #{Step := #{results := R}} -> lists:append([X || X <- R, is_list(X)]);
        _ -> []
    end.
