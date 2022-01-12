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

-module(emqx_exhook_handler).

-include("emqx_exhook.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-logger_header("[ExHook]").

-export([ on_client_connect/2
        , on_client_connack/3
        , on_client_connected/2
        , on_client_disconnected/3
        , on_client_authenticate/2
        , on_client_check_acl/4
        , on_client_subscribe/3
        , on_client_unsubscribe/3
        ]).

%% Session Lifecircle Hooks
-export([ on_session_created/2
        , on_session_subscribed/3
        , on_session_unsubscribed/3
        , on_session_resumed/2
        , on_session_discarded/2
        , on_session_takeovered/2
        , on_session_terminated/3
        ]).

%% Utils
-export([ message/1
        , stringfy/1
        , merge_responsed_bool/2
        , merge_responsed_message/2
        , assign_to_message/2
        , clientinfo/1
        ]).

-import(emqx_exhook,
        [ cast/2
        , call_fold/3
        ]).

-exhooks([ {'client.connect',      {?MODULE, on_client_connect,       []}}
         , {'client.connack',      {?MODULE, on_client_connack,       []}}
         , {'client.connected',    {?MODULE, on_client_connected,     []}}
         , {'client.disconnected', {?MODULE, on_client_disconnected,  []}}
         , {'client.authenticate', {?MODULE, on_client_authenticate,  []}}
         , {'client.check_acl',    {?MODULE, on_client_check_acl,     []}}
         , {'client.subscribe',    {?MODULE, on_client_subscribe,     []}}
         , {'client.unsubscribe',  {?MODULE, on_client_unsubscribe,   []}}
         , {'session.created',     {?MODULE, on_session_created,      []}}
         , {'session.subscribed',  {?MODULE, on_session_subscribed,   []}}
         , {'session.unsubscribed',{?MODULE, on_session_unsubscribed, []}}
         , {'session.resumed',     {?MODULE, on_session_resumed,      []}}
         , {'session.discarded',   {?MODULE, on_session_discarded,    []}}
         , {'session.takeovered',  {?MODULE, on_session_takeovered,   []}}
         , {'session.terminated',  {?MODULE, on_session_terminated,   []}}
         ]).

%%--------------------------------------------------------------------
%% Clients
%%--------------------------------------------------------------------

on_client_connect(ConnInfo, Props) ->
    Req = #{conninfo => conninfo(ConnInfo),
            props => properties(Props)
           },
    cast('client.connect', Req).

on_client_connack(ConnInfo, Rc, Props) ->
    Req = #{conninfo => conninfo(ConnInfo),
            result_code => stringfy(Rc),
            props => properties(Props)},
    cast('client.connack', Req).

on_client_connected(ClientInfo, _ConnInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo)},
    cast('client.connected', Req).

on_client_disconnected(ClientInfo, Reason, _ConnInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo),
            reason => stringfy(Reason)
           },
    cast('client.disconnected', Req).

on_client_authenticate(ClientInfo, AuthResult) ->
    Bool = maps:get(auth_result, AuthResult, undefined) == success,
    Req = #{clientinfo => clientinfo(ClientInfo),
            result => Bool
           },

    case call_fold('client.authenticate', Req,
                   fun merge_responsed_bool/2) of
        {StopOrOk, #{result := Bool}} when is_boolean(Bool) ->
            Result = case Bool of true -> success; _ -> not_authorized end,
            {StopOrOk, AuthResult#{auth_result => Result, anonymous => false}};
        _ ->
            {ok, AuthResult}
    end.

on_client_check_acl(ClientInfo, PubSub, Topic, Result) ->
    Bool = Result == allow,
    Type = case PubSub of
               publish -> 'PUBLISH';
               subscribe -> 'SUBSCRIBE'
           end,
    Req = #{clientinfo => clientinfo(ClientInfo),
            type => Type,
            topic => Topic,
            result => Bool
           },
    case call_fold('client.check_acl', Req,
                   fun merge_responsed_bool/2) of
        {StopOrOk, #{result := Bool}} when is_boolean(Bool) ->
            NResult = case Bool of true -> allow; _ -> deny end,
            {StopOrOk, NResult};
        _ -> {ok, Result}
    end.

on_client_subscribe(ClientInfo, Props, TopicFilters) ->
    Req = #{clientinfo => clientinfo(ClientInfo),
            props => properties(Props),
            topic_filters => topicfilters(TopicFilters)
           },
    cast('client.subscribe', Req).

on_client_unsubscribe(ClientInfo, Props, TopicFilters) ->
    Req = #{clientinfo => clientinfo(ClientInfo),
            props => properties(Props),
            topic_filters => topicfilters(TopicFilters)
           },
    cast('client.unsubscribe', Req).

%%--------------------------------------------------------------------
%% Session
%%--------------------------------------------------------------------

on_session_created(ClientInfo, _SessInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo)},
    cast('session.created', Req).

