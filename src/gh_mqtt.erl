%% The bridge to the site's MQTT broker (FS 4.3: EMQX 5.8.9, one per site, never exposed outside it). Every event of
%% the site (gh_events) is published on its topic, QoS 1, as JSON. Messages on genhub/sequences/new from other
%% publishers (a sequencer's integration, another service of the site) start jobs:
%%   {"kind": "genome" | "reads", "inputs": [hash, ...]}   the files already in the site's store
%% The bridge subscribes with MQTT 5's no-local option, so it does not receive what it publishes itself. While the
%% broker is down, events are dropped and the bridge reconnects every 5 s: the job table in Mnesia, not the broker,
%% is where work is kept (FS 4.3).
-module(gh_mqtt).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(map()) -> {ok, pid()}.
start_link(Conf) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Conf, []).

init(Conf) ->
    process_flag(trap_exit, true),
    ok = gh_events:subscribe_all(),
    self() ! connect,
    {ok, #{conf => Conf, client => undefined}}.

handle_call(_, _From, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(connect, #{conf := Conf} = S) ->
    Opts = [{host, maps:get(host, Conf, "127.0.0.1")}, {port, maps:get(port, Conf, 1883)},
            {clientid, iolist_to_binary(["genhub2-", atom_to_list(node())])}, {proto_ver, v5}, {clean_start, false},
            {properties, #{'Session-Expiry-Interval' => 3600}}],
    case emqtt:start_link(Opts) of
        {ok, C} ->
            case emqtt:connect(C) of
                {ok, _} ->
                    {ok, _, _} = emqtt:subscribe(C, #{}, [{<<"genhub/sequences/new">>, [{qos, 1}, {nl, true}]}]),
                    logger:notice("gh_mqtt: connected to ~p", [Conf]),
                    {noreply, S#{client => C}};
                {error, E} ->
                    logger:warning("gh_mqtt: cannot connect to ~p: ~p", [Conf, E]),
                    catch emqtt:stop(C),
                    retry(S)
            end;
        {error, E} -> logger:warning("gh_mqtt: ~p", [E]), retry(S)
    end;
handle_info({gh_event, Topic, Msg}, #{client := C} = S) when C =/= undefined ->
    _ = emqtt:publish(C, Topic, gh_json:encode(Msg), [{qos, 1}]),
    {noreply, S};
handle_info({gh_event, _, _}, S) -> {noreply, S};
handle_info({publish, #{topic := <<"genhub/sequences/new">>, payload := P}}, S) ->
    case catch json:decode(P) of
        #{<<"kind">> := K, <<"inputs">> := Inputs} when K =:= <<"genome">>; K =:= <<"reads">> ->
            case lists:all(fun gh_store:has/1, Inputs) of
                true -> _ = gh_jobs:submit(binary_to_existing_atom(K), Inputs, gh_config:params()), ok;
                false -> logger:warning("gh_mqtt: inputs not in the store: ~p", [Inputs])
            end;
        #{<<"job">> := _} -> ok;                                % a job announced by another node of the site
        Other -> logger:warning("gh_mqtt: not a job request: ~p", [Other])
    end,
    {noreply, S};
handle_info({'EXIT', C, Why}, #{client := C} = S) ->
    logger:warning("gh_mqtt: connection lost: ~p", [Why]),
    retry(S#{client => undefined});
handle_info(_, S) -> {noreply, S}.

retry(S) ->
    erlang:send_after(5000, self(), connect),
    {noreply, S#{client => undefined}}.
