%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2012, 2013 GoPivotal, Inc.  All rights reserved.
%% -----------------------------------------------------------------------------

%% JMS on Rabbit Selector Exchange plugin

%% -----------------------------------------------------------------------------
-module(rabbit_jms_topic_exchange).

-behaviour(rabbit_exchange_type).

-include("rabbit_jms_topic_exchange.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%% Rabbit exchange type functions:
-export([ description/0
        , serialise_events/0
        , route/2
        , validate/1
        , create/2
        , delete/3
        , validate_binding/2
        , add_binding/3
        , remove_bindings/3
        , assert_args_equivalence/2
        , policy_changed/3 ]).

%% Initialisation of database function:
-export([setup_db_schema/0]).

%%----------------------------------------------------------------------------

%% Register exchange type
-rabbit_boot_step({ ?MODULE
                  , [ {description, "exchange type JMS topic selector"}
                    , {mfa, {rabbit_registry, register, [exchange, ?X_TYPE_NAME, ?MODULE]}}
                    , {requires, rabbit_registry}
                    , {enables, kernel_ready} ] }).

%% Initialise database
-rabbit_boot_step({ rabbit_jms_topic_exchange_mnesia
                  , [ {description, "database exchange type JMS topic selector"}
                    , {mfa, {?MODULE, setup_db_schema, []}}
                    , {requires, database}
                    , {enables, external_infrastructure} ] }).

%%----------------------------------------------------------------------------

% Initialise database table for all exchanges of type <<"x-jms-topic">>
setup_db_schema() ->
  case mnesia:create_table( ?JMS_TOPIC_TABLE
                          , [ {attributes, record_info(fields, ?JMS_TOPIC_RECORD)}
                            , {record_name, ?JMS_TOPIC_RECORD}
                            , {type, set} ]
                          ) of
    {atomic, ok} -> ok;
    {aborted, {already_exists, ?JMS_TOPIC_TABLE}} -> ok
  end.

%%----------------------------------------------------------------------------
%% R E F E R E N C E   T Y P E   I N F O R M A T I O N

%% -type(binding() ::
%%         #binding{source      :: rabbit_exchange:name(),
%%                  destination :: binding_destination(),
%%                  key         :: rabbit_binding:key(),
%%                  args        :: rabbit_framing:amqp_table()}).
%%
%% -type(exchange() ::
%%         #exchange{name        :: rabbit_exchange:name(),
%%                   type        :: rabbit_exchange:type(),
%%                   durable     :: boolean(),
%%                   auto_delete :: boolean(),
%%                   arguments   :: rabbit_framing:amqp_table()}).
%%
%% -type(amqp_field_type() ::
%%       'longstr' | 'signedint' | 'decimal' | 'timestamp' |
%%       'table' | 'byte' | 'double' | 'float' | 'long' |
%%       'short' | 'bool' | 'binary' | 'void' | 'array').

%%----------------------------------------------------------------------------
%% E X P O R T E D   E X C H A N G E   B E H A V I O U R

% Exchange description
description() -> [ {name, <<"jms-selector">>}
                 , {description, <<"JMS selector exchange">>} ].

% Binding event serialisation
serialise_events() -> false.

% Route messages
route( #exchange{name = XName}
     , #delivery{message = #basic_message{content = MessageContent, routing_keys = RKs}}
     ) ->
  {XPol, BindingFuns} = get_policy_and_binding_funs_x(XName),
  match_bindings_by_policy(XName, RKs, MessageContent, XPol, BindingFuns).


% Before exchange declaration
validate(_X) -> ok.

