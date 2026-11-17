%% The gateway's WebSocket (gh_web): every event of the site, {"topic", "message"}, as it happens.
-module(gh_web_ws).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% only for a session of a role allowed the site's events (gh_web_api:allowed/1)
init(Req, State) ->
    case gh_web_api:session_of(Req) of
        {ok, User, Role} ->
            case lists:member(Role, gh_web_api:allowed(ws)) of
                true ->
                    gh_audit:log(User, events_subscribe, <<>>, ok, #{}),
                    {cowboy_websocket, Req, State, #{idle_timeout => 3600000}};
                false ->
                    gh_audit:log(User, events_subscribe, <<>>, denied, #{role => Role}),
                    {ok, cowboy_req:reply(403, Req), State}
            end;
        error -> {ok, cowboy_req:reply(401, Req), State}
    end.

websocket_init(State) ->
    ok = gh_events:subscribe_all(),
    {[], State}.

websocket_handle(_Frame, State) -> {[], State}.

websocket_info({gh_event, Topic, Msg}, State) ->
    {[{text, gh_json:encode(#{topic => Topic, message => Msg})}], State};
websocket_info(_, State) -> {[], State}.
