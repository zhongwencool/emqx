%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% This file contains common macros for testing.
%% It must not be used anywhere except in test suites.

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(assertWaitEvent(Code, EventMatch, Timeout),
    ?assertMatch(
        {_, {ok, EventMatch}},
        ?wait_async_action(
            Code,
            EventMatch,
            Timeout
        )
    )
).

-define(drainMailbox(),
    (fun F__Flush_() ->
        receive
            X__Msg_ -> [X__Msg_ | F__Flush_()]
        after 0 -> []
        end
    end)()
).

-define(assertReceive(PATTERN),
    ?assertReceive(PATTERN, 1000)
).

-define(assertReceive(PATTERN, TIMEOUT),
    (fun() ->
        receive
            X__V = PATTERN -> X__V
        after TIMEOUT ->
            erlang:error(
                {assertReceive, [
                    {module, ?MODULE},
                    {line, ?LINE},
                    {expression, (??PATTERN)},
                    {mailbox, ?drainMailbox()}
                ]}
            )
        end
    end)()
).
