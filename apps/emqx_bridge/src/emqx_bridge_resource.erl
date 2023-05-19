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
-module(emqx_bridge_resource).

-include("emqx_bridge_resource.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").

-export([
    bridge_to_resource_type/1,
    resource_id/1,
    resource_id/2,
    bridge_id/2,
    parse_bridge_id/1,
    parse_bridge_id/2,
    bridge_hookpoint/1,
    bridge_hookpoint_to_bridge_id/1
]).

-export([
    create/2,
    create/3,
    create/4,
    create_dry_run/2,
    recreate/2,
    recreate/3,
    remove/1,
    remove/2,
    remove/4,
    reset_metrics/1,
    restart/2,
    start/2,
    stop/2,
    update/2,
    update/3,
    update/4
]).

%% bi-directional bridge with producer/consumer or ingress/egress configs
-define(IS_BI_DIR_BRIDGE(TYPE),
    (TYPE) =:= <<"mqtt">>
).
-define(IS_INGRESS_BRIDGE(TYPE),
    (TYPE) =:= <<"kafka_consumer">> orelse ?IS_BI_DIR_BRIDGE(TYPE)
).

%% [FIXME] this has no place here, it's used in parse_confs/3, which should
%% rather delegate to a behavior callback than implementing domain knowledge
%% here (reversed dependency)
-define(INSERT_TABLET_PATH, "/rest/v2/insertTablet").

-if(?EMQX_RELEASE_EDITION == ee).
bridge_to_resource_type(<<"mqtt">>) -> emqx_connector_mqtt;
bridge_to_resource_type(mqtt) -> emqx_connector_mqtt;
bridge_to_resource_type(<<"webhook">>) -> emqx_connector_http;
bridge_to_resource_type(webhook) -> emqx_connector_http;
bridge_to_resource_type(BridgeType) -> emqx_ee_bridge:resource_type(BridgeType).
-else.
bridge_to_resource_type(<<"mqtt">>) -> emqx_connector_mqtt;
bridge_to_resource_type(mqtt) -> emqx_connector_mqtt;
bridge_to_resource_type(<<"webhook">>) -> emqx_connector_http;
bridge_to_resource_type(webhook) -> emqx_connector_http.
-endif.

resource_id(BridgeId) when is_binary(BridgeId) ->
    <<"bridge:", BridgeId/binary>>.

resource_id(BridgeType, BridgeName) ->
    BridgeId = bridge_id(BridgeType, BridgeName),
    resource_id(BridgeId).

bridge_id(BridgeType, BridgeName) ->
    Name = bin(BridgeName),
    Type = bin(BridgeType),
    <<Type/binary, ":", Name/binary>>.

