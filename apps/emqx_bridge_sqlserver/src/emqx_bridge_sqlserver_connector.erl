%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_sqlserver_connector).

-behaviour(emqx_resource).

-include("emqx_bridge_sqlserver.hrl").

-include_lib("kernel/include/file.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%%====================================================================
%% Exports
%%====================================================================

%% Hocon config schema exports
-export([
    roots/0,
    fields/1
]).

%% callbacks for behaviour emqx_resource
-export([
    callback_mode/0,
    is_buffer_supported/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_get_status/2
]).

%% callbacks for ecpool
-export([connect/1]).

%% Internal exports used to execute code with ecpool worker
-export([do_get_status/1, worker_do_insert/3]).

-import(emqx_plugin_libs_rule, [str/1]).
-import(hoconsc, [mk/2, enum/1, ref/2]).

-define(ACTION_SEND_MESSAGE, send_message).

-define(SYNC_QUERY_MODE, handover).

-define(SQLSERVER_HOST_OPTIONS, #{
    default_port => ?SQLSERVER_DEFAULT_PORT
}).

-define(REQUEST_TIMEOUT(RESOURCE_OPTS),
    maps:get(request_timeout, RESOURCE_OPTS, ?DEFAULT_REQUEST_TIMEOUT)
).

-define(BATCH_INSERT_TEMP, batch_insert_temp).

-define(BATCH_INSERT_PART, batch_insert_part).
-define(BATCH_PARAMS_TOKENS, batch_insert_tks).

-define(FILE_MODE_755, 33261).
%% 32768 + 8#00400 + 8#00200 + 8#00100 + 8#00040 + 8#00010 + 8#00004 + 8#00001
%% See also
%% https://www.erlang.org/doc/man/file.html#read_file_info-2

%% Copied from odbc reference page
%% https://www.erlang.org/doc/man/odbc.html

%% as returned by connect/2
-type connection_reference() :: pid().
-type time_out() :: milliseconds() | infinity.
-type sql() :: string() | binary().
-type milliseconds() :: pos_integer().
%% Tuple of column values e.g. one row of the result set.
%% it's a variable size tuple of column values.
-type row() :: tuple().
%% Some kind of explanation of what went wrong
-type common_reason() :: connection_closed | extended_error() | term().
%% extended error type with ODBC
%% and native database error codes, as well as the base reason that would have been
%% returned had extended_errors not been enabled.
-type extended_error() :: {string(), integer(), _Reason :: term()}.
%% Name of column in the result set
-type col_name() :: string().
%% e.g. a list of the names of the selected columns in the result set.
-type col_names() :: [col_name()].
%% A list of rows from the result set.
-type rows() :: list(row()).

%% -type result_tuple() :: {updated, n_rows()} | {selected, col_names(), rows()}.
-type updated_tuple() :: {updated, n_rows()}.
-type selected_tuple() :: {selected, col_names(), rows()}.
%% The number of affected rows for UPDATE,
%% INSERT, or DELETE queries. For other query types the value
%% is driver defined, and hence should be ignored.
-type n_rows() :: integer().

%% These type was not used in this module, but we may use it later
%% -type odbc_data_type() ::
%%     sql_integer
%%     | sql_smallint
%%     | sql_tinyint
%%     | {sql_decimal, precision(), scale()}
%%     | {sql_numeric, precision(), scale()}
%%     | {sql_char, size()}
%%     | {sql_wchar, size()}
%%     | {sql_varchar, size()}
%%     | {sql_wvarchar, size()}
%%     | {sql_float, precision()}
%%     | {sql_wlongvarchar, size()}
%%     | {sql_float, precision()}
%%     | sql_real
%%     | sql_double
%%     | sql_bit
%%     | atom().
%% -type precision() :: integer().
%% -type scale() :: integer().
%% -type size() :: integer().

-type state() :: #{
    pool_name := binary(),
    resource_opts := map(),
    sql_templates := map()
}.

%%====================================================================
%% Configuration and default values
%%====================================================================

roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    [
        {server, server()}
        | add_default_username(emqx_connector_schema_lib:relational_db_fields())
    ].

add_default_username(Fields) ->
    lists:map(
        fun
            ({username, OrigUsernameFn}) ->
                {username, add_default_fn(OrigUsernameFn, <<"sa">>)};
            (Field) ->
                Field
        end,
        Fields
    ).

add_default_fn(OrigFn, Default) ->
    fun
        (default) -> Default;
        (Field) -> OrigFn(Field)
    end.

server() ->
    Meta = #{desc => ?DESC("server")},
    emqx_schema:servers_sc(Meta, ?SQLSERVER_HOST_OPTIONS).

%%====================================================================
%% Callbacks defined in emqx_resource
%%====================================================================

callback_mode() -> always_sync.

is_buffer_supported() -> false.

on_start(
    ResourceId = PoolName,
    #{
        server := Server,
        username := Username,
        password := Password,
        driver := Driver,
        database := Database,
        pool_size := PoolSize,
        resource_opts := ResourceOpts
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_sqlserver_connector",
        connector => ResourceId,
        config => emqx_utils:redact(Config)
    }),

    ODBCDir = code:priv_dir(odbc),
    OdbcserverDir = filename:join(ODBCDir, "bin/odbcserver"),
    {ok, Info = #file_info{mode = Mode}} = file:read_file_info(OdbcserverDir),
    case ?FILE_MODE_755 =:= Mode of
        true ->
            ok;
        false ->
            _ = file:write_file_info(OdbcserverDir, Info#file_info{mode = ?FILE_MODE_755}),
            ok
    end,

    Options = [
        {server, to_bin(Server)},
        {username, Username},
        {password, Password},
        {driver, Driver},
        {database, Database},
        {pool_size, PoolSize}
    ],

    State = #{
        %% also ResourceId
        pool_name => PoolName,
        sql_templates => parse_sql_template(Config),
        resource_opts => ResourceOpts
    },
    case emqx_resource_pool:start(PoolName, ?MODULE, Options) of
        ok ->
            {ok, State};
        {error, Reason} ->
            ?tp(
                sqlserver_connector_start_failed,
                #{error => Reason}
            ),
            {error, Reason}
    end.

on_stop(ResourceId, _State) ->
    ?SLOG(info, #{
        msg => "stopping_sqlserver_connector",
        connector => ResourceId
    }),
    emqx_resource_pool:stop(ResourceId).

