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
    Req0 = case catch json:decode(Body) of M when is_map(M) -> M; _ -> #{} end,
    {Kind, Inputs} = case Req0 of
                         #{<<"kind">> := <<"genome">>, <<"inputs">> := [H]} -> {genome, [H]};
                         #{<<"kind">> := <<"reads">>, <<"inputs">> := [H1, H2]} -> {reads, [H1, H2]};
                         _ -> throw({status, 400, <<"expected {\"kind\": \"genome\", \"inputs\": [hash]} or "
                                                    "{\"kind\": \"reads\", \"inputs\": [hash1, hash2]}">>})
                     end,
    [gh_store:has(H) orelse throw({status, 400, <<"not in the store: ", H/binary>>}) || H <- Inputs],
    Params = (gh_config:params())#{primers => gh_config:primers(maps:get(<<"primers">>, Req0, undefined))},
    reply(201, #{id => gh_jobs:submit(Kind, Inputs, Params)}, Req2);
handle(jobs, <<"GET">>, Req) ->
    reply(200, [maps:without([params], J) || J <- gh_jobs:list()], Req);
handle(job, <<"GET">>, Req) ->
    reply(200, view(Req), Req);
handle(export, <<"GET">>, Req) ->
    J = view(Req),
    Id = maps:get(id, J),
    {Type, Body} = case cowboy_req:binding(export, Req) of
                       <<"report.csv">> -> {<<"text/csv; charset=utf-8">>, gh_export:csv(J)};
                       <<"report.pdf">> -> {<<"application/pdf">>, gh_export:pdf(J)};
                       <<"job.json">> -> {<<"application/json">>, gh_json:encode(J)};
                       <<"tree.svg">> -> {<<"image/svg+xml">>, gh_export:svg(gh_store:read(newick(J)))};
                       <<"tree.nwk">> -> {<<"text/plain; charset=utf-8">>, gh_store:read(newick(J))};
                       _ -> throw({status, 404, <<"exports: report.csv, report.pdf, job.json, tree.svg, tree.nwk">>})
                   end,
    Name = <<Id/binary, "-", (cowboy_req:binding(export, Req))/binary>>,
    cowboy_req:reply(200, #{<<"content-type">> => Type,
                            <<"content-disposition">> => <<"inline; filename=\"", Name/binary, "\"">>}, Body, Req);
handle(trees, <<"POST">>, Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 100000}),
    {Ids, Method} = case catch json:decode(Body) of
                        #{<<"jobs">> := L, <<"method">> := M} when is_list(L), M =:= <<"nj">>; M =:= <<"fasttree">> ->
                            {L, binary_to_existing_atom(M)};
                        _ -> throw({status, 400, <<"expected {\"jobs\": [id, ...], \"method\": \"nj\" | \"fasttree\"}">>})
                    end,
    Views = [case gh_jobs:view(I) of
                 #{state := done, kind := K} = V when K =/= tree -> V;
                 _ -> throw({status, 400, <<"not a finished genome or reads job: ", I/binary>>})
             end || I <- Ids],
    Genomes = [{genome_of(V), [maps:get(ref, R) || R <- gh_export:rows(V)]} || V <- Views],
    Refs = lists:append([Rs || {_, Rs} <- Genomes]),
    length(Refs) >= 2 orelse throw({status, 400, <<"a tree needs at least two sequences">>}),
    Reference = most_common(Refs),
    Fasta = gh_store:put_binary([named(maps:get(id, V), gh_store:read(G)) || {V, {G, _}} <- lists:zip(Views, Genomes)]),
    Params = (gh_config:params())#{reference => Reference, method => Method, from_jobs => Ids},
    reply(201, #{id => gh_jobs:submit(tree, [Fasta], Params), reference => Reference}, Req2);
handle(summary, <<"GET">>, Req) ->
    reply(200, gh_monitor:summary(), Req);
handle(file, <<"GET">>, Req) ->
    Hash = cowboy_req:binding(hash, Req),
    (byte_size(Hash) =:= 64 andalso gh_store:has(Hash)) orelse throw({status, 404, <<"no such file">>}),
    P = gh_store:path(Hash),
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                     {sendfile, 0, filelib:file_size(P), P}, Req);
handle(_, _, _) ->
    throw({status, 405, <<"method not allowed">>}).

view(Req) ->
    case gh_jobs:view(cowboy_req:binding(id, Req)) of
        undefined -> throw({status, 404, <<"no such job">>});
        J -> J
    end.

newick(#{kind := tree, state := done, steps := #{tree := #{results := [#{newick := H}]}}}) -> H;
newick(_) -> throw({status, 404, <<"not a finished tree job">>}).

%% a job's genome file: the validated upload, or the consensus of its reads
genome_of(#{kind := genome, steps := #{validate := #{results := [#{output := H}]}}}) -> H;
genome_of(#{kind := reads, steps := #{consensus := #{results := [#{genome := H}]}}}) -> H.

%% the records of a FASTA file, each named <job>/<its own name>, so trees show where a genome came from
named(Job, Fasta) ->
    binary:replace(<<"\n", Fasta/binary>>, <<"\n>">>, <<"\n>", Job/binary, "/">>, [global]).

most_common(L) ->
    Counts = lists:foldl(fun(X, M) -> maps:update_with(X, fun(C) -> C + 1 end, 1, M) end, #{}, L),
    element(2, lists:max([{N, K} || {K, N} <- maps:to_list(Counts)])).

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
