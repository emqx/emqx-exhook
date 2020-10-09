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

-export([ start_grpc_client_channel_inplace/3
        , stop_grpc_client_channel_inplace/1
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
        atom() | string(),
        [grpcbox_channel:endpoint()],
        grpcbox_channel:options()) -> {ok, pid()} | {error, term()}.
start_grpc_client_channel(Name, Endpoints, Options0) ->
    Options = Options0#{sync_start => true},
    Spec = #{id => Name,
             start => {grpcbox_channel, start_link, [Name, Endpoints, Options]},
             type => worker},

    supervisor:start_child(?MODULE, Spec).

-spec stop_grpc_client_channel(atom()) -> ok.
stop_grpc_client_channel(Name) ->
    ok = supervisor:terminate_child(?MODULE, Name),
    ok = supervisor:delete_child(?MODULE, Name).

-spec start_grpc_client_channel_inplace(
        atom() | string(),
        [grpcbox_channel:endpoint()],
        grpcbox_channel:options()) -> {ok, pid()} | {error, term()}.
start_grpc_client_channel_inplace(Name, Endpoints, Options0) ->
    Options = Options0#{sync_start => true},
    grpcbox_channel_sup:start_child(Name, Endpoints, Options).

-spec stop_grpc_client_channel_inplace(pid()) -> ok.
stop_grpc_client_channel_inplace(Pid) ->
    ok = supervisor:terminate_child(grpcbox_channel_sup, Pid).
