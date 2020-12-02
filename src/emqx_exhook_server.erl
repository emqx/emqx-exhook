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

-module(emqx_exhook_server).

-include_lib("emqx/include/logger.hrl").

-logger_header("[ExHook Svr]").

-define(PB_CLIENT_MOD, emqx_exhook_v_1_hook_provider_client).

%% Load/Unload
-export([ load/2
        , unload/1
        ]).

%% APIs
-export([call/3]).

%% Infos
-export([ name/1
        , format/1
        ]).

-record(server, {
          %% Server name (equal to grpc client channel name)
          name :: server_name(),
          %% The server started options
          options :: list(),
          %% gRPC channel pid
          channel :: pid(),
          %% Registered hook names and options
          hookspec :: #{hookpoint() => map()},
          %% Metrcis name prefix
          prefix :: list()
       }).

-type server_name() :: string().
-type server() :: #server{}.

-type hookpoint() :: 'client.connect'
                   | 'client.connack'
                   | 'client.connected'
                   | 'client.disconnected'
                   | 'client.authenticate'
                   | 'client.check_acl'
                   | 'client.subscribe'
                   | 'client.unsubscribe'
                   | 'session.created'
                   | 'session.subscribed'
                   | 'session.unsubscribed'
                   | 'session.resumed'
                   | 'session.discarded'
                   | 'session.takeovered'
                   | 'session.terminated'
                   | 'message.publish'
                   | 'message.delivered'
                   | 'message.acked'
                   | 'message.dropped'.

-export_type([server/0]).

-dialyzer({nowarn_function, [inc_metrics/2]}).

%%--------------------------------------------------------------------
%% Load/Unload APIs
%%--------------------------------------------------------------------

-spec load(atom(), list()) -> {ok, server()} | {error, term()} .
load(Name0, Opts0) ->
    Name = prefix(Name0),
    {SvrAddr, ClientOpts} = channel_opts(Opts0),
    case emqx_exhook_sup:start_grpc_client_channel(Name, SvrAddr, ClientOpts) of
        {ok, _ChannPoolPid} ->
            case do_init(Name) of
                {ok, HookSpecs} ->
                    %% Reigster metrics
                    Prefix = lists:flatten(io_lib:format("exhook.~s.", [Name])),
                    ensure_metrics(Prefix, HookSpecs),
                    {ok, #server{name = Name,
                                 options = Opts0,
                                 channel = _ChannPoolPid,
                                 hookspec = HookSpecs,
                                 prefix = Prefix }};
                {error, _} = E ->
                    emqx_exhook_sup:stop_grpc_client_channel(Name), E
            end;
        {error, _} = E -> E
    end.

%% @private
prefix(Name) when is_atom(Name) ->
    "exhook:" ++ atom_to_list(Name);
prefix(Name) when is_binary(Name) ->
    "exhook:" ++ binary_to_list(Name);
prefix(Name) when is_list(Name) ->
    "exhook:" ++ Name.

%% @private
channel_opts(Opts) ->
    Scheme = proplists:get_value(scheme, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    SvrAddr = lists:flatten(io_lib:format("~s://~s:~w", [Scheme, Host, Port])),
    ClientOpts = case Scheme of
                     https ->
                         SslOpts = lists:keydelete(ssl, 1, proplists:get_value(ssl_options, Opts, [])),
                         #{gun_opts =>
                           #{transport => ssl,
                             transport_opts => SslOpts}};
                     _ -> #{}
                 end,
    {SvrAddr, ClientOpts}.

