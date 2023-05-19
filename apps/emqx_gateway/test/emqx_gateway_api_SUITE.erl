%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_gateway_api_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-import(
    emqx_gateway_test_utils,
    [
        assert_confs/2,
        assert_fields_exist/2,
        request/2,
        request/3,
        ssl_server_opts/0,
        ssl_client_opts/0
    ]
).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% this parses to #{}, will not cause config cleanup
%% so we will need call emqx_config:erase
-define(CONF_DEFAULT, <<"gateway {}">>).

%%--------------------------------------------------------------------
%% Setup
%%--------------------------------------------------------------------

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Conf) ->
    application:load(emqx),
    emqx_gateway_test_utils:load_all_gateway_apps(),
    emqx_config:delete_override_conf_files(),
    emqx_config:erase(gateway),
    emqx_common_test_helpers:load_config(emqx_gateway_schema, ?CONF_DEFAULT),
    emqx_mgmt_api_test_util:init_suite([emqx_conf, emqx_authn, emqx_gateway]),
    Conf.

end_per_suite(Conf) ->
    emqx_mgmt_api_test_util:end_suite([emqx_gateway, emqx_authn, emqx_conf]),
    Conf.

init_per_testcase(t_gateway_fail, Config) ->
    meck:expect(
        emqx_gateway_conf,
        update_gateway,
        fun
            (stomp, V) -> {error, {badconf, #{key => gw, value => V, reason => test_error}}};
            (coap, V) -> error({badconf, #{key => gw, value => V, reason => test_crash}})
        end
    ),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(TestCase, Config) ->
    case TestCase of
        t_gateway_fail -> meck:unload(emqx_gateway_conf);
        _ -> ok
    end,
    [emqx_gateway_conf:unload_gateway(GwName) || GwName <- [stomp, mqttsn, coap, lwm2m, exproto]],
    Config.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

t_gateways(_) ->
    {200, Gateways} = request(get, "/gateways"),
    lists:foreach(fun assert_gw_unloaded/1, Gateways),
    {200, UnloadedGateways} = request(get, "/gateways?status=unloaded"),
    lists:foreach(fun assert_gw_unloaded/1, UnloadedGateways),
    {200, NoRunningGateways} = request(get, "/gateways?status=running"),
    ?assertEqual([], NoRunningGateways),
    {400, BadReqInvalidStatus} = request(get, "/gateways?status=invalid_status"),
    assert_bad_request(BadReqInvalidStatus),
    {400, BadReqUCStatus} = request(get, "/gateways?status=UNLOADED"),
    assert_bad_request(BadReqUCStatus),
    ok.

t_gateway(_) ->
    {404, GwNotFoundReq1} = request(get, "/gateways/not_a_known_atom"),
    assert_not_found(GwNotFoundReq1),
    {404, GwNotFoundReq2} = request(get, "/gateways/undefined"),
    assert_not_found(GwNotFoundReq2),
    {204, _} = request(put, "/gateways/stomp", #{}),
    {200, StompGw} = request(get, "/gateways/stomp"),
    assert_fields_exist(
        [name, status, enable, created_at, started_at],
        StompGw
    ),
    {204, _} = request(put, "/gateways/stomp", #{enable => true}),
    {200, #{enable := true}} = request(get, "/gateway/stomp"),
    {204, _} = request(put, "/gateways/stomp", #{enable => false}),
    {200, #{enable := false}} = request(get, "/gateway/stomp"),
    {404, _} = request(put, "/gateways/undefined", #{}),
    {400, _} = request(put, "/gateways/stomp", #{bad_key => "foo"}),
    ok.

t_gateway_fail(_) ->
    {204, _} = request(put, "/gateways/stomp", #{}),
    {400, _} = request(put, "/gateways/stomp", #{}),
    {204, _} = request(put, "/gateways/coap", #{}),
    {400, _} = request(put, "/gateways/coap", #{}),
    ok.

t_deprecated_gateway(_) ->
    {200, Gateways} = request(get, "/gateway"),
    lists:foreach(fun assert_gw_unloaded/1, Gateways),
    {404, NotFoundReq} = request(get, "/gateway/uname_gateway"),
    assert_not_found(NotFoundReq),
    {204, _} = request(put, "/gateway/stomp", #{}),
    {200, StompGw} = request(get, "/gateway/stomp"),
    assert_fields_exist(
        [name, status, enable, created_at, started_at],
        StompGw
    ),
    ok.

t_gateway_enable(_) ->
    {204, _} = request(put, "/gateways/stomp", #{}),
    {200, #{enable := Enable}} = request(get, "/gateway/stomp"),
    NotEnable = not Enable,
    {204, _} = request(put, "/gateways/stomp/enable/" ++ atom_to_list(NotEnable), undefined),
    {200, #{enable := NotEnable}} = request(get, "/gateway/stomp"),
    {204, _} = request(put, "/gateways/stomp/enable/" ++ atom_to_list(Enable), undefined),
    {200, #{enable := Enable}} = request(get, "/gateway/stomp"),
    {404, _} = request(put, "/gateways/undefined/enable/true", undefined),
    {404, _} = request(put, "/gateways/not_a_known_atom/enable/true", undefined),
    {404, _} = request(put, "/gateways/coap/enable/true", undefined),
    ok.

t_gateway_stomp(_) ->
    {200, Gw} = request(get, "/gateways/stomp"),
    assert_gw_unloaded(Gw),
    GwConf = #{
        name => <<"stomp">>,
        frame => #{
            max_headers => 5,
            max_headers_length => 100,
            max_body_length => 100
        },
        listeners => [
            #{name => <<"def">>, type => <<"tcp">>, bind => <<"61613">>}
        ]
    },
    {204, _} = request(put, "/gateways/stomp", GwConf),
    {200, ConfResp} = request(get, "/gateways/stomp"),
    assert_confs(GwConf, ConfResp),
    GwConf2 = emqx_utils_maps:deep_merge(GwConf, #{frame => #{max_headers => 10}}),
    {204, _} = request(put, "/gateways/stomp", maps:without([name, listeners], GwConf2)),
    {200, ConfResp2} = request(get, "/gateways/stomp"),
    assert_confs(GwConf2, ConfResp2),
    ok.

t_gateway_mqttsn(_) ->
    {200, Gw} = request(get, "/gateways/mqttsn"),
    assert_gw_unloaded(Gw),
    GwConf = #{
        name => <<"mqttsn">>,
        gateway_id => 1,
        broadcast => true,
        predefined => [#{id => 1, topic => <<"t/a">>}],
        enable_qos3 => true,
        listeners => [
            #{name => <<"def">>, type => <<"udp">>, bind => <<"1884">>}
        ]
    },
    {204, _} = request(put, "/gateways/mqttsn", GwConf),
    {200, ConfResp} = request(get, "/gateways/mqttsn"),
    assert_confs(GwConf, ConfResp),
    GwConf2 = emqx_utils_maps:deep_merge(GwConf, #{predefined => []}),
    {204, _} = request(put, "/gateways/mqttsn", maps:without([name, listeners], GwConf2)),
    {200, ConfResp2} = request(get, "/gateways/mqttsn"),
    assert_confs(GwConf2, ConfResp2),
    ok.

t_gateway_coap(_) ->
    {200, Gw} = request(get, "/gateways/coap"),
    assert_gw_unloaded(Gw),
    GwConf = #{
        name => <<"coap">>,
        heartbeat => <<"60s">>,
        connection_required => true,
        listeners => [
            #{name => <<"def">>, type => <<"udp">>, bind => <<"5683">>}
        ]
    },
    {204, _} = request(put, "/gateways/coap", GwConf),
    {200, ConfResp} = request(get, "/gateways/coap"),
    assert_confs(GwConf, ConfResp),
    GwConf2 = emqx_utils_maps:deep_merge(GwConf, #{heartbeat => <<"10s">>}),
    {204, _} = request(put, "/gateways/coap", maps:without([name, listeners], GwConf2)),
    {200, ConfResp2} = request(get, "/gateways/coap"),
    assert_confs(GwConf2, ConfResp2),
    ok.

t_gateway_lwm2m(_) ->
    {200, Gw} = request(get, "/gateways/lwm2m"),
    assert_gw_unloaded(Gw),
    XmlDir = filename:join(
        [
            emqx_common_test_helpers:proj_root(),
            "apps",
            "emqx_gateway_lwm2m",
            "lwm2m_xml"
        ]
    ),
    GwConf = #{
        name => <<"lwm2m">>,
        xml_dir => list_to_binary(XmlDir),
        lifetime_min => <<"1s">>,
        lifetime_max => <<"1000s">>,
        qmode_time_window => <<"30s">>,
        auto_observe => true,
        translators => #{
            command => #{topic => <<"dn/#">>},
            response => #{topic => <<"up/resp">>},
            notify => #{topic => <<"up/resp">>},
            register => #{topic => <<"up/resp">>},
            update => #{topic => <<"up/resp">>}
        },
        listeners => [
            #{name => <<"def">>, type => <<"udp">>, bind => <<"5783">>}
        ]
    },
    {204, _} = request(put, "/gateways/lwm2m", GwConf),
    {200, ConfResp} = request(get, "/gateways/lwm2m"),
    assert_confs(GwConf, ConfResp),
    GwConf2 = emqx_utils_maps:deep_merge(GwConf, #{qmode_time_window => <<"10s">>}),
    {204, _} = request(put, "/gateways/lwm2m", maps:without([name, listeners], GwConf2)),
    {200, ConfResp2} = request(get, "/gateways/lwm2m"),
    assert_confs(GwConf2, ConfResp2),
    ok.

t_gateway_exproto(_) ->
    {200, Gw} = request(get, "/gateways/exproto"),
    assert_gw_unloaded(Gw),
    GwConf = #{
        name => <<"exproto">>,
        server => #{bind => <<"9100">>},
        handler => #{address => <<"http://127.0.0.1:9001">>},
        listeners => [
            #{name => <<"def">>, type => <<"tcp">>, bind => <<"7993">>}
        ]
    },
    {204, _} = request(put, "/gateways/exproto", GwConf),
    {200, ConfResp} = request(get, "/gateways/exproto"),
    assert_confs(GwConf, ConfResp),
    GwConf2 = emqx_utils_maps:deep_merge(GwConf, #{server => #{bind => <<"9200">>}}),
    {204, _} = request(put, "/gateways/exproto", maps:without([name, listeners], GwConf2)),
    {200, ConfResp2} = request(get, "/gateways/exproto"),
    assert_confs(GwConf2, ConfResp2),
    ok.

t_gateway_exproto_with_ssl(_) ->
    {200, Gw} = request(get, "/gateways/exproto"),
    assert_gw_unloaded(Gw),

    SslSvrOpts = ssl_server_opts(),
    SslCliOpts = ssl_client_opts(),
    GwConf = #{
        name => <<"exproto">>,
        server => #{
            bind => <<"9100">>,
            ssl_options => SslSvrOpts
        },
        handler => #{
            address => <<"http://127.0.0.1:9001">>,
            ssl_options => SslCliOpts#{enable => true}
        },
        listeners => [
            #{name => <<"def">>, type => <<"tcp">>, bind => <<"7993">>}
        ]
    },
    {204, _} = request(put, "/gateways/exproto", GwConf),
    {200, ConfResp} = request(get, "/gateways/exproto"),
    assert_confs(GwConf, ConfResp),
    GwConf2 = emqx_utils_maps:deep_merge(GwConf, #{
        server => #{
            bind => <<"9200">>,
            ssl_options => SslCliOpts
        }
    }),
    {204, _} = request(put, "/gateways/exproto", maps:without([name, listeners], GwConf2)),
    {200, ConfResp2} = request(get, "/gateways/exproto"),
    assert_confs(GwConf2, ConfResp2),
    ok.

t_authn(_) ->
    init_gw("stomp"),
    AuthConf = #{
        mechanism => <<"password_based">>,
        backend => <<"built_in_database">>,
        user_id_type => <<"clientid">>
    },
    {201, _} = request(post, "/gateways/stomp/authentication", AuthConf),
    {200, ConfResp} = request(get, "/gateways/stomp/authentication"),
    assert_confs(AuthConf, ConfResp),

    AuthConf2 = maps:merge(AuthConf, #{user_id_type => <<"username">>}),
    {200, _} = request(put, "/gateways/stomp/authentication", AuthConf2),

    {200, ConfResp2} = request(get, "/gateways/stomp/authentication"),
    assert_confs(AuthConf2, ConfResp2),

    {204, _} = request(delete, "/gateways/stomp/authentication"),
    {204, _} = request(get, "/gateways/stomp/authentication"),
    ok.

t_authn_data_mgmt(_) ->
    init_gw("stomp"),
    AuthConf = #{
        mechanism => <<"password_based">>,
        backend => <<"built_in_database">>,
        user_id_type => <<"clientid">>
    },
    {201, _} = request(post, "/gateways/stomp/authentication", AuthConf),
    {200, ConfResp} =
        ?retry(10, 10, {200, _} = request(get, "/gateways/stomp/authentication")),
    assert_confs(AuthConf, ConfResp),

    User1 = #{
        user_id => <<"test">>,
        password => <<"123456">>,
        is_superuser => false
    },
    {201, _} = request(post, "/gateways/stomp/authentication/users", User1),
    {200, #{data := [UserRespd1]}} = request(get, "/gateways/stomp/authentication/users"),
    assert_confs(UserRespd1, User1),

    {200, UserRespd2} = request(
        get,
        "/gateways/stomp/authentication/users/test"
    ),
    assert_confs(UserRespd2, User1),

    {200, UserRespd3} = request(
        put,
        "/gateways/stomp/authentication/users/test",
        #{
            password => <<"654321">>,
            is_superuser => true
        }
    ),
    assert_confs(UserRespd3, User1#{is_superuser => true}),

    {200, UserRespd4} = request(
        get,
        "/gateways/stomp/authentication/users/test"
    ),
    assert_confs(UserRespd4, User1#{is_superuser => true}),

    {204, _} = request(delete, "/gateways/stomp/authentication/users/test"),

    {200, #{data := []}} = request(
        get,
        "/gateways/stomp/authentication/users"
    ),

    ImportUri = emqx_dashboard_api_test_helpers:uri(
        ["gateways", "stomp", "authentication", "import_users"]
    ),

    Dir = code:lib_dir(emqx_authn, test),
    JSONFileName = filename:join([Dir, <<"data/user-credentials.json">>]),
    {ok, JSONData} = file:read_file(JSONFileName),
    {ok, 204, _} = emqx_dashboard_api_test_helpers:multipart_formdata_request(ImportUri, [], [
        {filename, "user-credentials.json", JSONData}
    ]),

    CSVFileName = filename:join([Dir, <<"data/user-credentials.csv">>]),
    {ok, CSVData} = file:read_file(CSVFileName),
    {ok, 204, _} = emqx_dashboard_api_test_helpers:multipart_formdata_request(ImportUri, [], [
        {filename, "user-credentials.csv", CSVData}
    ]),

    {204, _} = request(delete, "/gateways/stomp/authentication"),
    {204, _} = request(get, "/gateways/stomp/authentication"),
    ok.

t_listeners_tcp(_) ->
    {204, _} = request(put, "/gateways/stomp", #{}),
    {404, _} = request(get, "/gateways/stomp/listeners"),
    LisConf = #{
        name => <<"def">>,
        type => <<"tcp">>,
        bind => <<"127.0.0.1:61613">>
    },
    {201, _} = request(post, "/gateways/stomp/listeners", LisConf),
    {200, ConfResp} = request(get, "/gateways/stomp/listeners"),
    assert_confs([LisConf], ConfResp),
    {200, ConfResp1} = request(get, "/gateways/stomp/listeners/stomp:tcp:def"),
    assert_confs(LisConf, ConfResp1),

    LisConf2 = maps:merge(LisConf, #{bind => <<"127.0.0.1:61614">>}),
    {200, _} = request(
        put,
        "/gateways/stomp/listeners/stomp:tcp:def",
        LisConf2
    ),

    {200, ConfResp2} = request(get, "/gateways/stomp/listeners/stomp:tcp:def"),
    assert_confs(LisConf2, ConfResp2),

    {204, _} = request(delete, "/gateways/stomp/listeners/stomp:tcp:def"),
    {404, _} = request(get, "/gateways/stomp/listeners/stomp:tcp:def"),
    ok.

t_listeners_authn(_) ->
    GwConf = #{
        name => <<"stomp">>,
        listeners => [
            #{
                name => <<"def">>,
                type => <<"tcp">>,
                bind => <<"127.0.0.1:61613">>
            }
        ]
    },
    ConfResp = init_gw("stomp", GwConf),
    assert_confs(GwConf, ConfResp),

    AuthConf = #{
        mechanism => <<"password_based">>,
        backend => <<"built_in_database">>,
        user_id_type => <<"clientid">>
    },
    Path = "/gateways/stomp/listeners/stomp:tcp:def/authentication",
    {201, _} = request(post, Path, AuthConf),
    {200, ConfResp2} = request(get, Path),
    assert_confs(AuthConf, ConfResp2),

    AuthConf2 = maps:merge(AuthConf, #{user_id_type => <<"username">>}),
    {200, _} = request(put, Path, AuthConf2),

    {200, ConfResp3} = request(get, Path),
    assert_confs(AuthConf2, ConfResp3),

    {204, _} = request(delete, Path),
    %% FIXME: 204?
    {204, _} = request(get, Path),
    ok.

t_listeners_authn_data_mgmt(_) ->
    GwConf = #{
        name => <<"stomp">>,
        listeners => [
            #{
                name => <<"def">>,
                type => <<"tcp">>,
                bind => <<"127.0.0.1:61613">>
            }
        ]
    },
    {204, _} = request(put, "/gateways/stomp", GwConf),
    {200, ConfResp} = request(get, "/gateways/stomp"),
    assert_confs(GwConf, ConfResp),

    AuthConf = #{
        mechanism => <<"password_based">>,
        backend => <<"built_in_database">>,
        user_id_type => <<"clientid">>
    },
    Path = "/gateways/stomp/listeners/stomp:tcp:def/authentication",
    {201, _} = request(post, Path, AuthConf),
    {200, ConfResp2} = request(get, Path),
    assert_confs(AuthConf, ConfResp2),

    User1 = #{
        user_id => <<"test">>,
        password => <<"123456">>,
        is_superuser => false
    },
    {201, _} = request(
        post,
        "/gateways/stomp/listeners/stomp:tcp:def/authentication/users",
        User1
    ),

    {200, #{data := [UserRespd1]}} = request(
        get,
        Path ++ "/users"
    ),
    assert_confs(UserRespd1, User1),

    {200, UserRespd2} = request(
        get,
        Path ++ "/users/test"
    ),
    assert_confs(UserRespd2, User1),

    {200, UserRespd3} = request(
        put,
        Path ++ "/users/test",
        #{password => <<"654321">>, is_superuser => true}
    ),
    assert_confs(UserRespd3, User1#{is_superuser => true}),

    {200, UserRespd4} = request(
        get,
        Path ++ "/users/test"
    ),
    assert_confs(UserRespd4, User1#{is_superuser => true}),

    {204, _} = request(
        delete,
        Path ++ "/users/test"
    ),

    {200, #{data := []}} = request(
        get,
        Path ++ "/users"
    ),

    ImportUri = emqx_dashboard_api_test_helpers:uri(
        ["gateways", "stomp", "listeners", "stomp:tcp:def", "authentication", "import_users"]
    ),

    Dir = code:lib_dir(emqx_authn, test),
    JSONFileName = filename:join([Dir, <<"data/user-credentials.json">>]),
    {ok, JSONData} = file:read_file(JSONFileName),
    {ok, 204, _} = emqx_dashboard_api_test_helpers:multipart_formdata_request(ImportUri, [], [
        {filename, "user-credentials.json", JSONData}
    ]),

    CSVFileName = filename:join([Dir, <<"data/user-credentials.csv">>]),
    {ok, CSVData} = file:read_file(CSVFileName),
    {ok, 204, _} = emqx_dashboard_api_test_helpers:multipart_formdata_request(ImportUri, [], [
        {filename, "user-credentials.csv", CSVData}
    ]),

    ok.

t_authn_fuzzy_search(_) ->
    init_gw("stomp"),
    AuthConf = #{
        mechanism => <<"password_based">>,
        backend => <<"built_in_database">>,
        user_id_type => <<"clientid">>
    },
    {201, _} = request(post, "/gateways/stomp/authentication", AuthConf),
    {200, ConfResp} = request(get, "/gateways/stomp/authentication"),
    assert_confs(AuthConf, ConfResp),

    Checker = fun({User, Fuzzy}) ->
        {200, #{data := [UserRespd]}} = request(
            get, "/gateways/stomp/authentication/users", Fuzzy
        ),
        assert_confs(UserRespd, User)
    end,

    Create = fun(User) ->
        {201, _} = request(post, "/gateways/stomp/authentication/users", User)
    end,

    UserDatas = [
        #{
            user_id => <<"test">>,
            password => <<"123456">>,
            is_superuser => false
        },
        #{
            user_id => <<"foo">>,
            password => <<"123456">>,
            is_superuser => true
        }
    ],

    FuzzyDatas = [[{<<"like_user_id">>, <<"test">>}], [{<<"is_superuser">>, <<"true">>}]],

    lists:foreach(Create, UserDatas),
    lists:foreach(Checker, lists:zip(UserDatas, FuzzyDatas)),

    {204, _} = request(delete, "/gateways/stomp/authentication"),
    {204, _} = request(get, "/gateways/stomp/authentication"),
    ok.

%%--------------------------------------------------------------------
%% Helpers

init_gw(GwName) ->
    init_gw(GwName, #{}).

init_gw(GwName, GwConf) ->
    {204, _} = request(put, "/gateways/" ++ GwName, GwConf),
    ?retry(
        10,
        10,
        begin
            {200, #{status := Status} = RespConf} = request(get, "/gateways/" ++ GwName),
            false = (Status == <<"unloaded">>),
            RespConf
        end
    ).

%%--------------------------------------------------------------------
%% Asserts

assert_gw_unloaded(Gateway) ->
    ?assertEqual(<<"unloaded">>, maps:get(status, Gateway)).

assert_bad_request(BadReq) ->
    ?assertEqual(<<"BAD_REQUEST">>, maps:get(code, BadReq)).

assert_not_found(NotFoundReq) ->
    ?assertEqual(<<"RESOURCE_NOT_FOUND">>, maps:get(code, NotFoundReq)).
