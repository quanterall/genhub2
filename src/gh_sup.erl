-module(gh_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => gh_events, start => {pg, start_link, [gh_events]}},
           #{id => gh_jobs, start => {gh_jobs, start_link, []}}]
          ++ [#{id => gh_mqtt, start => {gh_mqtt, start_link, [Conf]}}
              || {ok, Conf} <- [application:get_env(genhub2, mqtt)], is_map(Conf)]}}.