-spec unload(server()) -> ok.
unload(#server{name = Name}) ->
    _ = do_deinit(Name),
    _ = emqx_exhook_sup:stop_grpc_client_channel(Name),
    ok.

do_deinit(Name) ->
    _ = do_call(Name, 'on_provider_unloaded', #{}),
    ok.

do_init(ChannName) ->
    Req = #{broker => maps:from_list(emqx_sys:info())},
    case do_call(ChannName, 'on_provider_loaded', Req) of
        {ok, InitialResp} ->
            try
                {ok, resovle_hookspec(maps:get(hooks, InitialResp, []))}
            catch _:Reason:Stk ->
                ?LOG(error, "try to init ~p failed, reason: ~p, stacktrace: ~0p",
                             [ChannName, Reason, Stk]),
                {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
resovle_hookspec(HookSpecs) when is_list(HookSpecs) ->
    MessageHooks = message_hooks(),
    AvailableHooks = available_hooks(),
    lists:foldr(fun(HookSpec, Acc) ->
        case maps:get(name, HookSpec, undefined) of
            undefined -> Acc;
            Name0 ->
                Name = try binary_to_existing_atom(Name0, utf8) catch T:R:_ -> {T,R} end,
                case lists:member(Name, AvailableHooks) of
                    true ->
                        case lists:member(Name, MessageHooks) of
                            true ->
                                Acc#{Name => #{topics => maps:get(topics, HookSpec, [])}};
                            _ ->
                                Acc#{Name => #{}}
                        end;
                    _ -> error({unknown_hookpoint, Name})
                end
        end
    end, #{}, HookSpecs).

ensure_metrics(Prefix, HookSpecs) ->
    Keys = [list_to_atom(Prefix ++ atom_to_list(Hookpoint))
            || Hookpoint <- maps:keys(HookSpecs)],
    lists:foreach(fun emqx_metrics:ensure/1, Keys).

format(#server{name = Name, hookspec = Hooks}) ->
    io_lib:format("name=~p, hooks=~0p", [Name, Hooks]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

name(#server{name = Name}) ->
    Name.

-spec call(hookpoint(), map(), server())
  -> ignore
   | {ok, Resp :: term()}
   | {error, term()}.
call(Hookpoint, Req, #server{name = ChannName, hookspec = Hooks, prefix = Prefix}) ->
    GrpcFunc = hk2func(Hookpoint),
    case maps:get(Hookpoint, Hooks, undefined) of
        undefined -> ignore;
        Opts ->
            NeedCall  = case lists:member(Hookpoint, message_hooks()) of
                            false -> true;
                            _ ->
                                #{message := #{topic := Topic}} = Req,
                                match_topic_filter(Topic, maps:get(topics, Opts, []))
                        end,
            case NeedCall of
                false -> ignore;
                _ ->
                    inc_metrics(Prefix, Hookpoint),
                    do_call(ChannName, GrpcFunc, Req)
            end
    end.

%% @private
inc_metrics(IncFun, Name) when is_function(IncFun) ->
    %% BACKW: e4.2.0-e4.2.2
    {env, [Prefix|_]} = erlang:fun_info(IncFun, env),
    inc_metrics(Prefix, Name);
inc_metrics(Prefix, Name) when is_list(Prefix) ->
    emqx_metrics:inc(list_to_atom(Prefix ++ atom_to_list(Name))).

-compile({inline, [match_topic_filter/2]}).
match_topic_filter(_, []) ->
    true;
match_topic_filter(TopicName, TopicFilter) ->
    lists:any(fun(F) -> emqx_topic:match(TopicName, F) end, TopicFilter).

-spec do_call(string(), atom(), map()) -> {ok, map()} | {error, term()}.
do_call(ChannName, Fun, Req) ->
    Options = #{channel => ChannName},
    ?LOG(debug, "Call ~0p:~0p(~0p, ~0p)", [?PB_CLIENT_MOD, Fun, Req, Options]),
    case catch apply(?PB_CLIENT_MOD, Fun, [Req, Options]) of
        {ok, Resp, _Metadata} ->
            ?LOG(debug, "Response {ok, ~0p, ~0p}", [Resp, _Metadata]),
            {ok, Resp};
        {error, {Code, Msg}, _Metadata} ->
            ?LOG(error, "CALL ~0p:~0p(~0p, ~0p) response errcode: ~0p, errmsg: ~0p",
                        [?PB_CLIENT_MOD, Fun, Req, Options, Code, Msg]),
            {error, {Code, Msg}};
        {error, Reason} ->
            ?LOG(error, "CALL ~0p:~0p(~0p, ~0p) error: ~0p",
                        [?PB_CLIENT_MOD, Fun, Req, Options, Reason]),
            {error, Reason};
        {'EXIT', {Reason, Stk}} ->
            ?LOG(error, "CALL ~0p:~0p(~0p, ~0p) throw an exception: ~0p, stacktrace: ~0p",
                        [?PB_CLIENT_MOD, Fun, Req, Options, Reason, Stk]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

-compile({inline, [hk2func/1]}).
hk2func('client.connect') -> 'on_client_connect';
hk2func('client.connack') -> 'on_client_connack';
hk2func('client.connected') -> 'on_client_connected';
hk2func('client.disconnected') -> 'on_client_disconnected';
hk2func('client.authenticate') -> 'on_client_authenticate';
hk2func('client.check_acl') -> 'on_client_check_acl';
hk2func('client.subscribe') -> 'on_client_subscribe';
hk2func('client.unsubscribe') -> 'on_client_unsubscribe';
hk2func('session.created') -> 'on_session_created';
hk2func('session.subscribed') -> 'on_session_subscribed';
hk2func('session.unsubscribed') -> 'on_session_unsubscribed';
hk2func('session.resumed') -> 'on_session_resumed';
hk2func('session.discarded') -> 'on_session_discarded';
hk2func('session.takeovered') -> 'on_session_takeovered';
hk2func('session.terminated') -> 'on_session_terminated';
hk2func('message.publish') -> 'on_message_publish';
hk2func('message.delivered') ->'on_message_delivered';
hk2func('message.acked') -> 'on_message_acked';
hk2func('message.dropped') ->'on_message_dropped'.

-compile({inline, [message_hooks/0]}).
message_hooks() ->
    ['message.publish', 'message.delivered',
     'message.acked', 'message.dropped'].

-compile({inline, [available_hooks/0]}).
available_hooks() ->
    ['client.connect', 'client.connack', 'client.connected',
     'client.disconnected', 'client.authenticate', 'client.check_acl',
     'client.subscribe', 'client.unsubscribe',
     'session.created', 'session.subscribed', 'session.unsubscribed',
     'session.resumed', 'session.discarded', 'session.takeovered',
     'session.terminated' | message_hooks()].
