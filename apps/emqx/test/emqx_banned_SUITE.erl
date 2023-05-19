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

-module(emqx_banned_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_common_test_helpers:start_apps([]),
    ok = ekka:start(),
    Config.

end_per_suite(_Config) ->
    ekka:stop(),
    mria:stop(),
    mria_mnesia:delete_schema(),
    emqx_common_test_helpers:stop_apps([]).

t_add_delete(_) ->
    Banned = #banned{
        who = {clientid, <<"TestClient">>},
        by = <<"banned suite">>,
        reason = <<"test">>,
        at = erlang:system_time(second),
        until = erlang:system_time(second) + 1
    },
    {ok, _} = emqx_banned:create(Banned),
    {error, {already_exist, Banned}} = emqx_banned:create(Banned),
    ?assertEqual(1, emqx_banned:info(size)),
    {error, {already_exist, Banned}} =
        emqx_banned:create(Banned#banned{until = erlang:system_time(second) + 100}),
    ?assertEqual(1, emqx_banned:info(size)),

    ok = emqx_banned:delete({clientid, <<"TestClient">>}),
    ?assertEqual(0, emqx_banned:info(size)).

t_check(_) ->
    {ok, _} = emqx_banned:create(#banned{who = {clientid, <<"BannedClient">>}}),
    {ok, _} = emqx_banned:create(#banned{who = {username, <<"BannedUser">>}}),
    {ok, _} = emqx_banned:create(#banned{who = {peerhost, {192, 168, 0, 1}}}),
    ?assertEqual(3, emqx_banned:info(size)),
    ClientInfo1 = #{
        clientid => <<"BannedClient">>,
        username => <<"user">>,
        peerhost => {127, 0, 0, 1}
    },
    ClientInfo2 = #{
        clientid => <<"client">>,
        username => <<"BannedUser">>,
        peerhost => {127, 0, 0, 1}
    },
    ClientInfo3 = #{
        clientid => <<"client">>,
        username => <<"user">>,
        peerhost => {192, 168, 0, 1}
    },
    ClientInfo4 = #{
        clientid => <<"client">>,
        username => <<"user">>,
        peerhost => {127, 0, 0, 1}
    },
    ClientInfo5 = #{},
    ClientInfo6 = #{clientid => <<"client1">>},
    ?assert(emqx_banned:check(ClientInfo1)),
    ?assert(emqx_banned:check(ClientInfo2)),
    ?assert(emqx_banned:check(ClientInfo3)),
    ?assertNot(emqx_banned:check(ClientInfo4)),
    ?assertNot(emqx_banned:check(ClientInfo5)),
    ?assertNot(emqx_banned:check(ClientInfo6)),
    ok = emqx_banned:delete({clientid, <<"BannedClient">>}),
    ok = emqx_banned:delete({username, <<"BannedUser">>}),
    ok = emqx_banned:delete({peerhost, {192, 168, 0, 1}}),
    ?assertNot(emqx_banned:check(ClientInfo1)),
    ?assertNot(emqx_banned:check(ClientInfo2)),
    ?assertNot(emqx_banned:check(ClientInfo3)),
    ?assertNot(emqx_banned:check(ClientInfo4)),
    ?assertEqual(0, emqx_banned:info(size)).

t_unused(_) ->
    Who1 = {clientid, <<"BannedClient1">>},
    Who2 = {clientid, <<"BannedClient2">>},

    ?assertMatch(
        {ok, _},
        emqx_banned:create(#banned{
            who = Who1,
            until = erlang:system_time(second)
        })
    ),
    ?assertMatch(
        {ok, _},
        emqx_banned:create(#banned{
            who = Who2,
            until = erlang:system_time(second) - 1
        })
    ),
    ?assertEqual(ignored, gen_server:call(emqx_banned, unexpected_req)),
    ?assertEqual(ok, gen_server:cast(emqx_banned, unexpected_msg)),
    %% expiry timer
    timer:sleep(500),

    ok = emqx_banned:delete(Who1),
    ok = emqx_banned:delete(Who2).

t_kick(_) ->
    ClientId = <<"client">>,
    snabbkaffe:start_trace(),

    Now = erlang:system_time(second),
    Who = {clientid, ClientId},

    emqx_banned:create(#{
        who => Who,
        by => <<"test">>,
        reason => <<"test">>,
        at => Now,
        until => Now + 120
    }),

    Trace = snabbkaffe:collect_trace(),
    snabbkaffe:stop(),
    emqx_banned:delete(Who),
    ?assertEqual(1, length(?of_kind(kick_session_due_to_banned, Trace))).

t_session_taken(_) ->
    erlang:process_flag(trap_exit, true),
    Topic = <<"t/banned">>,
    ClientId2 = <<"t_session_taken">>,
    MsgNum = 3,
    Connect = fun() ->
        {ok, C} = emqtt:start_link([
            {clientid, <<"client1">>},
            {proto_ver, v5},
            {clean_start, false},
            {properties, #{'Session-Expiry-Interval' => 120}}
        ]),
        case emqtt:connect(C) of
            {ok, _} ->
                ok;
            {error, econnrefused} ->
                throw(mqtt_listener_not_ready)
        end,
        {ok, _, [0]} = emqtt:subscribe(C, Topic, []),
        C
    end,

    Publish = fun() ->
        lists:foreach(
            fun(_) ->
                Msg = emqx_message:make(ClientId2, Topic, <<"payload">>),
                emqx_broker:safe_publish(Msg)
            end,
            lists:seq(1, MsgNum)
        )
    end,
    emqx_common_test_helpers:wait_for(
        ?FUNCTION_NAME,
        ?LINE,
        fun() ->
            try
                C = Connect(),
                emqtt:disconnect(C),
                true
            catch
                throw:mqtt_listener_not_ready ->
                    false
            end
        end,
        15_000
    ),
    Publish(),

    C2 = Connect(),
    ?assertEqual(MsgNum, length(receive_messages(MsgNum + 1))),
    ok = emqtt:disconnect(C2),

    Publish(),

    Now = erlang:system_time(second),
    Who = {clientid, ClientId2},
    emqx_banned:create(#{
        who => Who,
        by => <<"test">>,
        reason => <<"test">>,
        at => Now,
        until => Now + 120
    }),

    C3 = Connect(),
    ?assertEqual(0, length(receive_messages(MsgNum + 1))),
    emqx_banned:delete(Who),
    {ok, #{}, [0]} = emqtt:unsubscribe(C3, Topic),
    ok = emqtt:disconnect(C3).

receive_messages(Count) ->
    receive_messages(Count, []).
receive_messages(0, Msgs) ->
    Msgs;
receive_messages(Count, Msgs) ->
    receive
        {publish, Msg} ->
            ct:log("Msg: ~p ~n", [Msg]),
            receive_messages(Count - 1, [Msg | Msgs]);
        Other ->
            ct:log("Other Msg: ~p~n", [Other]),
            receive_messages(Count, Msgs)
    after 1200 ->
        Msgs
    end.