on_session_subscribed(ClientInfo, Topic, SubOpts) ->
    Req = #{clientinfo => clientinfo(ClientInfo),
            topic => Topic,
            subopts => maps:with([qos, share, rh, rap, nl], SubOpts)
           },
    cast('session.subscribed', Req).

on_session_unsubscribed(ClientInfo, Topic, _SubOpts) ->
    Req = #{clientinfo => clientinfo(ClientInfo),
            topic => Topic
           },
    cast('session.unsubscribed', Req).

on_session_resumed(ClientInfo, _SessInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo)},
    cast('session.resumed', Req).

on_session_discarded(ClientInfo, _SessInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo)},
    cast('session.discarded', Req).

on_session_takeovered(ClientInfo, _SessInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo)},
    cast('session.takeovered', Req).

on_session_terminated(ClientInfo, Reason, _SessInfo) ->
    Req = #{clientinfo => clientinfo(ClientInfo),
            reason => stringfy(Reason)},
    cast('session.terminated', Req).

%%--------------------------------------------------------------------
%% Types

properties(undefined) -> [];
properties(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) ->
        [#{name => stringfy(K),
           value => stringfy(V)} | Acc]
    end, [], M).

conninfo(_ConnInfo =
           #{clientid := ClientId, username := Username, peername := {Peerhost, _},
             sockname := {_, SockPort}, proto_name := ProtoName, proto_ver := ProtoVer,
             keepalive := Keepalive}) ->
    #{node => stringfy(node()),
      clientid => ClientId,
      username => maybe(Username),
      peerhost => ntoa(Peerhost),
      sockport => SockPort,
      proto_name => ProtoName,
      proto_ver => stringfy(ProtoVer),
      keepalive => Keepalive}.

clientinfo(ClientInfo =
            #{clientid := ClientId, username := Username, peerhost := PeerHost,
              sockport := SockPort, protocol := Protocol, mountpoint := Mountpoiont}) ->
    #{node => stringfy(node()),
      clientid => ClientId,
      username => maybe(Username),
      password => maybe(maps:get(password, ClientInfo, undefined)),
      peerhost => ntoa(PeerHost),
      sockport => SockPort,
      protocol => stringfy(Protocol),
      mountpoint => maybe(Mountpoiont),
      is_superuser => maps:get(is_superuser, ClientInfo, false),
      anonymous => maps:get(anonymous, ClientInfo, true)}.

message(#message{id = Id, qos = Qos, from = From, topic = Topic, payload = Payload, timestamp = Ts}) ->
    #{node => stringfy(node()),
      id => hexstr(Id),
      qos => Qos,
      from => stringfy(From),
      topic => Topic,
      payload => Payload,
      timestamp => Ts}.

assign_to_message(#{qos := Qos, topic := Topic, payload := Payload}, Message) ->
    Message#message{qos = Qos, topic = Topic, payload = Payload}.

topicfilters(Tfs) when is_list(Tfs) ->
    [#{name => Topic, qos => Qos} || {Topic, #{qos := Qos}} <- Tfs].

ntoa({0,0,0,0,0,16#ffff,AB,CD}) ->
    list_to_binary(inet_parse:ntoa({AB bsr 8, AB rem 256, CD bsr 8, CD rem 256}));
ntoa(IP) ->
    list_to_binary(inet_parse:ntoa(IP)).

maybe(undefined) -> <<>>;
maybe(B) -> B.

%% @private
stringfy(Term) when is_binary(Term) ->
    Term;
stringfy(Term) when is_integer(Term) ->
    integer_to_binary(Term);
stringfy(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);
stringfy(Term) ->
    unicode:characters_to_binary((io_lib:format("~0p", [Term]))).

hexstr(B) ->
    iolist_to_binary([io_lib:format("~2.16.0B", [X]) || X <- binary_to_list(B)]).

%%--------------------------------------------------------------------
%% Acc funcs

%% see exhook.proto
merge_responsed_bool(Req, #{type := 'IGNORE'}) ->
    {ok, Req};
merge_responsed_bool(Req, #{type := Type, value := {bool_result, NewBool}})
  when is_boolean(NewBool) ->
    NReq = Req#{result => NewBool},
    case Type of
        'CONTINUE' -> {ok, NReq};
        'STOP_AND_RETURN' -> {stop, NReq}
    end;
merge_responsed_bool(Req, Resp) ->
    ?LOG(warning, "Unknown responsed value ~0p to merge to callback chain", [Resp]),
    {ok, Req}.

merge_responsed_message(Req, #{type := 'IGNORE'}) ->
    {ok, Req};
merge_responsed_message(Req, #{type := Type, value := {message, NMessage}}) ->
    NReq = Req#{message => NMessage},
    case Type of
        'CONTINUE' -> {ok, NReq};
        'STOP_AND_RETURN' -> {stop, NReq}
    end;
merge_responsed_message(Req, Resp) ->
    ?LOG(warning, "Unknown responsed value ~0p to merge to callback chain", [Resp]),
    {ok, Req}.