-spec on_query(
    resource_id(),
    {?ACTION_SEND_MESSAGE, map()},
    state()
) ->
    ok
    | {ok, list()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_query(ResourceId, {?ACTION_SEND_MESSAGE, _Msg} = Query, State) ->
    ?TRACE(
        "SINGLE_QUERY_SYNC",
        "bridge_sqlserver_received",
        #{requests => Query, connector => ResourceId, state => State}
    ),
    do_query(ResourceId, Query, ?SYNC_QUERY_MODE, State).

-spec on_batch_query(
    resource_id(),
    [{?ACTION_SEND_MESSAGE, map()}],
    state()
) ->
    ok
    | {ok, list()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_batch_query(ResourceId, BatchRequests, State) ->
    ?TRACE(
        "BATCH_QUERY_SYNC",
        "bridge_sqlserver_received",
        #{requests => BatchRequests, connector => ResourceId, state => State}
    ),
    do_query(ResourceId, BatchRequests, ?SYNC_QUERY_MODE, State).

on_get_status(_InstanceId, #{pool_name := PoolName} = _State) ->
    Health = emqx_resource_pool:health_check_workers(
        PoolName,
        {?MODULE, do_get_status, []}
    ),
    status_result(Health).

status_result(_Status = true) -> connected;
status_result(_Status = false) -> connecting.
%% TODO:
%% case for disconnected

%%====================================================================
%% ecpool callback fns
%%====================================================================

-spec connect(Options :: list()) -> {ok, connection_reference()} | {error, term()}.
connect(Options) ->
    ConnectStr = lists:concat(conn_str(Options, [])),
    Opts = proplists:get_value(options, Options, []),
    odbc:connect(ConnectStr, Opts).

-spec do_get_status(connection_reference()) -> Result :: boolean().
do_get_status(Conn) ->
    case execute(Conn, <<"SELECT 1">>) of
        {selected, [[]], [{1}]} -> true;
        _ -> false
    end.

%%====================================================================
%% Internal Helper fns
%%====================================================================

%% TODO && FIXME:
%% About the connection string attribute `Encrypt`:
%% The default value is `yes` in odbc version 18.0+ and `no` in previous versions.
%% And encrypted connections always verify the server's certificate.
%% So `Encrypt=YES;TrustServerCertificate=YES` must be set in the connection string
%% when connecting to a server that has a self-signed certificate.
%% See also:
%% 'https://learn.microsoft.com/en-us/sql/connect/odbc/
%%      dsn-connection-string-attribute?source=recommendations&view=sql-server-ver16#encrypt'
conn_str([], Acc) ->
    %% we should use this for msodbcsql 18+
    %% lists:join(";", ["Encrypt=YES", "TrustServerCertificate=YES" | Acc]);
    lists:join(";", Acc);
conn_str([{driver, Driver} | Opts], Acc) ->
    conn_str(Opts, ["Driver=" ++ str(Driver) | Acc]);
conn_str([{server, Server} | Opts], Acc) ->
    #{hostname := Host, port := Port} = emqx_schema:parse_server(Server, ?SQLSERVER_HOST_OPTIONS),
    conn_str(Opts, ["Server=" ++ str(Host) ++ "," ++ str(Port) | Acc]);
conn_str([{database, Database} | Opts], Acc) ->
    conn_str(Opts, ["Database=" ++ str(Database) | Acc]);
conn_str([{username, Username} | Opts], Acc) ->
    conn_str(Opts, ["UID=" ++ str(Username) | Acc]);
conn_str([{password, Password} | Opts], Acc) ->
    conn_str(Opts, ["PWD=" ++ str(Password) | Acc]);
conn_str([{_, _} | Opts], Acc) ->
    conn_str(Opts, Acc).

%% Query with singe & batch sql statement
-spec do_query(
    resource_id(),
    Query :: {?ACTION_SEND_MESSAGE, map()} | [{?ACTION_SEND_MESSAGE, map()}],
    ApplyMode :: handover,
    state()
) ->
    {ok, list()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
do_query(
    ResourceId,
    Query,
    ApplyMode,
    #{pool_name := PoolName, sql_templates := Templates} = State
) ->
    ?TRACE(
        "SINGLE_QUERY_SYNC",
        "sqlserver_connector_received",
        #{query => Query, connector => ResourceId, state => State}
    ),

    %% only insert sql statement for single query and batch query
    case apply_template(Query, Templates) of
        {?ACTION_SEND_MESSAGE, SQL} ->
            Result = ecpool:pick_and_do(
                PoolName,
                {?MODULE, worker_do_insert, [SQL, State]},
                ApplyMode
            );
        Query ->
            Result = {error, {unrecoverable_error, invalid_query}};
        _ ->
            Result = {error, {unrecoverable_error, failed_to_apply_sql_template}}
    end,
    case Result of
        {error, Reason} ->
            ?tp(
                sqlserver_connector_query_return,
                #{error => Reason}
            ),
            ?SLOG(error, #{
                msg => "sqlserver_connector_do_query_failed",
                connector => ResourceId,
                query => Query,
                reason => Reason
            }),
            Result;
        _ ->
            ?tp(
                sqlserver_connector_query_return,
                #{result => Result}
            ),
            Result
    end.

worker_do_insert(
    Conn, SQL, #{resource_opts := ResourceOpts, pool_name := ResourceId} = State
) ->
    LogMeta = #{connector => ResourceId, state => State},
    try
        case execute(Conn, SQL, ?REQUEST_TIMEOUT(ResourceOpts)) of
            {selected, Rows, _} ->
                {ok, Rows};
            {updated, _} ->
                ok;
            {error, ErrStr} ->
                ?SLOG(error, LogMeta#{msg => "invalid_request", reason => ErrStr}),
                {error, {unrecoverable_error, {invalid_request, ErrStr}}}
        end
    catch
        _Type:Reason ->
            ?SLOG(error, LogMeta#{msg => "invalid_request", reason => Reason}),
            {error, {unrecoverable_error, {invalid_request, Reason}}}
    end.

-spec execute(pid(), sql()) ->
    updated_tuple()
    | selected_tuple()
    | [updated_tuple()]
    | [selected_tuple()]
    | {error, common_reason()}.
execute(Conn, SQL) ->
    odbc:sql_query(Conn, str(SQL)).

-spec execute(pid(), sql(), time_out()) ->
    updated_tuple()
    | selected_tuple()
    | [updated_tuple()]
    | [selected_tuple()]
    | {error, common_reason()}.
execute(Conn, SQL, Timeout) ->
    odbc:sql_query(Conn, str(SQL), Timeout).

to_bin(List) when is_list(List) ->
    unicode:characters_to_binary(List, utf8).

%% for bridge data to sql server
parse_sql_template(Config) ->
    RawSQLTemplates =
        case maps:get(sql, Config, undefined) of
            undefined -> #{};
            <<>> -> #{};
            SQLTemplate -> #{?ACTION_SEND_MESSAGE => SQLTemplate}
        end,

    BatchInsertTks = #{},
    parse_sql_template(maps:to_list(RawSQLTemplates), BatchInsertTks).

parse_sql_template([{Key, H} | T], BatchInsertTks) ->
    case emqx_plugin_libs_rule:detect_sql_type(H) of
        {ok, select} ->
            parse_sql_template(T, BatchInsertTks);
        {ok, insert} ->
            case emqx_plugin_libs_rule:split_insert_sql(H) of
                {ok, {InsertSQL, Params}} ->
                    parse_sql_template(
                        T,
                        BatchInsertTks#{
                            Key =>
                                #{
                                    ?BATCH_INSERT_PART => InsertSQL,
                                    ?BATCH_PARAMS_TOKENS => emqx_plugin_libs_rule:preproc_tmpl(
                                        Params
                                    )
                                }
                        }
                    );
                {error, Reason} ->
                    ?SLOG(error, #{msg => "split sql failed", sql => H, reason => Reason}),
                    parse_sql_template(T, BatchInsertTks)
            end;
        {error, Reason} ->
            ?SLOG(error, #{msg => "detect sql type failed", sql => H, reason => Reason}),
            parse_sql_template(T, BatchInsertTks)
    end;
parse_sql_template([], BatchInsertTks) ->
    #{
        ?BATCH_INSERT_TEMP => BatchInsertTks
    }.

%% single insert
apply_template(
    {?ACTION_SEND_MESSAGE = _Key, _Msg} = Query, Templates
) ->
    %% TODO: fix emqx_plugin_libs_rule:proc_tmpl/2
    %% it won't add single quotes for string
    apply_template([Query], Templates);
%% batch inserts
apply_template(
    [{?ACTION_SEND_MESSAGE = Key, _Msg} | _T] = BatchReqs,
    #{?BATCH_INSERT_TEMP := BatchInsertsTks} = _Templates
) ->
    case maps:get(Key, BatchInsertsTks, undefined) of
        undefined ->
            BatchReqs;
        #{?BATCH_INSERT_PART := BatchInserts, ?BATCH_PARAMS_TOKENS := BatchParamsTks} ->
            SQL = emqx_plugin_libs_rule:proc_batch_sql(BatchReqs, BatchInserts, BatchParamsTks),
            {Key, SQL}
    end;
apply_template(Query, Templates) ->
    %% TODO: more detail infomatoin
    ?SLOG(error, #{msg => "apply sql template failed", query => Query, templates => Templates}),
    {error, failed_to_apply_sql_template}.
