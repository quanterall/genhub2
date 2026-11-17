%% The site's audit log (FS 3.4: every action, sharing event, alert and data access is logged). Append-only, in Mnesia
%% (disc copies, this site only). Each record carries the SHA-256 of the record before it, so a record changed or
%% removed afterwards breaks the chain, and verify/0 finds where.
%%
%%   {gh_audit, Seq, Time, Actor, Action, Object, Outcome, Detail, Prev, Hash}
%%     Seq      1, 2, ...
%%     Time     Unix time, milliseconds
%%     Actor    the user (binary), or a system actor: <<"system">>, <<"mqtt">>
%%     Action   e.g. login, job_submit, job_view, export, file_download, user_create
%%     Object   what it concerns (a job id, a file hash, a user), or <<>>
%%     Outcome  ok | denied | failed
%%     Detail   a map (never a password, a code or a token)
%%     Prev     the previous record's Hash (64 zeros for the first)
%%     Hash     SHA-256 of the record's fields and Prev
-module(gh_audit).
-behaviour(gen_server).
-export([start_link/0, tables/0, log/5, log/4, list/2, verify/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(gh_audit, {seq, time, actor, action, object, outcome, detail, prev, hash}).

-define(ZERO, <<"0000000000000000000000000000000000000000000000000000000000000000">>).

-spec tables() -> ok.
tables() ->
    case mnesia:create_table(gh_audit, [{attributes, record_info(fields, gh_audit)}, {disc_copies, [node()]},
                                        {type, ordered_set}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, gh_audit}} -> ok
    end,
    ok = mnesia:wait_for_tables([gh_audit], 60000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec log(binary(), atom(), binary(), ok | denied | failed, map()) -> ok.
log(Actor, Action, Object, Outcome, Detail) ->
    gen_server:call(?MODULE, {log, Actor, Action, Object, Outcome, Detail}).

-spec log(binary(), atom(), binary(), ok | denied | failed) -> ok.
log(Actor, Action, Object, Outcome) -> log(Actor, Action, Object, Outcome, #{}).

%% the records from sequence number From on, at most Limit, oldest first
-spec list(pos_integer(), pos_integer()) -> [map()].
list(From, Limit) ->
    Recs = mnesia:dirty_select(gh_audit, [{#gh_audit{seq = '$1', _ = '_'}, [{'>=', '$1', From}], ['$_']}]),
    [to_map(R) || R <- lists:sublist(lists:keysort(#gh_audit.seq, Recs), Limit)].

%% ok, with the number of records, if the chain is whole; {broken, Seq} at the first record that does not match
-spec verify() -> {ok, non_neg_integer()} | {broken, pos_integer()}.
verify() ->
    Recs = lists:keysort(#gh_audit.seq, mnesia:dirty_match_object(#gh_audit{_ = '_'})),
    verify(Recs, ?ZERO, 1).

verify([], _, N) -> {ok, N - 1};
verify([#gh_audit{seq = N, prev = Prev, hash = H} = R | Rest], Prev, N) ->
    case hash(R) of
        H -> verify(Rest, H, N + 1);
        _ -> {broken, N}
    end;
verify([#gh_audit{seq = S} | _], _, _) -> {broken, S}.

hash(#gh_audit{seq = S, time = T, actor = A, action = Ac, object = O, outcome = Out, detail = D, prev = P}) ->
    binary:encode_hex(crypto:hash(sha256, term_to_binary({S, T, A, Ac, O, Out, D, P}, [deterministic])), lowercase).

to_map(#gh_audit{seq = S, time = T, actor = A, action = Ac, object = O, outcome = Out, detail = D, hash = H}) ->
    #{seq => S, time => T, actor => A, action => Ac, object => O, outcome => Out, detail => D, hash => H}.

%%% server: the last record's sequence number and hash, so each record is appended in order

init([]) ->
    case mnesia:dirty_last(gh_audit) of
        '$end_of_table' -> {ok, {0, ?ZERO}};
        Last -> [#gh_audit{hash = H}] = mnesia:dirty_read(gh_audit, Last), {ok, {Last, H}}
    end.

handle_call({log, Actor, Action, Object, Outcome, Detail}, _From, {Seq, Prev}) ->
    R0 = #gh_audit{seq = Seq + 1, time = erlang:system_time(millisecond), actor = Actor, action = Action,
                   object = Object, outcome = Outcome, detail = Detail, prev = Prev},
    R = R0#gh_audit{hash = hash(R0)},
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(R) end),
    {reply, ok, {Seq + 1, R#gh_audit.hash}}.

handle_cast(_, S) -> {noreply, S}.
