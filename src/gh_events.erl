%% Events inside the site (FS 4.3): a topic and a message. Local subscribers (the gateway's WebSockets, tests) join
%% the topic's process group; the MQTT bridge to the site's EMQX broker subscribes the same way.
-module(gh_events).
-export([publish/2, subscribe/1]).

-spec publish(binary(), map()) -> ok.
publish(Topic, Msg) ->
    _ = [P ! {gh_event, Topic, Msg} || P <- pg:get_local_members(gh_events, Topic)],
    ok.

-spec subscribe(binary()) -> ok.
subscribe(Topic) -> pg:join(gh_events, Topic, self()).
