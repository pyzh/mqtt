-module(n2o).
-description('N2O Protocol Server for MQTT').
-author('Maxim Sokhatsky').
-license('ISC').
-behaviour(supervisor).
-behaviour(application).
-include("n2o.hrl").
-include("emqttd.hrl").
-compile(export_all).
-export([start/2, stop/1, init/1, proc/2]).

%% N2O-MQTT Topic Format
%%
%% Client: 1. actions/:vsn/:module/:client
%% Server: 2. events/:vsn/:node/:module/:user/:client/:token

load(Env) ->
    emqttd:hook('client.connected',    fun ?MODULE:on_client_connected/3,     [Env]),
    emqttd:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3,  [Env]),
    emqttd:hook('client.subscribe',    fun ?MODULE:on_client_subscribe/4,     [Env]),
    emqttd:hook('client.unsubscribe',  fun ?MODULE:on_client_unsubscribe/4,   [Env]),
    emqttd:hook('session.created',     fun ?MODULE:on_session_created/3,      [Env]),
    emqttd:hook('session.subscribed',  fun ?MODULE:on_session_subscribed/4,   [Env]),
    emqttd:hook('session.unsubscribed',fun ?MODULE:on_session_unsubscribed/4, [Env]),
    emqttd:hook('session.terminated',  fun ?MODULE:on_session_terminated/4,   [Env]),
    emqttd:hook('message.publish',     fun ?MODULE:on_message_publish/2,      [Env]),
    emqttd:hook('message.delivered',   fun ?MODULE:on_message_delivered/4,    [Env]),
    emqttd:hook('message.acked',       fun ?MODULE:on_message_acked/4,        [Env]).

