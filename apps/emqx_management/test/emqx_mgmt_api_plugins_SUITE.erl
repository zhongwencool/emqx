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
-module(emqx_mgmt_api_plugins_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-define(EMQX_PLUGIN_TEMPLATE_NAME, "emqx_plugin_template").
-define(EMQX_PLUGIN_TEMPLATE_VSN, "5.0.0").
-define(PACKAGE_SUFFIX, ".tar.gz").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    WorkDir = proplists:get_value(data_dir, Config),
    ok = filelib:ensure_dir(WorkDir),
    DemoShDir1 = string:replace(WorkDir, "emqx_mgmt_api_plugins", "emqx_plugins"),
    DemoShDir = lists:flatten(string:replace(DemoShDir1, "emqx_management", "emqx_plugins")),
    OrigInstallDir = emqx_plugins:get_config(install_dir, undefined),
    ok = filelib:ensure_dir(DemoShDir),
    emqx_mgmt_api_test_util:init_suite([emqx_conf, emqx_plugins]),
    emqx_plugins:put_config(install_dir, DemoShDir),
    [{demo_sh_dir, DemoShDir}, {orig_install_dir, OrigInstallDir} | Config].

end_per_suite(Config) ->
    emqx_common_test_helpers:boot_modules(all),
    %% restore config
    case proplists:get_value(orig_install_dir, Config) of
        undefined -> ok;
        OrigInstallDir -> emqx_plugins:put_config(install_dir, OrigInstallDir)
    end,
    emqx_mgmt_api_test_util:end_suite([emqx_plugins, emqx_conf]),
    ok.

t_plugins(Config) ->
    DemoShDir = proplists:get_value(demo_sh_dir, Config),
    PackagePath = get_demo_plugin_package(DemoShDir),
    ct:pal("package_location:~p install dir:~p", [PackagePath, emqx_plugins:install_dir()]),
    NameVsn = filename:basename(PackagePath, ?PACKAGE_SUFFIX),
    ok = emqx_plugins:ensure_uninstalled(NameVsn),
    ok = emqx_plugins:delete_package(NameVsn),
    ok = install_plugin(PackagePath),
    {ok, StopRes} = describe_plugins(NameVsn),
    Node = atom_to_binary(node()),
    ?assertMatch(
        #{
            <<"running_status">> := [
                #{<<"node">> := Node, <<"status">> := <<"stopped">>}
            ]
        },
        StopRes
    ),
    {ok, StopRes1} = update_plugin(NameVsn, "start"),
    ?assertEqual([], StopRes1),
    {ok, StartRes} = describe_plugins(NameVsn),
    ?assertMatch(
        #{
            <<"running_status">> := [
                #{<<"node">> := Node, <<"status">> := <<"running">>}
            ]
        },
        StartRes
    ),
    {ok, []} = update_plugin(NameVsn, "stop"),
    {ok, StopRes2} = describe_plugins(NameVsn),
    ?assertMatch(
        #{
            <<"running_status">> := [
                #{<<"node">> := Node, <<"status">> := <<"stopped">>}
            ]
        },
        StopRes2
    ),
    {ok, []} = uninstall_plugin(NameVsn),
    ok.

t_install_plugin_matching_exisiting_name(Config) ->
    DemoShDir = proplists:get_value(demo_sh_dir, Config),
    PackagePath = get_demo_plugin_package(DemoShDir),
    NameVsn = filename:basename(PackagePath, ?PACKAGE_SUFFIX),
    ok = emqx_plugins:ensure_uninstalled(NameVsn),
    ok = emqx_plugins:delete_package(NameVsn),
    NameVsn1 = ?EMQX_PLUGIN_TEMPLATE_NAME ++ "_a" ++ "-" ++ ?EMQX_PLUGIN_TEMPLATE_VSN,
    PackagePath1 = create_renamed_package(PackagePath, NameVsn1),
    NameVsn1 = filename:basename(PackagePath1, ?PACKAGE_SUFFIX),
    ok = emqx_plugins:ensure_uninstalled(NameVsn1),
    ok = emqx_plugins:delete_package(NameVsn1),
    %% First, install plugin "emqx_plugin_template_a", then:
    %% "emqx_plugin_template" which matches the beginning
    %% of the previously installed plugin name
    ok = install_plugin(PackagePath1),
    ok = install_plugin(PackagePath),
    {ok, _} = describe_plugins(NameVsn),
    {ok, _} = describe_plugins(NameVsn1),
    {ok, _} = uninstall_plugin(NameVsn),
    {ok, _} = uninstall_plugin(NameVsn1).

