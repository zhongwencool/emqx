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
-module(emqx_mgmt_api_test_util).
-compile(export_all).
-compile(nowarn_export_all).

-define(SERVER, "http://127.0.0.1:18083").
-define(BASE_PATH, "/api/v5").

init_suite() ->
    init_suite([]).

init_suite(Apps) ->
    init_suite(Apps, fun set_special_configs/1, #{}).

init_suite(Apps, SetConfigs) when is_function(SetConfigs) ->
    init_suite(Apps, SetConfigs, #{}).

init_suite(Apps, SetConfigs, Opts) ->
    mria:start(),
    application:load(emqx_management),
    emqx_common_test_helpers:start_apps(Apps ++ [emqx_dashboard], SetConfigs, Opts),
    emqx_common_test_http:create_default_app().

end_suite() ->
    end_suite([]).

end_suite(Apps) ->
    emqx_common_test_http:delete_default_app(),
    application:unload(emqx_management),
    emqx_common_test_helpers:stop_apps(Apps ++ [emqx_dashboard]),
    emqx_config:delete_override_conf_files(),
    ok.

set_special_configs(emqx_dashboard) ->
    emqx_dashboard_api_test_helpers:set_default_config(),
    ok;
set_special_configs(_App) ->
    ok.

%% there is no difference between the 'request' and 'request_api'
%% the 'request' is only to be compatible with the 'emqx_dashboard_api_test_helpers:request'
request(Method, Url) ->
    request(Method, Url, []).

request(Method, Url, Body) ->
    request_api_with_body(Method, Url, Body).

uri(Parts) ->
    emqx_dashboard_api_test_helpers:uri(Parts).

%% compatible_mode will return as same as 'emqx_dashboard_api_test_helpers:request'
request_api_with_body(Method, Url, Body) ->
    Opts = #{compatible_mode => true, httpc_req_opts => [{body_format, binary}]},
    request_api(Method, Url, [], auth_header_(), Body, Opts).

request_api(Method, Url) ->
    request_api(Method, Url, auth_header_()).

request_api(Method, Url, AuthOrHeaders) ->
    request_api(Method, Url, [], AuthOrHeaders, [], #{}).

request_api(Method, Url, QueryParams, AuthOrHeaders) ->
    request_api(Method, Url, QueryParams, AuthOrHeaders, [], #{}).

request_api(Method, Url, QueryParams, AuthOrHeaders, Body) ->
    request_api(Method, Url, QueryParams, AuthOrHeaders, Body, #{}).

request_api(Method, Url, QueryParams, [], Body, Opts) ->
    request_api(Method, Url, QueryParams, auth_header_(), Body, Opts);
request_api(Method, Url, QueryParams, AuthOrHeaders, [], Opts) when
    (Method =:= options) orelse
        (Method =:= get) orelse
        (Method =:= put) orelse
        (Method =:= head) orelse
        (Method =:= delete) orelse
        (Method =:= trace)
->
    NewUrl =
        case QueryParams of
            "" -> Url;
            _ -> Url ++ "?" ++ QueryParams
        end,
    do_request_api(Method, {NewUrl, build_http_header(AuthOrHeaders)}, Opts);
request_api(Method, Url, QueryParams, AuthOrHeaders, Body, Opts) when
    (Method =:= post) orelse
        (Method =:= patch) orelse
        (Method =:= put) orelse
        (Method =:= delete)
->
    NewUrl =
        case QueryParams of
            "" -> Url;
            _ -> Url ++ "?" ++ QueryParams
        end,
    do_request_api(
        Method,
        {NewUrl, build_http_header(AuthOrHeaders), "application/json",
            emqx_utils_json:encode(Body)},
        Opts
    ).

do_request_api(Method, Request, Opts) ->
    ReturnAll = maps:get(return_all, Opts, false),
    CompatibleMode = maps:get(compatible_mode, Opts, false),
    HttpcReqOpts = maps:get(httpc_req_opts, Opts, []),
    ct:pal("Method: ~p, Request: ~p, Opts: ~p", [Method, Request, Opts]),
    case httpc:request(Method, Request, [], HttpcReqOpts) of
        {error, socket_closed_remotely} ->
            {error, socket_closed_remotely};
        {ok, {{_, Code, _}, _Headers, Body}} when CompatibleMode ->
            {ok, Code, Body};
        {ok, {{"HTTP/1.1", Code, _} = Reason, Headers, Body}} when
            Code >= 200 andalso Code =< 299 andalso ReturnAll
        ->
            {ok, {Reason, Headers, Body}};
        {ok, {{"HTTP/1.1", Code, _}, _, Body}} when
            Code >= 200 andalso Code =< 299
        ->
            {ok, Body};
        {ok, {Reason, Headers, Body}} when ReturnAll ->
            {error, {Reason, Headers, Body}};
        {ok, {Reason, _Headers, _Body}} ->
            {error, Reason}
    end.

auth_header_() ->
    emqx_common_test_http:default_auth_header().

build_http_header(X) when is_list(X) ->
    X;
build_http_header(X) ->
    [X].

api_path(Parts) ->
    ?SERVER ++ filename:join([?BASE_PATH | Parts]).

api_path_without_base_path(Parts) ->
    ?SERVER ++ filename:join([Parts]).

%% Usage:
%% upload_request(<<"site.com/api/upload">>, <<"path/to/file.png">>,
%% <<"upload">>, <<"image/png">>, [], <<"some-token">>)
%%
%% Usage with RequestData:
%% Payload = [{upload_type, <<"user_picture">>}],
%% PayloadContent = emqx_utils_json:encode(Payload),
%% RequestData = [
%%     {<<"payload">>, PayloadContent}
%% ]
%% upload_request(<<"site.com/api/upload">>, <<"path/to/file.png">>,
%% <<"upload">>, <<"image/png">>, RequestData, <<"some-token">>)
-spec upload_request(URL, FilePath, Name, MimeType, RequestData, AuthorizationToken) ->
    {ok, binary()} | {error, list()}
when
    URL :: binary(),
    FilePath :: binary(),
    Name :: binary(),
    MimeType :: binary(),
    RequestData :: list(),
    AuthorizationToken :: binary().
upload_request(URL, FilePath, Name, MimeType, RequestData, AuthorizationToken) ->
    Method = post,
    Filename = filename:basename(FilePath),
    {ok, Data} = file:read_file(FilePath),
    Boundary = emqx_guid:to_base62(emqx_guid:gen()),
    RequestBody = format_multipart_formdata(
        Data,
        RequestData,
        Name,
        [Filename],
        MimeType,
        Boundary
    ),
    ContentType = "multipart/form-data; boundary=" ++ binary_to_list(Boundary),
    ContentLength = integer_to_list(length(binary_to_list(RequestBody))),
    Headers = [
        {"Content-Length", ContentLength},
        case AuthorizationToken =/= undefined of
            true -> {"Authorization", "Bearer " ++ binary_to_list(AuthorizationToken)};
            false -> {}
        end
    ],
    HTTPOptions = [],
    Options = [{body_format, binary}],
    inets:start(),
    httpc:request(Method, {URL, Headers, ContentType, RequestBody}, HTTPOptions, Options).

-spec format_multipart_formdata(Data, Params, Name, FileNames, MimeType, Boundary) ->
    binary()
when
    Data :: binary(),
    Params :: list(),
    Name :: binary(),
    FileNames :: list(),
    MimeType :: binary(),
    Boundary :: binary().
format_multipart_formdata(Data, Params, Name, FileNames, MimeType, Boundary) ->
    StartBoundary = erlang:iolist_to_binary([<<"--">>, Boundary]),
    LineSeparator = <<"\r\n">>,
    WithParams = lists:foldl(
        fun({Key, Value}, Acc) ->
            erlang:iolist_to_binary([
                Acc,
                StartBoundary,
                LineSeparator,
                <<"Content-Disposition: form-data; name=\"">>,
                Key,
                <<"\"">>,
                LineSeparator,
                LineSeparator,
                Value,
                LineSeparator
            ])
        end,
        <<"">>,
        Params
    ),
    WithPaths = lists:foldl(
        fun(FileName, Acc) ->
            erlang:iolist_to_binary([
                Acc,
                StartBoundary,
                LineSeparator,
                <<"Content-Disposition: form-data; name=\"">>,
                Name,
                <<"\"; filename=\"">>,
                FileName,
                <<"\"">>,
                LineSeparator,
                <<"Content-Type: ">>,
                MimeType,
                LineSeparator,
                LineSeparator,
                Data,
                LineSeparator
            ])
        end,
        WithParams,
        FileNames
    ),
    erlang:iolist_to_binary([WithPaths, StartBoundary, <<"--">>, LineSeparator]).