stop(_)    -> unload(), ok.
start(_,_) -> catch load([]), X = supervisor:start_link({local,n2o},n2o, []),
              n2o_async:start(#handler{module=?MODULE,class=caching,group=n2o,state=[],name="timer"}),
              [ n2o_async:start(#handler{module=n2o_vnode,class=ring,group=n2o,state=[],name=Pos})
                || {{Name,Nodes},Pos} <- lists:zip(ring(),lists:seq(1,length(ring()))) ],
                X.
ring()     -> n2o_ring:ring_list().
ring_max() -> length(ring()).
rand_vnode() -> rand:uniform(ring_max()).

init([])   -> storage_init(),
              n2o_ring:init([{node(),1,4}]),
              { ok, { { one_for_one, 1000, 10 }, [] } }.

% MQTT vs OTP benchmarks

bench() -> [bench_mqtt(),bench_otp()].
run()   -> 10000.

bench_mqtt() -> N = run(), {T,_} = timer:tc(fun() -> [ begin Y = nitro:to_list(X rem 16), 
    n2o:send_reply(<<"clientId">>,iolist_to_binary(["events/1/",Y]),term_to_binary(X))
                               end || X <- lists:seq(1,N) ], ok end),
           {mqtt,trunc(N*1000000/T),"msgs/s"}.

bench_otp() -> N = run(), {T,_} = timer:tc(fun() ->
     [ n2o_ring:send({publish, nitro:to_binary("events/1/" ++ nitro:to_list((X rem length(n2o:ring())) + 1) ++
                 "/index/anon/room/"), term_to_binary(X)})
                || X <- lists:seq(1,N) ], ok end),
           {otp,trunc(N*1000000/T),"msgs/s"}.

on_client_connected(ConnAck, Client=#mqtt_client{client_id= <<"emqttc",_/bytes>>}, _) ->
   {ok, Client};

on_client_connected(ConnAck, Client = #mqtt_client{client_id  = ClientId,
                                                   client_pid = ClientPid,
                                                   username   = Username}, Env) ->
    {ok, Client}.

on_client_disconnected(Reason, _Client = #mqtt_client{client_id = ClientId}, _Env) ->
%    io:format("client ~s disconnected, reason: ~w\r~n", [ClientId, Reason]),
    ok.

on_client_subscribe(ClientId, _Username, TopicTable, _Env) ->
%    io:format("client subscribed ~p.\r~n", [TopicTable]),
    {ok, TopicTable}.

on_client_unsubscribe(ClientId, _Username, TopicTable, _Env) ->
%    io:format("client ~p unsubscribe ~p.\r~n", [ClientId, TopicTable]),
    {ok, TopicTable}.

on_session_created(ClientId, _Username, _Env) ->
%    io:format("session ~p created.\r~n", [ClientId]),
    ok.


on_session_subscribed(<<"emqttd",_/binary>> = ClientId,
    Username, {<<"actions/",Vsn, "/",_/binary>> = Topic, Opts}, _Env) ->
%    io:format("session ~p subscribed: ~p.\r~n", [ClientId, Topic]),
%    {ring,VNode} = n2o_ring:lookup(ClientId),
%    n2o_ring:send({publish,
%        iolist_to_binary(["events/",Vsn,"/",integer_to_list(VNode, 10),"/",Username,"/anon/",ClientId,"/"]),
%        term_to_binary({vnode_max, ring_max()})}),
    {ok, {Topic, Opts}};


on_session_subscribed(ClientId, _Username, {Topic, Opts}, _Env) ->
%    io:format("session ~p subscribed: ~p.\r~n", [ClientId, Topic]),
    {ok, {Topic, Opts}}.

on_session_unsubscribed(ClientId, _Username, {Topic, Opts}, _Env) ->
%    io:format("session ~p unsubscribed: ~p.\r~n", [ClientId, {Topic, Opts}]),
    ok.

on_session_terminated(ClientId, _Username, _Reason, _Env) ->
%    io:format("session ~p terminated.\r~n", [{ClientId,_Reason}]),
    ok.

on_message_publish(Message = #mqtt_message{topic = <<"actions/",
                   _/binary>>,
                   from=From}, _Env) ->
    {ok, Message};

on_message_publish(#mqtt_message{topic = <<"events/",Vsn,"//",RestTopic/binary>>, qos=Qos,
                   from={ClientId,_},payload = Payload}, _Env) ->
    emqttd:publish(emqttd_message:make(ClientId, Qos,
        iolist_to_binary(["events/",Vsn,"/",get_vnode(ClientId),"/",RestTopic]), Payload)),
    stop;

on_message_publish(Message = #mqtt_message{topic = <<"events/",
                   _RestTopic/binary>>,
                   from={ClientId,_Undefined},
                   payload = Payload}, _Env) ->
    {ok, Message};

on_message_publish(Message, _) ->
    {ok,Message}.

on_message_delivered(ClientId, _Username, Message, _Env) ->
    {ok,Message}.

on_message_acked(ClientId, _Username, Message, _Env) ->
%    io:format("client ~p acked.\r~n",[ClientId]),
    {ok,Message}.

unload() ->
    emqttd:unhook('client.connected',     fun ?MODULE:on_client_connected/3),
    emqttd:unhook('client.disconnected',  fun ?MODULE:on_client_disconnected/3),
    emqttd:unhook('client.subscribe',     fun ?MODULE:on_client_subscribe/4),
    emqttd:unhook('client.unsubscribe',   fun ?MODULE:on_client_unsubscribe/4),
    emqttd:unhook('session.subscribed',   fun ?MODULE:on_session_subscribed/4),
    emqttd:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
    emqttd:unhook('message.publish',      fun ?MODULE:on_message_publish/2),
    emqttd:unhook('message.delivered',    fun ?MODULE:on_message_delivered/4),
    emqttd:unhook('message.acked',        fun ?MODULE:on_message_acked/4).

send_reply(ClientId, Topic, Message) -> send_reply(ClientId, 0, Topic, Message).
send_reply(ClientId, QoS, Topic, Message) ->
    emqttd:publish(emqttd_message:make(ClientId, QoS, Topic, Message)).

send(X,Y) -> gproc:send({p,l,X},Y).
reg(Pool) -> reg(Pool,undefined).
reg(X,Y) ->
    case cache(caching,{pool,X}) of
         undefined -> gproc:reg({p,l,X},Y), cache(caching,{pool,X},X);
                 _ -> skip end.

