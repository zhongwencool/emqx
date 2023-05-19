%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_mgmt_api_api_keys_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> [{group, parallel}, {group, sequence}].
suite() -> [{timetrap, {minutes, 1}}].
groups() ->
    [
        {parallel, [parallel], [t_create, t_update, t_delete, t_authorize, t_create_unexpired_app]},
        {sequence, [], [t_bootstrap_file, t_create_failed]}
    ].

init_per_suite(Config) ->
    emqx_mgmt_api_test_util:init_suite([emqx_conf]),
    Config.

end_per_suite(_) ->
    emqx_mgmt_api_test_util:end_suite([emqx_conf]).

t_bootstrap_file(_) ->
    TestPath = <<"/api/v5/status">>,
    Bin = <<"test-1:secret-1\ntest-2:secret-2">>,
    File = "./bootstrap_api_keys.txt",
    ok = file:write_file(File, Bin),
    emqx:update_config([api_key, bootstrap_file], File),
    ok = emqx_mgmt_auth:init_bootstrap_file(),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-1">>, <<"secret-1">>)),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-2">>, <<"secret-2">>)),
    ?assertMatch({error, _}, emqx_mgmt_auth:authorize(TestPath, <<"test-2">>, <<"secret-1">>)),

    %% relaunch to check if the table is changed.
    Bin1 = <<"test-1:new-secret-1\ntest-2:new-secret-2">>,
    ok = file:write_file(File, Bin1),
    ok = emqx_mgmt_auth:init_bootstrap_file(),
    ?assertMatch({error, _}, emqx_mgmt_auth:authorize(TestPath, <<"test-1">>, <<"secret-1">>)),
    ?assertMatch({error, _}, emqx_mgmt_auth:authorize(TestPath, <<"test-2">>, <<"secret-2">>)),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-1">>, <<"new-secret-1">>)),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-2">>, <<"new-secret-2">>)),

    %% Compatibility
    Bin2 = <<"test-3:new-secret-3\ntest-4:new-secret-4">>,
    ok = file:write_file(File, Bin2),
    emqx:update_config([api_key, bootstrap_file], <<>>),
    emqx:update_config([dashboard, bootstrap_users_file], File),
    ok = emqx_mgmt_auth:init_bootstrap_file(),
    ?assertMatch(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-1">>, <<"new-secret-1">>)),
    ?assertMatch(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-2">>, <<"new-secret-2">>)),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-3">>, <<"new-secret-3">>)),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-4">>, <<"new-secret-4">>)),

    %% not found
    NotFoundFile = "./bootstrap_apps_not_exist.txt",
    emqx:update_config([api_key, bootstrap_file], NotFoundFile),
    ?assertMatch({error, "No such file or directory"}, emqx_mgmt_auth:init_bootstrap_file()),

    %% bad format
    BadBin = <<"test-1:secret-11\ntest-2 secret-12">>,
    ok = file:write_file(File, BadBin),
    emqx:update_config([api_key, bootstrap_file], File),
    ?assertMatch({error, #{reason := "invalid_format"}}, emqx_mgmt_auth:init_bootstrap_file()),
    ?assertEqual(ok, emqx_mgmt_auth:authorize(TestPath, <<"test-1">>, <<"secret-11">>)),
    ?assertMatch({error, _}, emqx_mgmt_auth:authorize(TestPath, <<"test-2">>, <<"secret-12">>)),
    emqx:update_config([api_key, bootstrap_file], <<>>),
    emqx:update_config([dashboard, bootstrap_users_file], <<>>),
    ok.

t_create(_Config) ->
    Name = <<"EMQX-API-KEY-1">>,
    {ok, Create} = create_app(Name),
    ?assertMatch(
        #{
            <<"api_key">> := _,
            <<"api_secret">> := _,
            <<"created_at">> := _,
            <<"desc">> := _,
            <<"enable">> := true,
            <<"expired_at">> := _,
            <<"name">> := Name
        },
        Create
    ),
    {ok, List} = list_app(),
    [App] = lists:filter(fun(#{<<"name">> := NameA}) -> NameA =:= Name end, List),
    ?assertEqual(false, maps:is_key(<<"api_secret">>, App)),
    {ok, App1} = read_app(Name),
    ?assertEqual(Name, maps:get(<<"name">>, App1)),
    ?assertEqual(true, maps:get(<<"enable">>, App1)),
    ?assertEqual(false, maps:is_key(<<"api_secret">>, App1)),
    ?assertEqual({error, {"HTTP/1.1", 404, "Not Found"}}, read_app(<<"EMQX-API-KEY-NO-EXIST">>)),
    ok.

t_create_failed(_Config) ->
    BadRequest = {error, {"HTTP/1.1", 400, "Bad Request"}},

    ?assertEqual(BadRequest, create_app(<<" error format name">>)),
    LongName = iolist_to_binary(lists:duplicate(257, "A")),
    ?assertEqual(BadRequest, create_app(<<" error format name">>)),
    ?assertEqual(BadRequest, create_app(LongName)),

    {ok, List} = list_app(),
    CreateNum = 100 - erlang:length(List),
    Names = lists:map(
        fun(Seq) ->
            <<"EMQX-API-FAILED-KEY-", (integer_to_binary(Seq))/binary>>
        end,
        lists:seq(1, CreateNum)
    ),
    lists:foreach(fun(N) -> {ok, _} = create_app(N) end, Names),
    ?assertEqual(BadRequest, create_app(<<"EMQX-API-KEY-MAXIMUM">>)),

    lists:foreach(fun(N) -> {ok, _} = delete_app(N) end, Names),
    Name = <<"EMQX-API-FAILED-KEY-1">>,
    ?assertMatch({ok, _}, create_app(Name)),
    ?assertEqual(BadRequest, create_app(Name)),
    {ok, _} = delete_app(Name),
    ?assertMatch({ok, #{<<"name">> := Name}}, create_app(Name)),
    {ok, _} = delete_app(Name),
    ok.

t_update(_Config) ->
    Name = <<"EMQX-API-UPDATE-KEY">>,
    {ok, _} = create_app(Name),

    ExpiredAt = to_rfc3339(erlang:system_time(second) + 10000),
    Change = #{
        expired_at => ExpiredAt,
        desc => <<"NoteVersion1"/utf8>>,
        enable => false
    },
    {ok, Update1} = update_app(Name, Change),
    ?assertEqual(Name, maps:get(<<"name">>, Update1)),
    ?assertEqual(false, maps:get(<<"enable">>, Update1)),
    ?assertEqual(<<"NoteVersion1"/utf8>>, maps:get(<<"desc">>, Update1)),
    ?assertEqual(
        calendar:rfc3339_to_system_time(binary_to_list(ExpiredAt)),
        calendar:rfc3339_to_system_time(binary_to_list(maps:get(<<"expired_at">>, Update1)))
    ),
    Unexpired1 = maps:without([expired_at], Change),
    {ok, Update2} = update_app(Name, Unexpired1),
    ?assertEqual(<<"infinity">>, maps:get(<<"expired_at">>, Update2)),
    Unexpired2 = Change#{expired_at => <<"infinity">>},
    {ok, Update3} = update_app(Name, Unexpired2),
    ?assertEqual(<<"infinity">>, maps:get(<<"expired_at">>, Update3)),

    ?assertEqual({error, {"HTTP/1.1", 404, "Not Found"}}, update_app(<<"Not-Exist">>, Change)),
    ok.

t_delete(_Config) ->
    Name = <<"EMQX-API-DELETE-KEY">>,
    {ok, _Create} = create_app(Name),
    {ok, Delete} = delete_app(Name),
    ?assertEqual([], Delete),
    ?assertEqual({error, {"HTTP/1.1", 404, "Not Found"}}, delete_app(Name)),
    ok.

t_authorize(_Config) ->
    Name = <<"EMQX-API-AUTHORIZE-KEY">>,
    {ok, #{<<"api_key">> := ApiKey, <<"api_secret">> := ApiSecret}} = create_app(Name),
    BasicHeader = emqx_common_test_http:auth_header(
        binary_to_list(ApiKey),
        binary_to_list(ApiSecret)
    ),
    SecretError = emqx_common_test_http:auth_header(
        binary_to_list(ApiKey),
        binary_to_list(ApiKey)
    ),
    KeyError = emqx_common_test_http:auth_header("not_found_key", binary_to_list(ApiSecret)),
    Unauthorized = {error, {"HTTP/1.1", 401, "Unauthorized"}},

    BanPath = emqx_mgmt_api_test_util:api_path(["banned"]),
    ApiKeyPath = emqx_mgmt_api_test_util:api_path(["api_key"]),
    UserPath = emqx_mgmt_api_test_util:api_path(["users"]),

    {ok, _Status} = emqx_mgmt_api_test_util:request_api(get, BanPath, BasicHeader),
    ?assertEqual(Unauthorized, emqx_mgmt_api_test_util:request_api(get, BanPath, KeyError)),
    ?assertEqual(Unauthorized, emqx_mgmt_api_test_util:request_api(get, BanPath, SecretError)),
    ?assertEqual(Unauthorized, emqx_mgmt_api_test_util:request_api(get, ApiKeyPath, BasicHeader)),
    ?assertEqual(Unauthorized, emqx_mgmt_api_test_util:request_api(get, UserPath, BasicHeader)),

    ?assertMatch(
        {ok, #{<<"api_key">> := _, <<"enable">> := false}},
        update_app(Name, #{enable => false})
    ),
    ?assertEqual(Unauthorized, emqx_mgmt_api_test_util:request_api(get, BanPath, BasicHeader)),

    Expired = #{
        expired_at => to_rfc3339(erlang:system_time(second) - 1),
        enable => true
    },
    ?assertMatch({ok, #{<<"api_key">> := _, <<"enable">> := true}}, update_app(Name, Expired)),
    ?assertEqual(Unauthorized, emqx_mgmt_api_test_util:request_api(get, BanPath, BasicHeader)),
    UnExpired = #{expired_at => infinity},
    ?assertMatch(
        {ok, #{<<"api_key">> := _, <<"expired_at">> := <<"infinity">>}},
        update_app(Name, UnExpired)
    ),
    {ok, _Status1} = emqx_mgmt_api_test_util:request_api(get, BanPath, BasicHeader),
    ok.

t_create_unexpired_app(_Config) ->
    Name1 = <<"EMQX-UNEXPIRED-API-KEY-1">>,
    Name2 = <<"EMQX-UNEXPIRED-API-KEY-2">>,
    {ok, Create1} = create_unexpired_app(Name1, #{}),
    ?assertMatch(#{<<"expired_at">> := <<"infinity">>}, Create1),
    {ok, Create2} = create_unexpired_app(Name2, #{expired_at => <<"infinity">>}),
    ?assertMatch(#{<<"expired_at">> := <<"infinity">>}, Create2),
    ok.

list_app() ->
    AuthHeader = emqx_dashboard_SUITE:auth_header_(),
    Path = emqx_mgmt_api_test_util:api_path(["api_key"]),
    case emqx_mgmt_api_test_util:request_api(get, Path, AuthHeader) of
        {ok, Apps} -> {ok, emqx_utils_json:decode(Apps, [return_maps])};
        Error -> Error
    end.

read_app(Name) ->
    AuthHeader = emqx_dashboard_SUITE:auth_header_(),
    Path = emqx_mgmt_api_test_util:api_path(["api_key", Name]),
    case emqx_mgmt_api_test_util:request_api(get, Path, AuthHeader) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

create_app(Name) ->
    AuthHeader = emqx_dashboard_SUITE:auth_header_(),
    Path = emqx_mgmt_api_test_util:api_path(["api_key"]),
    ExpiredAt = to_rfc3339(erlang:system_time(second) + 1000),
    App = #{
        name => Name,
        expired_at => ExpiredAt,
        desc => <<"Note"/utf8>>,
        enable => true
    },
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, App) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

create_unexpired_app(Name, Params) ->
    AuthHeader = emqx_dashboard_SUITE:auth_header_(),
    Path = emqx_mgmt_api_test_util:api_path(["api_key"]),
    App = maps:merge(#{name => Name, desc => <<"Note"/utf8>>, enable => true}, Params),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, App) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

delete_app(Name) ->
    AuthHeader = emqx_dashboard_SUITE:auth_header_(),
    DeletePath = emqx_mgmt_api_test_util:api_path(["api_key", Name]),
    emqx_mgmt_api_test_util:request_api(delete, DeletePath, AuthHeader).

update_app(Name, Change) ->
    AuthHeader = emqx_dashboard_SUITE:auth_header_(),
    UpdatePath = emqx_mgmt_api_test_util:api_path(["api_key", Name]),
    case emqx_mgmt_api_test_util:request_api(put, UpdatePath, "", AuthHeader, Change) of
        {ok, Update} -> {ok, emqx_utils_json:decode(Update, [return_maps])};
        Error -> Error
    end.

to_rfc3339(Sec) ->
    list_to_binary(calendar:system_time_to_rfc3339(Sec)).
