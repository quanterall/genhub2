%% Task fetch_public (FS 3.2, 3.3): a public record or file (NCBI, ENA) downloaded into the store. Its result is
%% the content's hash, so whatever the server returns later, the analyses that used it name exactly what they used.
%%   {fetch_public, Url} -> #{url, hash, bytes}
-module(gh_fetch).
-behaviour(pq_task).
-export([run/2, describe/1, get/1]).

run({fetch_public, Url}, _Ctx) ->
    gh_store:with_tmp(
      fun(Dir) ->
              F = filename:join(Dir, "download"),
              ok = get_to_file(Url, F),
              Bytes = filelib:file_size(F),
              #{url => Url, hash => gh_store:move_file(F), bytes => Bytes}
      end).

%% the body of a GET, in memory
-spec get(string() | binary()) -> binary().
get(Url) ->
    start(),
    case httpc:request(get, {to_list(Url), []}, http_opts(), [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> Body;
        {ok, {{_, S, _}, _, Body}} -> error({http, S, Url, binary:part(Body, 0, min(500, byte_size(Body)))});
        {error, E} -> error({http, E, Url})
    end.

get_to_file(Url, F) ->
    start(),
    case httpc:request(get, {to_list(Url), []}, http_opts(), [{stream, F}]) of
        {ok, saved_to_file} -> ok;
        {ok, {{_, S, _}, _, _}} -> error({http, S, Url});
        {error, E} -> error({http, E, Url})
    end.

start() ->
    {ok, _} = application:ensure_all_started([inets, ssl]),
    ok.

http_opts() ->
    [{timeout, 3600000}, {connect_timeout, 30000},
     {ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 4},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}].

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.

describe({fetch_public, Url}) -> #{task => fetch_public, url => Url, pure => false}.