t_bad_plugin(Config) ->
    DemoShDir = proplists:get_value(demo_sh_dir, Config),
    PackagePathOrig = get_demo_plugin_package(DemoShDir),
    PackagePath = filename:join([
        filename:dirname(PackagePathOrig),
        "bad_plugin-1.0.0.tar.gz"
    ]),
    ct:pal("package_location:~p orig:~p", [PackagePath, PackagePathOrig]),
    %% rename plugin tarball
    file:copy(PackagePathOrig, PackagePath),
    file:delete(PackagePathOrig),
    {ok, {{"HTTP/1.1", 400, "Bad Request"}, _, _}} = install_plugin(PackagePath),
    ?assertEqual(
        {error, enoent},
        file:delete(
            filename:join([
                emqx_plugins:install_dir(),
                filename:basename(PackagePath)
            ])
        )
    ).

list_plugins() ->
    Path = emqx_mgmt_api_test_util:api_path(["plugins"]),
    case emqx_mgmt_api_test_util:request_api(get, Path) of
        {ok, Apps} -> {ok, emqx_utils_json:decode(Apps, [return_maps])};
        Error -> Error
    end.

describe_plugins(Name) ->
    Path = emqx_mgmt_api_test_util:api_path(["plugins", Name]),
    case emqx_mgmt_api_test_util:request_api(get, Path) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

install_plugin(FilePath) ->
    {ok, Token} = emqx_dashboard_admin:sign_token(<<"admin">>, <<"public">>),
    Path = emqx_mgmt_api_test_util:api_path(["plugins", "install"]),
    case
        emqx_mgmt_api_test_util:upload_request(
            Path,
            FilePath,
            "plugin",
            <<"application/gzip">>,
            [],
            Token
        )
    of
        {ok, {{"HTTP/1.1", 200, "OK"}, _Headers, <<>>}} -> ok;
        Error -> Error
    end.

update_plugin(Name, Action) ->
    Path = emqx_mgmt_api_test_util:api_path(["plugins", Name, Action]),
    emqx_mgmt_api_test_util:request_api(put, Path).

update_boot_order(Name, MoveBody) ->
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    Path = emqx_mgmt_api_test_util:api_path(["plugins", Name, "move"]),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", Auth, MoveBody) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

uninstall_plugin(Name) ->
    DeletePath = emqx_mgmt_api_test_util:api_path(["plugins", Name]),
    emqx_mgmt_api_test_util:request_api(delete, DeletePath).

get_demo_plugin_package(Dir) ->
    #{package := Pkg} = emqx_plugins_SUITE:get_demo_plugin_package(),
    FileName = ?EMQX_PLUGIN_TEMPLATE_NAME ++ "-" ++ ?EMQX_PLUGIN_TEMPLATE_VSN ++ ?PACKAGE_SUFFIX,
    PluginPath = "./" ++ FileName,
    Pkg = filename:join([Dir, FileName]),
    _ = os:cmd("cp " ++ Pkg ++ " " ++ PluginPath),
    true = filelib:is_regular(PluginPath),
    PluginPath.

create_renamed_package(PackagePath, NewNameVsn) ->
    {ok, Content} = erl_tar:extract(PackagePath, [compressed, memory]),
    {ok, NewName, _Vsn} = emqx_plugins:parse_name_vsn(NewNameVsn),
    NewNameB = atom_to_binary(NewName, utf8),
    Content1 = lists:map(
        fun({F, B}) ->
            [_ | PathPart] = filename:split(F),
            B1 = update_release_json(PathPart, B, NewNameB),
            {filename:join([NewNameVsn | PathPart]), B1}
        end,
        Content
    ),
    NewPackagePath = filename:join(filename:dirname(PackagePath), NewNameVsn ++ ?PACKAGE_SUFFIX),
    ok = erl_tar:create(NewPackagePath, Content1, [compressed]),
    NewPackagePath.

update_release_json(["release.json"], FileContent, NewName) ->
    ContentMap = emqx_utils_json:decode(FileContent, [return_maps]),
    emqx_utils_json:encode(ContentMap#{<<"name">> => NewName});
update_release_json(_FileName, FileContent, _NewName) ->
    FileContent.
