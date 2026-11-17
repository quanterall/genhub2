%% The gateway's REST endpoints (gh_web). Every endpoint but login needs a session (gh_accounts), and each allows
%% only some roles (allowed/1). A request that changes anything (POST) must carry the header x-genhub2: 1, which a
%% page of another site cannot send without the browser asking first (protection against cross-site requests; the
%% session cookie is also SameSite=Strict). Logins, data accesses, analyses, refusals and administration go to the
%% audit log (gh_audit).
-module(gh_web_api).
-behaviour(cowboy_handler).
-export([init/2, allowed/1, session_of/1]).

-define(MAX_UPLOAD, 100000000).
-define(COOKIE, <<"gh2_session">>).

init(Req, What) ->
    Method = cowboy_req:method(Req),
    {ok, try
             authorize(What, Method, Req),
             handle(What, Method, Req)
         catch
             throw:{status, S, Msg} -> reply(S, #{error => Msg}, Req);
             Class:Why:Stack ->
                 logger:error("gateway ~p ~s: ~p:~p ~p", [What, Method, Class, Why, Stack]),
                 reply(500, #{error => <<"internal error">>}, Req)
         end, What}.

%% the roles allowed to use an endpoint; login needs no session
-spec allowed(atom()) -> [gh_accounts:role()] | public.
allowed(login) -> public;
allowed(W) when W =:= logout; W =:= me -> [admin, analyst, researcher];
allowed(summary) -> [admin, analyst, researcher];
allowed(W) when W =:= aggregates; W =:= aggregate_alerts -> [admin, analyst, researcher];
allowed(W) when W =:= users; W =:= user_disable; W =:= audit; W =:= audit_verify -> [admin];
allowed(_) -> [admin, analyst].

%% {ok, User, Role} for the request's session cookie, or error
-spec session_of(map()) -> {ok, binary(), gh_accounts:role()} | error.
session_of(Req) ->
    gh_accounts:session(proplists:get_value(?COOKIE, cowboy_req:parse_cookies(Req))).

authorize(What, Method, Req) ->
    Method =:= <<"GET">> orelse cowboy_req:header(<<"x-genhub2">>, Req) =:= <<"1">>
        orelse throw({status, 403, <<"a changing request needs the header x-genhub2: 1">>}),
    case allowed(What) of
        public -> put(gh_actor, <<"anonymous">>);
        Roles ->
            case session_of(Req) of
                {ok, User, Role} ->
                    put(gh_actor, User),
                    put(gh_role, Role),
                    lists:member(Role, Roles) orelse
                        begin
                            audit(denied_request, path(Req), denied, #{method => Method, role => Role}),
                            throw({status, 403, <<"not allowed for your role">>})
                        end;
                error -> throw({status, 401, <<"log in first">>})
            end
    end.

actor() -> get(gh_actor).

audit(Action, Object, Outcome, Detail) -> gh_audit:log(actor(), Action, Object, Outcome, Detail).

path(Req) -> cowboy_req:path(Req).

handle(login, <<"POST">>, Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 10000}),
    {User, Pw, Code} = case catch json:decode(Body) of
                           #{<<"user">> := U, <<"password">> := P, <<"code">> := C}
                             when is_binary(U), is_binary(P), is_binary(C) -> {U, P, C};
                           _ -> throw({status, 400, <<"expected {\"user\", \"password\", \"code\"}">>})
                       end,
    case gh_accounts:login(User, Pw, Code) of
        {ok, Token, Role} ->
            gh_audit:log(User, login, User, ok, #{peer => peer(Req)}),
            Req3 = cowboy_req:set_resp_cookie(?COOKIE, Token, Req2, cookie_opts()),
            reply(200, #{user => User, role => Role}, Req3);
        {error, Why} ->
            gh_audit:log(User, login, User, denied, #{peer => peer(Req), reason => Why}),
            throw({status, 401, case Why of
                                    locked -> <<"account locked for 15 minutes after 5 failed logins">>;
                                    denied -> <<"wrong user, password or code">>
                                end})
    end;
handle(logout, <<"POST">>, Req) ->
    ok = gh_accounts:logout(proplists:get_value(?COOKIE, cowboy_req:parse_cookies(Req))),
    audit(logout, actor(), ok, #{}),
    reply(200, #{}, cowboy_req:set_resp_cookie(?COOKIE, <<>>, Req, (cookie_opts())#{max_age => 0}));
handle(me, <<"GET">>, Req) ->
    reply(200, #{user => actor(), role => get(gh_role)}, Req);
handle(users, <<"GET">>, Req) ->
    reply(200, gh_accounts:users(), Req);
handle(users, <<"POST">>, Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 10000}),
    {Name, Role, Pw} = case catch json:decode(Body) of
                           #{<<"user">> := N, <<"role">> := R, <<"password">> := P} when is_binary(N), is_binary(P) ->
                               {N, case lists:member(R, [<<"admin">>, <<"analyst">>, <<"researcher">>]) of
                                       true -> binary_to_existing_atom(R);
                                       false -> throw({status, 400, <<"role: admin, analyst or researcher">>})
                                   end, P};
                           _ -> throw({status, 400, <<"expected {\"user\", \"role\", \"password\"}">>})
                       end,
    case gh_accounts:create(Name, Role, Pw) of
        {ok, Secret} ->
            audit(user_create, Name, ok, #{role => Role}),
            %% the second factor's secret, shown this once: the new user adds it to an authenticator app
            reply(201, #{user => Name, role => Role, totp_secret => gh_totp:base32(Secret),
                         totp_uri => gh_totp:uri(<<"GenHub2">>, Name, Secret)}, Req2);
        {error, Why} ->
            audit(user_create, Name, failed, #{reason => Why}),
            throw({status, 400, atom_to_binary(Why)})
    end;
handle(user_disable, <<"POST">>, Req) ->
    Name = cowboy_req:binding(name, Req),
    Name =:= actor() andalso throw({status, 400, <<"you cannot disable yourself">>}),
    case gh_accounts:disable(Name) of
        ok -> audit(user_disable, Name, ok, #{}), reply(200, #{user => Name, disabled => true}, Req);
        {error, no_such_user} -> throw({status, 404, <<"no such user">>})
    end;
handle(audit, <<"GET">>, Req) ->
    #{from := From, limit := Limit} = cowboy_req:match_qs([{from, int, 1}, {limit, int, 1000}], Req),
    audit(audit_view, <<>>, ok, #{from => From}),
    reply(200, gh_audit:list(max(1, From), min(max(1, Limit), 10000)), Req);
handle(audit_verify, <<"GET">>, Req) ->
    reply(200, case gh_audit:verify() of
                   {ok, N} -> #{whole => true, records => N};
                   {broken, Seq} -> #{whole => false, broken_at => Seq}
               end, Req);
handle(uploads, <<"POST">>, Req) ->
    {Hash, Bytes, Req2} = gh_store:with_tmp(fun(Dir) ->
                                                    F = filename:join(Dir, "upload"),
                                                    {ok, Fd} = file:open(F, [write, raw, binary]),
                                                    {N, R2} = body_to_file(Req, Fd, 0),
                                                    ok = file:close(Fd),
                                                    {gh_store:move_file(F), N, R2}
                                            end),
    audit(upload, Hash, ok, #{bytes => Bytes}),
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
    Params = (gh_config:params())#{primers => gh_config:primers(maps:get(<<"primers">>, Req0, undefined)),
                                   metadata => metadata(maps:get(<<"metadata">>, Req0, #{}))},
    Id = gh_jobs:submit(Kind, Inputs, Params),
    audit(job_submit, Id, ok, #{kind => Kind, inputs => Inputs}),
    reply(201, #{id => Id}, Req2);
handle(jobs, <<"GET">>, Req) ->
    reply(200, [maps:without([params], J) || J <- gh_jobs:list()], Req);
handle(job, <<"GET">>, Req) ->
    J = view(Req),
    audit(job_view, maps:get(id, J), ok, #{}),
    reply(200, J, Req);
handle(export, <<"GET">>, Req) ->
    J = view(Req),
    Id = maps:get(id, J),
    audit(export, Id, ok, #{export => cowboy_req:binding(export, Req)}),
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
    Usage = <<"expected {\"jobs\": [id, ...], \"method\": \"nj\" | \"fasttree\" | \"veryfasttree\", "
              "\"bootstrap\": 0-1000 (neighbour-joining only)}">>,
    {Ids, Method, Boot} = case catch json:decode(Body) of
                              #{<<"jobs">> := L, <<"method">> := M} = Q
                                when is_list(L), (M =:= <<"nj">> orelse M =:= <<"fasttree">> orelse M =:= <<"veryfasttree">>) ->
                                  case maps:get(<<"bootstrap">>, Q, 0) of
                                      0 -> {L, binary_to_existing_atom(M), 0};
                                      B when is_integer(B), B > 0, B =< 1000, M =:= <<"nj">> -> {L, nj, B};
                                      _ -> throw({status, 400, Usage})
                                  end;
                              _ -> throw({status, 400, Usage})
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
    Params = (gh_config:params())#{reference => Reference, method => Method, bootstrap => Boot, from_jobs => Ids},
    Id = gh_jobs:submit(tree, [Fasta], Params),
    audit(job_submit, Id, ok, #{kind => tree, from_jobs => Ids, method => Method, bootstrap => Boot}),
    reply(201, #{id => Id, reference => Reference}, Req2);
handle(aggregates, <<"GET">>, Req) ->
    {A, NotCounted} = gh_monitor:aggregate(),
    audit(aggregates_export, maps:get(site, A), ok, #{}),
    reply(200, A#{not_counted => NotCounted}, Req);
handle(aggregates, <<"POST">>, Req) ->
    get(gh_role) =:= admin orelse throw({status, 403, <<"only an admin imports another site's aggregates">>}),
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 50000000}),
    case gh_agg:from_json(Body) of
        {ok, A} ->
            case gh_monitor:import(A) of
                ok ->
                    audit(aggregates_import, maps:get(site, A), ok, #{generated => maps:get(generated, A)}),
                    reply(201, #{site => maps:get(site, A)}, Req2);
                {error, own_site} -> throw({status, 400, <<"these are this site's own aggregates">>})
            end;
        {error, _} -> throw({status, 400, <<"not an aggregate (format genhub2-aggregates/1)">>})
    end;
handle(aggregate_alerts, <<"GET">>, Req) ->
    Opts = maps:from_list([{K, V} || {K, V} <- maps:to_list(application:get_env(genhub2, alert_thresholds, #{}))]),
    R = gh_monitor:merged_alerts(Opts),
    audit(aggregate_alerts_view, <<>>, ok, #{alerts => length(maps:get(alerts, R))}),
    reply(200, R, Req);
handle(summary, <<"GET">>, Req) ->
    audit(summary_view, <<>>, ok, #{}),
    reply(200, gh_monitor:summary(), Req);
handle(file, <<"GET">>, Req) ->
    Hash = cowboy_req:binding(hash, Req),
    (byte_size(Hash) =:= 64 andalso gh_store:has(Hash)) orelse throw({status, 404, <<"no such file">>}),
    P = gh_store:path(Hash),
    audit(file_download, Hash, ok, #{}),
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                     {sendfile, 0, filelib:file_size(P), P}, Req);
handle(_, _, _) ->
    throw({status, 405, <<"method not allowed">>}).

%% a job's sample metadata: region (ISO 3166-2) and collection date (ISO, not in the future), for the whole upload
%% and, under "sequences", per sequence; both optional, checked when given
metadata(M) when is_map(M) ->
    One = fun(X) ->
                  maps:from_list(
                    [case K of
                         <<"region">> -> gh_agg:valid_region(V) orelse throw({status, 400, <<"region: ISO 3166-2, e.g. BG-22">>}),
                                         {region, V};
                         <<"collection_date">> -> gh_agg:valid_date(V) orelse
                                                      throw({status, 400, <<"collection_date: an ISO date, not in the future">>}),
                                                  {collection_date, V};
                         _ -> throw({status, 400, <<"metadata: region, collection_date, sequences">>})
                     end || {K, V} <- maps:to_list(X)])
          end,
    Seqs = case maps:get(<<"sequences">>, M, #{}) of
               S when is_map(S) -> maps:map(fun(_, X) when is_map(X) -> One(X);
                                               (_, _) -> throw({status, 400, <<"metadata sequences: name => {...}">>}) end, S);
               _ -> throw({status, 400, <<"metadata sequences: name => {...}">>})
           end,
    (One(maps:without([<<"sequences">>], M)))#{sequences => Seqs};
metadata(_) -> throw({status, 400, <<"metadata: an object">>}).

%% the session cookie: not readable by scripts, never sent with another site's requests; Secure when the gateway is
%% behind TLS (setting {http, #{secure_cookies => true}})
cookie_opts() ->
    Secure = maps:get(secure_cookies, application:get_env(genhub2, http, #{}), false),
    #{http_only => true, same_site => strict, path => <<"/">>, secure => Secure}.

peer(Req) ->
    {Ip, _} = cowboy_req:peer(Req),
    list_to_binary(inet:ntoa(Ip)).

view(Req) ->
    case gh_jobs:view(cowboy_req:binding(id, Req)) of
        undefined -> throw({status, 404, <<"no such job">>});
        J -> J
    end.

%% a tree job's tree, with its branches' bootstrap support when it has replicates
newick(#{kind := tree, state := done, steps := #{support := #{results := [#{newick := H}]}}}) -> H;
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
