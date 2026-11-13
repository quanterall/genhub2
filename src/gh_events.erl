%% Events inside the site (FS 4.3): a topic and a message. Local subscribers (the gateway's WebSockets, tests) join
%% the topic's process group, or all topics' (subscribe_all/0); the MQTT bridge (gh_mqtt) to the site's EMQX broker
%% subscribes to all of them and publishes them there.
-module(gh_events).
-export([publish/2, subscribe/1, subscribe_all/0]).

-spec publish(binary(), map()) -> ok.
publish(Topic, Msg) ->
    _ = [P ! {gh_event, Topic, Msg} || P <- pg:get_local_members(gh_events, Topic) ++ pg:get_local_members(gh_events, all)],
    ok.

-spec subscribe(binary()) -> ok.
subscribe(Topic) -> pg:join(gh_events, Topic, self()).

-spec subscribe_all() -> ok.
subscribe_all() -> pg:join(gh_events, all, self()).
