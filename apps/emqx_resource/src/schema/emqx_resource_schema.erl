%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_resource_schema).

-include("emqx_resource.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-import(hoconsc, [mk/2, enum/1, ref/2]).

-export([namespace/0, roots/0, fields/1, desc/1]).

%% -------------------------------------------------------------------------------------------------
%% Hocon Schema Definitions

namespace() -> "resource_schema".

roots() -> [].

fields("resource_opts") ->
    [
        {resource_opts,
            mk(
                ref(?MODULE, "creation_opts"),
                resource_opts_meta()
            )}
    ];
fields("creation_opts") ->
    [
        {buffer_mode, fun buffer_mode/1},
        {worker_pool_size, fun worker_pool_size/1},
        {health_check_interval, fun health_check_interval/1},
        {resume_interval, fun resume_interval/1},
        {start_after_created, fun start_after_created/1},
        {start_timeout, fun start_timeout/1},
        {auto_restart_interval, fun auto_restart_interval/1},
        {query_mode, fun query_mode/1},
        {request_timeout, fun request_timeout/1},
        {inflight_window, fun inflight_window/1},
        {enable_batch, fun enable_batch/1},
        {batch_size, fun batch_size/1},
        {batch_time, fun batch_time/1},
        {enable_queue, fun enable_queue/1},
        {max_buffer_bytes, fun max_buffer_bytes/1},
        {buffer_seg_bytes, fun buffer_seg_bytes/1}
    ].

resource_opts_meta() ->
    #{
        required => false,
        default => #{},
        desc => ?DESC(<<"resource_opts">>)
    }.

worker_pool_size(type) -> non_neg_integer();
worker_pool_size(desc) -> ?DESC("worker_pool_size");
worker_pool_size(default) -> ?WORKER_POOL_SIZE;
worker_pool_size(required) -> false;
worker_pool_size(_) -> undefined.

resume_interval(type) -> emqx_schema:duration_ms();
resume_interval(importance) -> ?IMPORTANCE_HIDDEN;
resume_interval(desc) -> ?DESC("resume_interval");
resume_interval(required) -> false;
resume_interval(_) -> undefined.

health_check_interval(type) -> emqx_schema:duration_ms();
health_check_interval(desc) -> ?DESC("health_check_interval");
health_check_interval(default) -> ?HEALTHCHECK_INTERVAL_RAW;
health_check_interval(required) -> false;
health_check_interval(_) -> undefined.

start_after_created(type) -> boolean();
start_after_created(desc) -> ?DESC("start_after_created");
start_after_created(default) -> ?START_AFTER_CREATED_RAW;
start_after_created(required) -> false;
start_after_created(_) -> undefined.

start_timeout(type) -> emqx_schema:duration_ms();
start_timeout(desc) -> ?DESC("start_timeout");
start_timeout(default) -> ?START_TIMEOUT_RAW;
start_timeout(required) -> false;
start_timeout(_) -> undefined.

auto_restart_interval(type) -> hoconsc:union([infinity, emqx_schema:duration_ms()]);
auto_restart_interval(desc) -> ?DESC("auto_restart_interval");
auto_restart_interval(default) -> ?AUTO_RESTART_INTERVAL_RAW;
auto_restart_interval(required) -> false;
auto_restart_interval(_) -> undefined.

query_mode(type) -> enum([sync, async]);
query_mode(desc) -> ?DESC("query_mode");
query_mode(default) -> async;
query_mode(required) -> false;
query_mode(_) -> undefined.

request_timeout(type) -> hoconsc:union([infinity, emqx_schema:duration_ms()]);
request_timeout(desc) -> ?DESC("request_timeout");
request_timeout(default) -> <<"15s">>;
request_timeout(_) -> undefined.

enable_batch(type) -> boolean();
enable_batch(required) -> false;
enable_batch(default) -> true;
enable_batch(deprecated) -> {since, "v5.0.14"};
enable_batch(desc) -> ?DESC("enable_batch");
enable_batch(_) -> undefined.

enable_queue(type) -> boolean();
enable_queue(required) -> false;
enable_queue(default) -> false;
enable_queue(deprecated) -> {since, "v5.0.14"};
enable_queue(desc) -> ?DESC("enable_queue");
enable_queue(_) -> undefined.

inflight_window(type) -> pos_integer();
inflight_window(aliases) -> [async_inflight_window];
inflight_window(desc) -> ?DESC("inflight_window");
inflight_window(default) -> ?DEFAULT_INFLIGHT;
inflight_window(required) -> false;
inflight_window(_) -> undefined.

batch_size(type) -> pos_integer();
batch_size(desc) -> ?DESC("batch_size");
batch_size(default) -> ?DEFAULT_BATCH_SIZE;
batch_size(required) -> false;
batch_size(_) -> undefined.

batch_time(type) -> emqx_schema:duration_ms();
batch_time(desc) -> ?DESC("batch_time");
batch_time(default) -> ?DEFAULT_BATCH_TIME_RAW;
batch_time(required) -> false;
batch_time(_) -> undefined.

max_buffer_bytes(type) -> emqx_schema:bytesize();
max_buffer_bytes(aliases) -> [max_queue_bytes];
max_buffer_bytes(desc) -> ?DESC("max_buffer_bytes");
max_buffer_bytes(default) -> ?DEFAULT_BUFFER_BYTES_RAW;
max_buffer_bytes(required) -> false;
max_buffer_bytes(_) -> undefined.

buffer_mode(type) -> enum([memory_only, volatile_offload]);
buffer_mode(desc) -> ?DESC("buffer_mode");
buffer_mode(default) -> memory_only;
buffer_mode(required) -> false;
buffer_mode(importance) -> ?IMPORTANCE_HIDDEN;
buffer_mode(_) -> undefined.

buffer_seg_bytes(type) -> emqx_schema:bytesize();
buffer_seg_bytes(desc) -> ?DESC("buffer_seg_bytes");
buffer_seg_bytes(required) -> false;
buffer_seg_bytes(importance) -> ?IMPORTANCE_HIDDEN;
buffer_seg_bytes(_) -> undefined.

desc("creation_opts") -> ?DESC("creation_opts").