% After exchange declaration and recovery
create(transaction, #exchange{name = XName, arguments = XArgs}) ->
  add_initial_record(XName, get_selection_policy_from_arguments(XArgs));
create(_Tx, _X) ->
  ok.

% Delete an exchange
delete(transaction, #exchange{name = XName}, _Bs) ->
  delete_state(XName),
  ok;
delete(_Tx, _X, _Bs) ->
  ok.

% Before add binding
validate_binding(_X, _B) -> ok.

% A new binding has ben added or recovered
add_binding( Tx
           , #exchange{name = XName, arguments = XArgs}
           , #binding{key = BindingKey, destination = Dest = #resource{name = DestName}, args = Args}
           ) ->
  SQL = get_sql_from_args(Args),
  BindGen = case {get_selection_policy_from_arguments(XArgs), DestName, BindingKey} of
              {jms_queue, N, N} -> {ok, undefined};
              _                 -> generate_binding_fun(SQL, get_type_info_from_arguments(XArgs))
            end,
  case {Tx, BindGen} of
    {transaction, {ok, BindFun}} ->
      add_binding_fun(XName, {{BindingKey, Dest}, BindFun});
    {none, error} ->
      parsing_error(XName, SQL, Dest);
    _ ->
      ok
  end,
  ok.

% Binding removal
remove_bindings( transaction
               , #exchange{name = XName}
               , Bindings
               ) ->
  remove_binding_funs(XName, Bindings),
  ok;
remove_bindings(_Tx, _X, _Bs) ->
  ok.

% Exchange argument equivalence
assert_args_equivalence(X, Args) ->
  rabbit_exchange:assert_args_equivalence(X, Args).

% Policy change notifications ignored
policy_changed(_Tx, _X1, _X2) -> ok.

%%----------------------------------------------------------------------------
%% P R I V A T E   F U N C T I O N S

% Match bindings for the current message under the appropriate policy
match_bindings_by_policy(XName, _RoutingKeys, MessageContent, jms_topic, BindingFuns) ->
  MessageHeaders = get_headers(MessageContent),
  rabbit_router:match_bindings( XName
                              , fun(#binding{key = Key, destination = Dest}) ->
                                  binding_fun_match({Key, Dest}, MessageHeaders, BindingFuns)
                                end
                              );
match_bindings_by_policy(XName, [RoutingKey | _], MessageContent, jms_queue, BindingFuns) ->
  % assume exactly one routing key
  % get base binding and first matching selector binding if there is one....
  case get_base_and_selection(MessageContent, RoutingKey, BindingFuns) of
    {undefined, undefined   } -> [];
    {BaseDest , undefined   } -> [BaseDest];
    {_        , SelectorDest} -> [SelectorDest]
  end.

get_base_and_selection(Content, RKey, Funs) ->
  {BD, SD, _, _, _} = dict:fold(fun dict_scan/3, {undefined, undefined, Content, undefined, RKey}, Funs),
  {BD, SD}.

dict_scan({RKey, Dest = #resource{name = RKey}}, _BFun, {_       , SelDest  , Content, Headers  , RKey}) -> {Dest, SelDest, Content, Headers, RKey};
dict_scan({RKey, Dest                         },  BFun, {BaseDest, undefined, Content, undefined, RKey}) -> dict_scan({RKey, Dest}, BFun, {BaseDest, undefined, Content, get_headers(Content), RKey});
dict_scan({RKey, Dest                         },  BFun, {BaseDest, undefined, Content, Headers  , RKey}) -> case BFun(Headers) of
                                                                                                              true -> {BaseDest, Dest, Content, Headers, RKey};
                                                                                                              _    -> {BaseDest, undefined, Content, Headers, RKey}
                                                                                                            end;
dict_scan(_RKeyDest, _BFun, Acc) -> Acc.

% Select binding function from Funs dictionary, apply it to Headers and return result (true|false)
binding_fun_match(DictKey, Headers, FunsDict) ->
  case dict:find(DictKey, FunsDict) of
    {ok, Fun} when is_function(Fun, 1) -> Fun(Headers);
    error                              -> false          % do not match if no function found
  end.

get_type_info_from_arguments(Args) ->
  case rabbit_misc:table_lookup(Args, ?RJMS_TYPE_INFO_ARG) of
    {table, TypeInfoTable} -> TypeInfoTable;
    _                      -> [] %% not supplied or wrong type => ignored
  end.
%% The rjms_type_info value has a slightly klunky format,
%% due to the neccesity of transmitting this over the AMQP protocol.
%%
%% In general it is a table:
%%    type_info()   :: [ident_type()]
%% where
%%    ident_type()  ::   {ident(), 'longstr', scalar_type()}
%%                     | {ident(), 'array',   enum_type()  }
%%    ident()       :: binary()
%%    scalar_type() :: <<"string">> | <<"boolean">> | <<"number">>
%%    enum_type()   :: [{longstr, enum_value()}]
%%    enum_value()  :: binary()
%%
%% For example, the standard JMS type-info argument is supplied as:
%%   [ {<<"JMSType">>,          longstr, <<"string">>}
%%   , {<<"JMSCorrelationID">>, longstr, <<"string">>}
%%   , {<<"JMSMessageID">>,     longstr, <<"string">>}
%%   , {<<"JMSDeliveryMode">>,  array,
%%        [{longstr, <<"PERSISTENT">>}, {longstr, <<"NON_PERSISTENT">>}]}
%%   , {<<"JMSPriority">>,      longstr, <<"number">>}
%%   , {<<"JMSTimestamp">>,     longstr, <<"number">>}
%%   ]

get_selection_policy_from_arguments(Args) ->
  case rabbit_misc:table_lookup(Args, ?RJMS_POLICY_ARG) of
    {longstr, <<"jms-topic">>} -> jms_topic;
    {longstr, <<"jms-queue">>} -> jms_queue;
    _                          -> jms_topic  %% not supplied or wrong type => default
  end.
%% The rjms_selection_policy value is a 'longstr' value either:
%%    "jms-topic"   meaning topic selection policy, which sends the message to
%%                  any destination bound with a satisfied SQL selector expression;
%% or:
%%    "jms-queue"   meaning queue selection policy, which sends the message to
%%                  *one* of the destinations bound with a statisfied SQL selector,
%%                  if there is one, and to the base queue (bound with a binding key
%%                  equal to the destination resource name) otherwise.

% get Headers from message content
get_headers(Content) ->
  case (Content#content.properties)#'P_basic'.headers of
    undefined -> [];
    H         -> rabbit_misc:sort_field_table(H)
  end.

% generate the function that checks the message against the SQL expression
generate_binding_fun(SQL, TypeInfo) ->
  case compile_sql(SQL, TypeInfo) of
    error          -> error;
    CompiledSQLExp -> { ok,
                        fun(Headers) ->
                          sql_match(CompiledSQLExp, Headers)
                        end
                      }
  end.

get_sql_from_args(Args) ->
  case rabbit_misc:table_lookup(Args, ?RJMS_SELECTOR_ARG) of
    {longstr, BinSQL} -> binary_to_list(BinSQL);
    _                 -> ""  %% not found or wrong type
  end.

% scan and parse SQL expression
compile_sql(SQL, TypeInfo) ->
  case sjx_dialect:analyze(TypeInfo, SQL) of
    error    -> error;
    Compiled -> Compiled
  end.

% Evaluate the SQL parsed tree and check against the Headers
sql_match(SQL, Headers) ->
  case sjx_evaluator:evaluate(SQL, Headers) of
    true -> true;
    _    -> false
  end.

% get policy and binding funs from state (using dirty_reads)
get_policy_and_binding_funs_x(XName) ->
  mnesia:async_dirty(
    fun() ->
      #?JMS_TOPIC_RECORD{x_selection_policy = XPol, x_selector_funs = BindingFuns} = read_state(XName),
      {XPol, BindingFuns}
    end,
    []
  ).

add_initial_record(XName, XPol) ->
  write_state_fun(XName, dict:new(), XPol).

% add binding fun to binding fun dictionary
add_binding_fun(XName, BindingKeyAndFun) ->
  #?JMS_TOPIC_RECORD{x_selection_policy = XPol, x_selector_funs = BindingFuns} = read_state_for_update(XName),
  write_state_fun(XName, put_item(BindingFuns, BindingKeyAndFun), XPol).

% remove binding funs from binding fun dictionary
remove_binding_funs(XName, Bindings) ->
  BindingKeys = [ {BindingKey, DestName} || #binding{key = BindingKey, destination = DestName} <- Bindings ],
  #?JMS_TOPIC_RECORD{x_selection_policy = XPol, x_selector_funs = BindingFuns} = read_state_for_update(XName),
  write_state_fun(XName, remove_items(BindingFuns, BindingKeys), XPol).

% add an item to the dictionary of binding functions
put_item(Dict, {Key, Item}) -> dict:store(Key, Item, Dict).

% remove a list of keyed items from the dictionary, by key
remove_items(Dict, []) -> Dict;
remove_items(Dict, [Key | Keys]) -> remove_items(dict:erase(Key, Dict), Keys).

% delete all the state saved for this exchange
delete_state(XName) ->
  mnesia:delete(?JMS_TOPIC_TABLE, XName, write).

% Basic read for update
read_state_for_update(XName) -> read_state(XName, write).

% Basic read
read_state(XName) -> read_state(XName, read).

% Lockable read
read_state(XName, Lock) ->
  case mnesia:read(?JMS_TOPIC_TABLE, XName, Lock) of
    [Rec] -> Rec;
    _     -> exchange_state_corrupt_error(XName)
  end.

% Basic write
write_state_fun(XName, BFuns, XPol) ->
  mnesia:write( ?JMS_TOPIC_TABLE
              , #?JMS_TOPIC_RECORD{x_name = XName, x_selection_policy = XPol, x_selector_funs = BFuns}
              , write ).

%%----------------------------------------------------------------------------
%% E R R O R S

% state error
exchange_state_corrupt_error(#resource{name = XName}) ->
  rabbit_misc:protocol_error( internal_error
                            , "exchange named '~s' has no saved state or incorrect saved state"
                            , [XName] ).

% parsing error
parsing_error(#resource{name = XName}, S, #resource{name = DestName}) ->
  rabbit_misc:protocol_error( precondition_failed
                            , "cannot parse selector '~s' binding destination '~s' to exchange '~s'"
                            , [S, DestName, XName] ).

%%----------------------------------------------------------------------------
