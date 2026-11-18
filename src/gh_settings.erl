%% The site's settings that its admins change while it runs (FS 3.1: alert thresholds and notification settings),
%% kept in Mnesia (disc copies, this site only); every change is audited by the gateway. Read with defaults:
%%   alert_thresholds  #{min_share, ratio, min_n, baseline_weeks}: gh_agg:alerts/2's (the application setting
%%                     alert_thresholds, or gh_agg's defaults, until an admin sets them)
%%   notify            #{mqtt => boolean()}: whether new alerts of the merged counts are published on genhub/alerts
-module(gh_settings).
-compile({no_auto_import, [get/1, put/2]}).
-export([tables/0, get/1, put/2, check/2]).

-record(gh_setting, {key, value, updated}).

-define(THRESHOLDS, #{min_share => 0.10, ratio => 2.0, min_n => 5, baseline_weeks => 4}).

-spec tables() -> ok.
tables() ->
    case mnesia:create_table(gh_setting, [{attributes, record_info(fields, gh_setting)}, {disc_copies, [node()]}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, gh_setting}} -> ok
    end,
    ok = mnesia:wait_for_tables([gh_setting], 60000).

-spec get(alert_thresholds | notify) -> map().
get(Key) ->
    case mnesia:dirty_read(gh_setting, Key) of
        [#gh_setting{value = V}] -> V;
        [] -> default(Key)
    end.

default(alert_thresholds) -> maps:merge(?THRESHOLDS, application:get_env(genhub2, alert_thresholds, #{}));
default(notify) -> #{mqtt => true}.

%% sets a setting after check/2; ok or {error, Why}
-spec put(alert_thresholds | notify, map()) -> ok | {error, binary()}.
put(Key, Value) ->
    case check(Key, Value) of
        {ok, V} -> mnesia:dirty_write(#gh_setting{key = Key, value = V, updated = erlang:system_time(millisecond)});
        {error, _} = E -> E
    end.

%% a setting's value as JSON gives it (binary keys), checked and completed from the current one
-spec check(alert_thresholds | notify, map()) -> {ok, map()} | {error, binary()}.
check(alert_thresholds, M) when is_map(M) ->
    Cur = get(alert_thresholds),
    try
        V = maps:fold(fun(<<"min_share">>, X, A) when is_number(X), X > 0, X =< 1 -> A#{min_share => float(X)};
                         (<<"ratio">>, X, A) when is_number(X), X >= 1 -> A#{ratio => float(X)};
                         (<<"min_n">>, X, A) when is_integer(X), X >= 1 -> A#{min_n => X};
                         (<<"baseline_weeks">>, X, A) when is_integer(X), X >= 1, X =< 52 -> A#{baseline_weeks => X};
                         (_, _, _) -> throw(bad)
                      end, Cur, M),
        {ok, V}
    catch throw:bad ->
            {error, <<"min_share: (0, 1]; ratio: 1 or more; min_n: a whole number, 1 or more; baseline_weeks: 1-52">>}
    end;
check(notify, #{<<"mqtt">> := B}) when is_boolean(B) -> {ok, #{mqtt => B}};
check(notify, _) -> {error, <<"notify: {\"mqtt\": true | false}">>};
check(_, _) -> {error, <<"not a setting">>}.
