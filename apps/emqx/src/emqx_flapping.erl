%%--------------------------------------------------------------------
%% Copyright (c) 2018-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_flapping).

-behaviour(gen_server).

-include("emqx.hrl").
-include("types.hrl").
-include("logger.hrl").

-export([start_link/0, stop/0]).

%% API
-export([detect/1]).

-ifdef(TEST).
-export([get_policy/2]).
-endif.

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Tab
-define(FLAPPING_TAB, ?MODULE).

-record(flapping, {
    clientid :: emqx_types:clientid(),
    peerhost :: emqx_types:peerhost(),
    started_at :: pos_integer(),
    detect_cnt :: integer()
}).

-opaque flapping() :: #flapping{}.

-export_type([flapping/0]).

-spec start_link() -> emqx_types:startlink_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() -> gen_server:stop(?MODULE).

%% @doc Detect flapping when a MQTT client disconnected.
-spec detect(emqx_types:clientinfo()) -> boolean().
detect(#{clientid := ClientId, peerhost := PeerHost, zone := Zone}) ->
    Policy = #{max_count := Threshold} = get_policy([max_count, window_time, ban_time], Zone),
    %% The initial flapping record sets the detect_cnt to 0.
    InitVal = #flapping{
        clientid = ClientId,
        peerhost = PeerHost,
        started_at = erlang:system_time(millisecond),
        detect_cnt = 0
    },
    case ets:update_counter(?FLAPPING_TAB, ClientId, {#flapping.detect_cnt, 1}, InitVal) of
        Cnt when Cnt < Threshold -> false;
        _Cnt ->
            case ets:take(?FLAPPING_TAB, ClientId) of
                [Flapping] ->
                    ok = gen_server:cast(?MODULE, {detected, Flapping, Policy}),
                    true;
                [] ->
                    false
            end
    end.

get_policy(Keys, Zone) when is_list(Keys) ->
    RootKey = flapping_detect,
    Conf = emqx_config:get_zone_conf(Zone, [RootKey]),
    lists:foldl(
        fun(Key, Acc) ->
            case maps:find(Key, Conf) of
                {ok, V} -> Acc#{Key => V};
                error -> Acc#{Key => emqx_config:get([RootKey, Key])}
            end
        end,
        #{},
        Keys
    );
get_policy(Key, Zone) ->
    #{Key := Conf} = get_policy([Key], Zone),
    Conf.

now_diff(TS) -> erlang:system_time(millisecond) - TS.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ok = emqx_utils_ets:new(?FLAPPING_TAB, [
        public,
        set,
        {keypos, #flapping.clientid},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    start_timers(),
    {ok, #{}, hibernate}.

handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast(
    {detected,
        #flapping{
            clientid = ClientId,
            peerhost = PeerHost,
            started_at = StartedAt,
            detect_cnt = DetectCnt
        },
        #{window_time := WindTime, ban_time := Interval}},
    State
) ->
    case now_diff(StartedAt) < WindTime of
        %% Flapping happened:(
        true ->
            ?SLOG(
                warning,
                #{
                    msg => "flapping_detected",
                    peer_host => fmt_host(PeerHost),
                    detect_cnt => DetectCnt,
                    wind_time_in_ms => WindTime
                },
                #{clientid => ClientId}
            ),
            Now = erlang:system_time(second),
            Banned = #banned{
                who = {clientid, ClientId},
                by = <<"flapping detector">>,
                reason = <<"flapping is detected">>,
                at = Now,
                until = Now + (Interval div 1000)
            },
            {ok, _} = emqx_banned:create(Banned),
            ok;
        false ->
            ?SLOG(
                warning,
                #{
                    msg => "client_disconnected",
                    peer_host => fmt_host(PeerHost),
                    detect_cnt => DetectCnt,
                    interval => Interval
                },
                #{clientid => ClientId}
            )
    end,
    {noreply, State};
handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Msg}),
    {noreply, State}.

handle_info({timeout, _TRef, {garbage_collect, Zone}}, State) ->
    Timestamp =
        erlang:system_time(millisecond) - get_policy(window_time, Zone),
    MatchSpec = [{{'_', '_', '_', '$1', '_'}, [{'<', '$1', Timestamp}], [true]}],
    ets:select_delete(?FLAPPING_TAB, MatchSpec),
    _ = start_timer(Zone),
    {noreply, State, hibernate};
handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_timer(Zone) ->
    case get_policy(window_time, Zone) of
        WindowTime when is_integer(WindowTime) ->
            emqx_utils:start_timer(WindowTime, {garbage_collect, Zone});
        disabled ->
            ok
    end.

start_timers() ->
    maps:foreach(
        fun(Zone, _ZoneConf) ->
            start_timer(Zone)
        end,
        emqx:get_config([zones], #{})
    ).

fmt_host(PeerHost) ->
    try
        inet:ntoa(PeerHost)
    catch
        _:_ -> PeerHost
    end.
