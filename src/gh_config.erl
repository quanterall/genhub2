%% The site's analysis parameters: the reference bundles this node has built (gh_refdb), or the application's
%% {params, Map} setting.
-module(gh_config).
-export([params/0, primers/1]).

%% the bundle of a named primer scheme (gh_refdb:primers/2), or none
-spec primers(binary() | undefined) -> gh_store:hash() | none.
primers(undefined) -> none;
primers(Name) ->
    F = filename:join([application:get_env(genhub2, data_dir, "data"), "bundles", "primers-" ++ binary_to_list(Name)]),
    case file:read_file(F) of
        {ok, H} -> string:trim(H);
        {error, _} -> throw({status, 400, <<"no such primer scheme: ", Name/binary>>})
    end.

-define(NEXTCLADE_TAG, "2026-10-28--15-04-26Z").

-spec params() -> map().
params() ->
    case application:get_env(genhub2, params) of
        {ok, P} -> P;
        undefined ->
            Bundle = fun(Name) ->
                             F = filename:join([application:get_env(genhub2, data_dir, "data"), "bundles", Name]),
                             case file:read_file(F) of
                                 {ok, H} -> string:trim(H);
                                 {error, _} -> undefined
                             end
                     end,
            #{refs => Bundle("refseq_viral"), proteins => Bundle("refseq_viral_proteins"),
              host => case Bundle("hostile") of undefined -> Bundle("host"); H -> H end,
              kraken => Bundle("kraken-k2_viral_20241228"),
              nextclade => case Bundle("nextclade-datasets-v2") of
                               undefined -> Bundle("nextclade-sars-cov-2-" ++ ?NEXTCLADE_TAG);
                               Multi -> Multi
                           end,
              min_depth => 10}
    end.
