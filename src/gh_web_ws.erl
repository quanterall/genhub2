%% The gateway's WebSocket (gh_web): every event of the site, {"topic", "message"}, as it happens.
-module(gh_web_ws).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(Req, State) -> {cowboy_websocket, Req, State, #{idle_timeout => 3600000}}.

websocket_init(State) ->
    ok = gh_events:subscribe_all(),
    {[], State}.

websocket_handle(_Frame, State) -> {[], State}.

websocket_info({gh_event, Topic, Msg}, State) ->
    {[{text, gh_json:encode(#{topic => Topic, message => Msg})}], State};
websocket_info(_, State) -> {[], State}.