parse_bridge_id(BridgeId) ->
    parse_bridge_id(BridgeId, #{atom_name => true}).

-spec parse_bridge_id(list() | binary() | atom(), #{atom_name => boolean()}) ->
    {atom(), atom() | binary()}.
parse_bridge_id(BridgeId, Opts) ->
    case string:split(bin(BridgeId), ":", all) of
        [Type, Name] ->
            {to_type_atom(Type), validate_name(Name, Opts)};
        _ ->
            invalid_data(
                <<"should be of pattern {type}:{name}, but got ", BridgeId/binary>>
            )
    end.

bridge_hookpoint(BridgeId) ->
    <<"$bridges/", (bin(BridgeId))/binary>>.

bridge_hookpoint_to_bridge_id(?BRIDGE_HOOKPOINT(BridgeId)) ->
    {ok, BridgeId};
bridge_hookpoint_to_bridge_id(_) ->
    {error, bad_bridge_hookpoint}.

validate_name(Name0, Opts) ->
    Name = unicode:characters_to_list(Name0, utf8),
    case is_list(Name) andalso Name =/= [] of
        true ->
            case lists:all(fun is_id_char/1, Name) of
                true ->
                    case maps:get(atom_name, Opts, true) of
                        true -> list_to_existing_atom(Name);
                        false -> Name0
                    end;
                false ->
                    invalid_data(<<"bad name: ", Name0/binary>>)
            end;
        false ->
            invalid_data(<<"only 0-9a-zA-Z_-. is allowed in name: ", Name0/binary>>)
    end.

-spec invalid_data(binary()) -> no_return().
invalid_data(Reason) -> throw(#{kind => validation_error, reason => Reason}).

is_id_char(C) when C >= $0 andalso C =< $9 -> true;
is_id_char(C) when C >= $a andalso C =< $z -> true;
is_id_char(C) when C >= $A andalso C =< $Z -> true;
is_id_char($_) -> true;
is_id_char($-) -> true;
is_id_char($.) -> true;
is_id_char(_) -> false.

to_type_atom(Type) ->
    try
        erlang:binary_to_existing_atom(Type, utf8)
    catch
        _:_ ->
            invalid_data(<<"unknown bridge type: ", Type/binary>>)
    end.

reset_metrics(ResourceId) ->
    emqx_resource:reset_metrics(ResourceId).

restart(Type, Name) ->
    emqx_resource:restart(resource_id(Type, Name)).

stop(Type, Name) ->
    emqx_resource:stop(resource_id(Type, Name)).

start(Type, Name) ->
    emqx_resource:start(resource_id(Type, Name)).

create(BridgeId, Conf) ->
    {BridgeType, BridgeName} = parse_bridge_id(BridgeId),
    create(BridgeType, BridgeName, Conf).

create(Type, Name, Conf) ->
    create(Type, Name, Conf, #{}).

create(Type, Name, Conf, Opts) ->
    ?SLOG(info, #{
        msg => "create bridge",
        type => Type,
        name => Name,
        config => emqx_utils:redact(Conf)
    }),
    TypeBin = bin(Type),
    {ok, _Data} = emqx_resource:create_local(
        resource_id(Type, Name),
        <<"emqx_bridge">>,
        bridge_to_resource_type(Type),
        parse_confs(TypeBin, Name, Conf),
        parse_opts(Conf, Opts)
    ),
    ok.

update(BridgeId, {OldConf, Conf}) ->
    {BridgeType, BridgeName} = parse_bridge_id(BridgeId),
    update(BridgeType, BridgeName, {OldConf, Conf}).

update(Type, Name, {OldConf, Conf}) ->
    update(Type, Name, {OldConf, Conf}, #{}).

update(Type, Name, {OldConf, Conf}, Opts) ->
    %% TODO: sometimes its not necessary to restart the bridge connection.
    %%
    %% - if the connection related configs like `servers` is updated, we should restart/start
    %% or stop bridges according to the change.
    %% - if the connection related configs are not update, only non-connection configs like
    %% the `method` or `headers` of a WebHook is changed, then the bridge can be updated
    %% without restarting the bridge.
    %%
    case emqx_utils_maps:if_only_to_toggle_enable(OldConf, Conf) of
        false ->
            ?SLOG(info, #{
                msg => "update bridge",
                type => Type,
                name => Name,
                config => emqx_utils:redact(Conf)
            }),
            case recreate(Type, Name, Conf, Opts) of
                {ok, _} ->
                    ok;
                {error, not_found} ->
                    ?SLOG(warning, #{
                        msg => "updating_a_non_existing_bridge",
                        type => Type,
                        name => Name,
                        config => emqx_utils:redact(Conf)
                    }),
                    create(Type, Name, Conf, Opts);
                {error, Reason} ->
                    {error, {update_bridge_failed, Reason}}
            end;
        true ->
            %% we don't need to recreate the bridge if this config change is only to
            %% toggole the config 'bridge.{type}.{name}.enable'
            _ =
                case maps:get(enable, Conf, true) of
                    true ->
                        restart(Type, Name);
                    false ->
                        stop(Type, Name)
                end,
            ok
    end.

recreate(Type, Name) ->
    recreate(Type, Name, emqx:get_config([bridges, Type, Name])).

recreate(Type, Name, Conf) ->
    recreate(Type, Name, Conf, #{}).

recreate(Type, Name, Conf, Opts) ->
    TypeBin = bin(Type),
    emqx_resource:recreate_local(
        resource_id(Type, Name),
        bridge_to_resource_type(Type),
        parse_confs(TypeBin, Name, Conf),
        parse_opts(Conf, Opts)
    ).

create_dry_run(Type, Conf0) ->
    TmpPath0 = iolist_to_binary([?TEST_ID_PREFIX, emqx_utils:gen_id(8)]),
    TmpPath = emqx_utils:safe_filename(TmpPath0),
    Conf = emqx_utils_maps:safe_atom_key_map(Conf0),
    case emqx_connector_ssl:convert_certs(TmpPath, Conf) of
        {error, Reason} ->
            {error, Reason};
        {ok, ConfNew} ->
            try
                ParseConf = parse_confs(bin(Type), TmpPath, ConfNew),
                Res = emqx_resource:create_dry_run_local(
                    bridge_to_resource_type(Type), ParseConf
                ),
                Res
            catch
                %% validation errors
                throw:Reason ->
                    {error, Reason}
            after
                _ = maybe_clear_certs(TmpPath, ConfNew)
            end
    end.

remove(BridgeId) ->
    {BridgeType, BridgeName} = parse_bridge_id(BridgeId),
    remove(BridgeType, BridgeName, #{}, #{}).

remove(Type, Name) ->
    remove(Type, Name, #{}, #{}).

%% just for perform_bridge_changes/1
remove(Type, Name, _Conf, _Opts) ->
    ?SLOG(info, #{msg => "remove_bridge", type => Type, name => Name}),
    case emqx_resource:remove_local(resource_id(Type, Name)) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} -> {error, Reason}
    end.

maybe_clear_certs(TmpPath, #{ssl := SslConf} = Conf) ->
    %% don't remove the cert files if they are in use
    case is_tmp_path_conf(TmpPath, SslConf) of
        true -> emqx_connector_ssl:clear_certs(TmpPath, Conf);
        false -> ok
    end;
maybe_clear_certs(_TmpPath, _ConfWithoutSsl) ->
    ok.

is_tmp_path_conf(TmpPath, #{certfile := Certfile}) ->
    is_tmp_path(TmpPath, Certfile);
is_tmp_path_conf(TmpPath, #{keyfile := Keyfile}) ->
    is_tmp_path(TmpPath, Keyfile);
is_tmp_path_conf(TmpPath, #{cacertfile := CaCertfile}) ->
    is_tmp_path(TmpPath, CaCertfile);
is_tmp_path_conf(_TmpPath, _Conf) ->
    false.

is_tmp_path(TmpPath, File) ->
    string:str(str(File), str(TmpPath)) > 0.

%% convert bridge configs to what the connector modules want
parse_confs(
    <<"webhook">>,
    _Name,
    #{
        url := Url,
        method := Method,
        headers := Headers,
        request_timeout := ReqTimeout,
        max_retries := Retry
    } = Conf
) ->
    Url1 = bin(Url),
    {BaseUrl, Path} = parse_url(Url1),
    BaseUrl1 =
        case emqx_http_lib:uri_parse(BaseUrl) of
            {ok, BUrl} ->
                BUrl;
            {error, Reason} ->
                Reason1 = emqx_utils:readable_error_msg(Reason),
                invalid_data(<<"Invalid URL: ", Url1/binary, ", details: ", Reason1/binary>>)
        end,
    Conf#{
        base_url => BaseUrl1,
        request =>
            #{
                path => Path,
                method => Method,
                body => maps:get(body, Conf, undefined),
                headers => Headers,
                request_timeout => ReqTimeout,
                max_retries => Retry
            }
    };
parse_confs(<<"iotdb">>, Name, Conf) ->
    #{
        base_url := BaseURL,
        authentication :=
            #{
                username := Username,
                password := Password
            }
    } = Conf,
    BasicToken = base64:encode(<<Username/binary, ":", Password/binary>>),
    WebhookConfig =
        Conf#{
            method => <<"post">>,
            url => <<BaseURL/binary, ?INSERT_TABLET_PATH>>,
            headers => [
                {<<"Content-type">>, <<"application/json">>},
                {<<"Authorization">>, BasicToken}
            ]
        },
    parse_confs(
        <<"webhook">>,
        Name,
        WebhookConfig
    );
parse_confs(Type, Name, Conf) when ?IS_INGRESS_BRIDGE(Type) ->
    %% For some drivers that can be used as data-sources, we need to provide a
    %% hookpoint. The underlying driver will run `emqx_hooks:run/3` when it
    %% receives a message from the external database.
    BId = bridge_id(Type, Name),
    BridgeHookpoint = bridge_hookpoint(BId),
    Conf#{hookpoint => BridgeHookpoint, bridge_name => Name};
%% TODO: rename this to `kafka_producer' after alias support is added
%% to hocon; keeping this as just `kafka' for backwards compatibility.
parse_confs(<<"kafka">> = _Type, Name, Conf) ->
    Conf#{bridge_name => Name};
parse_confs(<<"pulsar_producer">> = _Type, Name, Conf) ->
    Conf#{bridge_name => Name};
parse_confs(_Type, _Name, Conf) ->
    Conf.

parse_url(Url) ->
    case string:split(Url, "//", leading) of
        [Scheme, UrlRem] ->
            case string:split(UrlRem, "/", leading) of
                [HostPort, Path] ->
                    {iolist_to_binary([Scheme, "//", HostPort]), Path};
                [HostPort] ->
                    {iolist_to_binary([Scheme, "//", HostPort]), <<>>}
            end;
        [Url] ->
            invalid_data(<<"Missing scheme in URL: ", Url/binary>>)
    end.

str(Bin) when is_binary(Bin) -> binary_to_list(Bin);
str(Str) when is_list(Str) -> Str.

bin(Bin) when is_binary(Bin) -> Bin;
bin(Str) when is_list(Str) -> list_to_binary(Str);
bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8).

parse_opts(Conf, Opts0) ->
    override_start_after_created(Conf, Opts0).

override_start_after_created(Config, Opts) ->
    Enabled = maps:get(enable, Config, true),
    StartAfterCreated = Enabled andalso maps:get(start_after_created, Opts, Enabled),
    Opts#{start_after_created => StartAfterCreated}.
