%% The gateway's REST endpoints (gh_web).
-module(gh_web_api).
-behaviour(cowboy_handler).
-export([init/2]).

-define(MAX_UPLOAD, 100000000).

init(Req, What) ->
    Method = cowboy_req:method(Req),
    {ok, try handle(What, Method, Req)
         catch
             throw:{status, S, Msg} -> reply(S, #{error => Msg}, Req);
             Class:Why:Stack ->
                 logger:error("gateway ~p ~s: ~p:~p ~p", [What, Method, Class, Why, Stack]),
                 reply(500, #{error => <<"internal error">>}, Req)
         end, What}.

handle(uploads, <<"POST">>, Req) ->
    {Hash, Bytes, Req2} = gh_store:with_tmp(fun(Dir) ->
                                                    F = filename:join(Dir, "upload"),
                                                    {ok, Fd} = file:open(F, [write, raw, binary]),
                                                    {N, R2} = body_to_file(Req, Fd, 0),
                                                    ok = file:close(Fd),
                                                    {gh_store:move_file(F), N, R2}
                                            end),
    reply(201, #{hash => Hash, bytes => Bytes}, Req2);
handle(jobs, <<"POST">>, Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 100000}),
    {Kind, Inputs} = case catch json:decode(Body) of
                         #{<<"kind">> := <<"genome">>, <<"inputs">> := [H]} -> {genome, [H]};
                         #{<<"kind">> := <<"reads">>, <<"inputs">> := [H1, H2]} -> {reads, [H1, H2]};
                         _ -> throw({status, 400, <<"expected {\"kind\": \"genome\", \"inputs\": [hash]} or "
                                                    "{\"kind\": \"reads\", \"inputs\": [hash1, hash2]}">>})
                     end,
    [gh_store:has(H) orelse throw({status, 400, <<"not in the store: ", H/binary>>}) || H <- Inputs],
    reply(201, #{id => gh_jobs:submit(Kind, Inputs, gh_config:params())}, Req2);
handle(jobs, <<"GET">>, Req) ->
    reply(200, [maps:without([params], J) || J <- gh_jobs:list()], Req);
handle(job, <<"GET">>, Req) ->
    Id = cowboy_req:binding(id, Req),
    case gh_jobs:get(Id) of
        undefined -> throw({status, 404, <<"no such job">>});
        J ->
            Steps = maps:map(fun(_, {Results, Secs}) ->
                                     #{seconds => Secs, results => [R || {R, _} <- Results],
                                       provenance => [P || {_, P} <- Results]}
                             end, gh_jobs:steps(Id)),
            reply(200, J#{steps => Steps, order => gh_pipeline:steps(maps:get(kind, J))}, Req)
    end;
handle(file, <<"GET">>, Req) ->
    Hash = cowboy_req:binding(hash, Req),
    (byte_size(Hash) =:= 64 andalso gh_store:has(Hash)) orelse throw({status, 404, <<"no such file">>}),
    P = gh_store:path(Hash),
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                     {sendfile, 0, filelib:file_size(P), P}, Req);
handle(_, _, _) ->
    throw({status, 405, <<"method not allowed">>}).

body_to_file(Req, Fd, N) ->
    {More, Data, Req2} = case cowboy_req:read_body(Req, #{length => 8000000, period => 60000}) of
                             {ok, D, R} -> {false, D, R};
                             {more, D, R} -> {true, D, R}
                         end,
    N2 = N + byte_size(Data),
    N2 =< ?MAX_UPLOAD orelse throw({status, 413, <<"uploads are limited to 100 MB">>}),
    ok = file:write(Fd, Data),
    case More of
        true -> body_to_file(Req2, Fd, N2);
        false -> {N2, Req2}
    end.

reply(Status, Term, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, gh_json:encode(Term), Req).
