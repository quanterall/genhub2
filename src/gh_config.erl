%% The site's analysis parameters: the reference bundles this node has built (gh_refdb), or the application's
%% {params, Map} setting.
-module(gh_config).
-export([params/0]).

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
            #{refs => Bundle("refseq_viral"), host => Bundle("host"),
              nextclade => Bundle("nextclade-sars-cov-2-" ++ ?NEXTCLADE_TAG), min_depth => 10}
    end.