% Pickling n2o:pickle/1

-ifndef(PICKLER).
-define(PICKLER, (application:get_env(n2o,pickler,n2o_secret))).
-endif.

pickle(Data) -> ?PICKLER:pickle(Data).
depickle(SerializedData) -> ?PICKLER:depickle(SerializedData).

% Error handler n2o:error/2 n2o:stack/2

-ifndef(ERRORING).
-define(ERRORING, (application:get_env(n2o,erroring,n2o))).
-endif.

stack(Error, Reason) -> ?ERRORING:stack_trace(Error, Reason).
erroring(Class, Error) -> ?ERRORING:error_page(Class, Error).

% Formatter

format(Term) -> format(Term,application:get_env(n2o,formatter,bert)).
format(Message, Formatter) -> n2o_format:format(Message, Formatter).

% Cache facilities n2o:cache/[1,2,3]

proc(init,#handler{}=Async) ->
    io:format("Proc Init: ~p\r~n",[init]),
    Timer = timer_restart(ping()),
    {ok,Async#handler{state=Timer}};

proc({timer,ping},#handler{state=Timer}=Async) ->
    erlang:cancel_timer(Timer),
    io:format("n2o Timer: ~p\r~n",[ping]),
    n2o:invalidate_cache(caching),
    {reply,ok,Async#handler{state=timer_restart(ping())}}.

timer_restart(Diff) -> {X,Y,Z} = Diff, erlang:send_after(1000*(Z+60*Y+60*60*X),self(),{timer,ping}).
ping() -> application:get_env(n2o,timer,{0,1,0}).

invalidate_cache(Table) -> ets:foldl(fun(X,_) -> n2o:cache(Table,element(1,X)) end, 0, Table).

ttl() -> application:get_env(n2o,ttl,60*1).
till(Now,TTL) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(Now) + TTL), infinity.

-ifndef(CACHING).
-define(CACHING, (application:get_env(n2o,caching,n2o))).
-endif.

opt()      -> [ set, named_table, { keypos, 1 }, public ].
tables()   -> [ cookies, file, caching, ring, async ].
storage_init()   -> [ ets:new(X,opt()) || X <- tables() ].
cache(Tab, Key, undefined)   -> ets:delete(Tab,Key);
cache(Tab, Key, Value)       -> ets:insert(Tab,{Key,till(calendar:local_time(), ttl()),Value}), Value.
cache(Tab, Key, Value, Till) -> ets:insert(Tab,{Key,Till,Value}), Value.
cache(Tab, Key) ->
    Res = ets:lookup(Tab,Key),
    Val = case Res of [] -> []; [Value] -> Value; Values -> Values end,
    case Val of [] -> [];
                {_,infinity,X} -> X;
                {_,Expire,X} -> case Expire < calendar:local_time() of
                                  true ->  ets:delete(Tab,Key), [];
                                  false -> X end end.

% Context Variables and URL Query Strings from ?REQ and ?CTX n2o:q/1 n2o:qc/[1,2]

q(Key) -> Val = get(Key), case Val of undefined -> qc(Key); A -> A end.
qc(Key) -> CX = get(context), qc(Key,CX).
qc(Key,Ctx) -> proplists:get_value(iolist_to_binary(Key),Ctx#cx.params).

atom(List) when is_list(List) -> list_to_atom(string:join([ lists:concat([L]) || L <- List],"_"));
atom(Scalar) -> list_to_atom(lists:concat([Scalar])).

% These api are not really API

temp_id() -> "auto" ++ integer_to_list(erlang:unique_integer() rem 1000000).
append(List, Key, Value) -> case Value of undefined -> List; _A -> [{Key, Value}|List] end.
render(X) -> wf_render:render(X).

version() -> proplists:get_value(vsn,element(2,application:get_all_key(n2o))).

keyset(Name,Pos,List,New) ->
    case lists:keyfind(Name,Pos,List) of
        false -> [New|List];
        _Element -> lists:keyreplace(Name,Pos,List,New) end.

actions() -> get(actions).
actions(Ac) -> put(actions,Ac).

clear_actions() -> put(actions,[]).
add_action(Action) ->
    Actions = case get(actions) of undefined -> []; E -> E end,
    put(actions,Actions++[Action]).

fold(Fun,Handlers,Ctx) ->
    lists:foldl(fun({_,Module},Ctx1) ->
        {ok,_,NewCtx} = Module:Fun([],Ctx1),
        NewCtx end,Ctx,Handlers).

stack_trace(Error, Reason) ->
    Stacktrace = [case A of
         { Module,Function,Arity,Location} ->
             { Module,Function,Arity,proplists:get_value(line, Location) };
         Else -> Else end
    || A <- erlang:get_stacktrace()],
    [Error, Reason, Stacktrace].

error_page(Class,Error) ->
    io_lib:format("ERROR:  ~w:~w\r~n\r~n",[Class,Error]) ++
    "STACK: " ++
    [ io_lib:format("\t~w:~w/~w:~w\n",
        [ Module,Function,Arity,proplists:get_value(line, Location) ])
    ||  { Module,Function,Arity,Location} <- erlang:get_stacktrace() ].


-ifndef(SESSION).
-define(SESSION, n2o_session).
-endif.

session(Key)        -> #cx{session=SID}=get(context), ?SESSION:get_value(SID, Key, []).
session(Key, Value) -> #cx{session=SID}=get(context), ?SESSION:set_value(SID, Key, Value).
user()              -> case session(user) of undefined -> []; E -> nitro:to_list(E) end.
user(User)          -> session(user,User).

subscribe(X,Y) -> subscribe_cli(X,Y).
unsubscribe(X,Y) -> unsubscribe_cli(X,Y).

subscribe_cli(ClientId, TopicTable) ->
    [ begin
        kvs:put({mqtt_subscription, ClientId, Topic}),
        kvs:put({mqtt_subproperty, {Topic, ClientId}, [{qos,Qos}]}),
        emqttd_pubsub:add_subscriber(Topic,ClientId,[{qos,Qos}])
      end || {Topic,Qos} <- TopicTable ].

unsubscribe_cli(ClientId, TopicTable) ->
    [ begin
        emqttd_pubsub:del_subscriber(Topic,ClientId,[{qos,Qos}])
      end || {Topic,Qos} <- TopicTable ].

get_vnode(ClientId) ->
    [H|_] = binary_to_list(erlang:md5(ClientId)),
    integer_to_binary(H rem ring_max() + 1).

% Tiny Logging Framework

-define(LOGGER, n2o_io).

log_modules() -> [?MODULE].
log_level() -> info.

-define(LOG_MODULES, (application:get_env(n2o,log_modules,n2o))).
-define(LOG_LEVEL,   (application:get_env(n2o,log_level,n2o))).

log_level(none) -> 3;
log_level(error) -> 2;
log_level(warning) -> 1;
log_level(_) -> 0.

log(Module, String, Args, Fun) ->
    case log_level(Fun) < log_level(?LOG_LEVEL:log_level()) of
        true -> skip;
        false -> case ?LOG_MODULES:log_modules() of
            any -> ?LOGGER:Fun(Module, String, Args);
            Allowed -> case lists:member(Module, Allowed) of
                true -> ?LOGGER:Fun(Module, String, Args);
                false -> skip end end end.

info(Module, String, Args) -> log(Module,  String, Args, info).
info(        String, Args) -> log(?MODULE, String, Args, info).
info(        String      ) -> log(?MODULE, String, [],   info).

warning(Module, String, Args) -> log(Module,  String, Args, warning).
warning(        String, Args) -> log(?MODULE, String, Args, warning).
warning(        String      ) -> log(?MODULE, String, [],   warning).

error(Module, String, Args) -> log(Module,  String, Args, error).
error(        String, Args) -> log(?MODULE, String, Args, error).
error(        String)       -> log(?MODULE, String, [],   error).

