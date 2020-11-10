%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_exhook_sup).

-behaviour(supervisor).

-export([ start_link/0
        , init/1
        ]).

-export([ start_grpc_client_channel/3
        , stop_grpc_client_channel/1
        ]).

%%--------------------------------------------------------------------
%%  Supervisor APIs & Callbacks
%%--------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 10, 100}, []}}.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_grpc_client_channel(
        string(),
        uri_string:uri_string(),
        grpc_client:options()) -> {ok, pid()} | {error, term()}.
start_grpc_client_channel(Name, SvrAddr, Options) ->
    grpc_client_sup:create_channel_pool(Name, SvrAddr, Options).

-spec stop_grpc_client_channel(string()) -> ok.
stop_grpc_client_channel(Name) ->
    grpc_client_sup:stop_channel_pool(Name).
