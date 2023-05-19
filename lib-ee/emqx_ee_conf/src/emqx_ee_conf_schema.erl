%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ee_conf_schema).

-behaviour(hocon_schema).

-export([namespace/0, roots/0, fields/1, translations/0, translation/1, validations/0]).

-define(EE_SCHEMA_MODULES, [emqx_license_schema, emqx_ee_schema_registry_schema]).

namespace() ->
    emqx_conf_schema:namespace().

roots() ->
    lists:foldl(
        fun(Module, Roots) ->
            Roots ++ apply(Module, roots, [])
        end,
        emqx_conf_schema:roots(),
        ?EE_SCHEMA_MODULES
    ).

fields(Name) ->
    emqx_conf_schema:fields(Name).

translations() ->
    emqx_conf_schema:translations().

translation(Name) ->
    emqx_conf_schema:translation(Name).

validations() ->
    emqx_conf_schema:validations().
