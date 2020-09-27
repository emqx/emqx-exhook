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

-module(prop_exhook_hooks).

-include_lib("proper/include/proper.hrl").

-import(emqx_ct_proper_types,
        [ conninfo/0
        , clientinfo/0
        , sessioninfo/0
        , message/0
        , connack_return_code/0
        , topictab/0
        , topic/0
        , subopts/0
        ]).

-define(ALL(Vars, Types, Exprs),
        ?SETUP(fun() ->
            State = do_setup(),
            fun() -> do_teardown(State) end
         end, ?FORALL(Vars, Types, Exprs))).

%%--------------------------------------------------------------------
%% Properties
%%--------------------------------------------------------------------

prop_client_connect() ->
    ?ALL({ConnInfo, ConnProps, Env},
         {conninfo(), conn_properties(), empty_env()},
       begin
           OutConnProps = emqx_hooks:run_fold('client.connect', [ConnInfo], ConnProps),
           {'on_client_connect', Resp} = emqx_exhook_demo_svr:take(),
           Resp = #{ props => properties(ConnProps),
                     conninfo =>
                       #{node => nodestr(),
                         clientid => maps:get(clientid, ConnInfo),
                         username => maps:get(username, ConnInfo, <<>>),
                         peerhost => peerhost(ConnInfo),
                         sockport => sockport(ConnInfo),
                         proto_name => maps:get(proto_name, ConnInfo),
                         proto_ver => stringfy(maps:get(proto_ver, ConnInfo)),
                         keepalive => maps:get(keepalive, ConnInfo)
                        }
                   },
           true
       end).

nodestr() ->
    stringfy(node()).

peerhost(#{peername := {Host, _}}) ->
    ntoa(Host).

sockport(#{sockname := {_, Port}}) ->
    Port.

%% copied from emqx_exhook

ntoa({0,0,0,0,0,16#ffff,AB,CD}) ->
    list_to_binary(inet_parse:ntoa({AB bsr 8, AB rem 256, CD bsr 8, CD rem 256}));
ntoa(IP) ->
    list_to_binary(inet_parse:ntoa(IP)).

properties(undefined) -> [];
properties(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) ->
        [#{name => stringfy(K),
           value => stringfy(V)} | Acc]
    end, [], M).

%% @private
stringfy(Term) when is_binary(Term) ->
    Term;
stringfy(Term) when is_integer(Term) ->
    integer_to_binary(Term);
stringfy(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);
stringfy(Term) when is_tuple(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).

%prop_client_connack() ->
%    ?ALL({ConnInfo, Rc, AckProps, Env},
%         {conninfo(), connack_return_code(), ack_properties(), empty_env()},
%        begin
%            true
%        end).
%
%prop_client_connected() ->
%    ?ALL({ClientInfo, ConnInfo, Env},
%         {clientinfo(), conninfo(), empty_env()},
%        begin
%            true
%        end).
%
%prop_client_disconnected() ->
%    ?ALL({ClientInfo, Reason, ConnInfo, Env},
%         {clientinfo(), shutdown_reason(), conninfo(), empty_env()},
%        begin
%            true
%        end).
%
%prop_client_subscribe() ->
%    ?ALL({ClientInfo, SubProps, TopicTab, Env},
%         {clientinfo(), sub_properties(), topictab(), topic_filter_env()},
%        begin
%            true
%        end).
%
%prop_client_unsubscribe() ->
%    ?ALL({ClientInfo, SubProps, TopicTab, Env},
%         {clientinfo(), unsub_properties(), topictab(), topic_filter_env()},
%        begin
%            true
%        end).
%
%prop_session_subscribed() ->
%    ?ALL({ClientInfo, Topic, SubOpts, Env},
%         {clientinfo(), topic(), subopts(), topic_filter_env()},
%        begin
%            true
%        end).
%
%prop_session_unsubscribed() ->
%    ?ALL({ClientInfo, Topic, SubOpts, Env},
%         {clientinfo(), topic(), subopts(), empty_env()},
%        begin
%            true
%        end).
%
%prop_session_terminated() ->
%    ?ALL({ClientInfo, Reason, SessInfo, Env},
%         {clientinfo(), shutdown_reason(), sessioninfo(), empty_env()},
%        begin
%            true
%        end).
%
%prop_message_publish() ->
%    ?ALL({Msg, Env, Encode}, {message(), topic_filter_env()},
%        begin
%            true
%        end).
%
%prop_message_delivered() ->
%    ?ALL({ClientInfo, Msg, Env, Encode}, {clientinfo(), message(), topic_filter_env()},
%        begin
%            true
%        end).
%
%prop_message_acked() ->
%    ?ALL({ClientInfo, Msg, Env, Encode}, {clientinfo(), message(), empty_env()},
%        begin
%            true
%        end).

%%--------------------------------------------------------------------
%% Helper
%%--------------------------------------------------------------------
do_setup() ->
    emqx_logger:set_log_level(debug),
    _ = emqx_exhook_demo_svr:start(),
    emqx_ct_helpers:start_apps([emqx_exhook], fun set_special_cfgs/1),
    %% waiting first loaded event
    {'on_provider_loaded', _} = emqx_exhook_demo_svr:take(),
    ok.

do_teardown(_) ->
    emqx_ct_helpers:stop_apps([emqx_exhook]),
    %% waiting last unloaded event
    {'on_provider_unloaded', _} = emqx_exhook_demo_svr:take(),
    _ = emqx_exhook_demo_svr:stop().

set_special_cfgs(emqx) ->
    application:set_env(emqx, allow_anonymous, false),
    application:set_env(emqx, enable_acl_cache, false),
    application:set_env(emqx, plugins_loaded_file,
                        emqx_ct_helpers:deps_path(emqx, "test/emqx_SUITE_data/loaded_plugins"));
set_special_cfgs(emqx_exhook) ->
    ok.

ensure_to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
ensure_to_binary(Bin) when is_binary(Bin) -> Bin.

%%--------------------------------------------------------------------
%% Generators
%%--------------------------------------------------------------------

conn_properties() ->
    #{}.

ack_properties() ->
    #{}.

sub_properties() ->
    #{}.

unsub_properties() ->
    #{}.

shutdown_reason() ->
    oneof([any(), {shutdown, atom()}]).

empty_env() ->
    {undefined}.

topic_filter_env() ->
    oneof([{<<"#">>}, {undefined}, {topic()}]).
