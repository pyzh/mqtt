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
% MQTT section
-export([load/1, unload/0]).
-export([on_client_connected/3,     on_client_disconnected/3, on_client_subscribe/4,
         on_client_unsubscribe/4,   on_session_created/3,     on_session_subscribed/4,
         on_session_unsubscribed/4, on_session_terminated/4,  on_message_publish/2,
         on_message_delivered/4,    on_message_acked/4]).
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

tables()   -> [ cookies, caching ].
opt()      -> [ set, named_table, { keypos, 1 }, public ].
stop(_)    -> unload(), ok.
start(_,_) -> load([]), X = supervisor:start_link({local,n2o},n2o, []),
              n2o_async:start(#handler{module=?MODULE,class=system,group=n2o,state=[],name="timer"}),
              X.
init([])   -> [ ets:new(T,opt()) || T <- tables() ],
              { ok, { { one_for_one, 5, 10 }, [] } }.

on_client_connected(ConnAck, Client = #mqtt_client{client_id = ClientId}, _Env) ->
    io:format("client ~s connected, connack: ~w~n", [ClientId, ConnAck]),
    {ok, Client}.

on_client_disconnected(Reason, _Client = #mqtt_client{client_id = ClientId}, _Env) ->
    io:format("client ~s disconnected, reason: ~w~n", [ClientId, Reason]),
    ok.

select(Topic) -> {SelectModule,Function} = application:get_env(n2o,select,{n2o,select}),
    [Module,Room] = case string:tokens(binary_to_list(iolist_to_binary(Topic)),"_") of
         [M,R] -> [M,R];
           [A] -> ["index",A];
            [] -> ["index","lobby"] end, SelectModule:Function(Module,Room).

select(Module,Room) -> [list_to_atom(Module),Room].

on_client_subscribe(ClientId, Username, TopicTable, _Env) ->
    io:format("client(~s/~s) will subscribe: ~p~n", [Username, ClientId, TopicTable]),
    Name = binary_to_list(iolist_to_binary(ClientId)),
    BinTopic = element(1,hd(TopicTable)),
    put(topic,BinTopic),
    [Module,Room] = select(BinTopic),
    n2o:context(#cx{module=Module,formatter=bert,params=[]}),
    case n2o_proto:info({init,<<>>},[],?CTX) of
         {reply, {binary, M}, _, #cx{}} ->
             Msg = emqttd_message:make(Name, 0, Name, M),
             io:format("N2O ~p~n Message: ~p Pid: ~p~n",[ClientId, binary_to_term(M), self()]),
             self() ! {deliver, Msg};
         _ -> skip end,
    {ok, TopicTable}.

on_client_unsubscribe(ClientId, Username, TopicTable, _Env) ->
    io:format("client(~s/~s) unsubscribe ~p~n", [ClientId, Username, TopicTable]),
    {ok, TopicTable}.

on_session_created(ClientId, Username, _Env) ->
    io:format("session(~s/~s) created.", [ClientId, Username]).

on_session_subscribed(_ClientId, Username, {Topic, Opts}, _Env) ->
    io:format("session(~s/~p) subscribed: ~p~n", [Username, self(), {Topic, Opts}]),
    {ok, {Topic, Opts}}.

on_session_unsubscribed(ClientId, Username, {Topic, Opts}, _Env) ->
    io:format("session(~s/~s) unsubscribed: ~p~n", [Username, ClientId, {Topic, Opts}]),
    ok.

on_session_terminated(ClientId, Username, Reason, _Env) ->
    io:format("session(~s/~s) terminated: ~p.", [ClientId, Username, Reason]).

on_message_publish(Message = #mqtt_message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message = #mqtt_message{topic = _Topic, from = {_ClientId,_}, payload = Payload}, _Env) ->
    io:format("publish ~p bytes~n", [size(Payload)]),
    {ok, Message}.

on_message_delivered(ClientId, _Username, Message = #mqtt_message{topic = _Topic, payload = Payload}, _Env) ->
    io:format("DELIVER to client(~p): ~p~n", [ClientId, self()]),
    {ok,Message#mqtt_message{payload = <<>>}}.
    % Name = binary_to_list(ClientId),
    % case n2o_proto:info(binary_to_term(Payload),[],?CTX) of
    %     {reply, {binary, M}, _R, #cx{}} ->
    %         % io:format("on_message_delivered BINARY ~p~n Message: ~p Pid: ~p~n",[ClientId, binary_to_term(M), self()]),
    %         case binary_to_term(M) of
    %             #ftp{status= <<"init">>} ->
    %                 io:format("on_message_delivered FTP ~p  Pid: ~p~n",[ftp, self()]),
    %                 Msg = emqttd_message:make(Name, 0, Name, M),
    %                 self() ! {deliver, Msg},
    %                 {ok, Message#mqtt_message{payload= <<>>}};
    %             % {io,<<>>,<<>>} -> {ok,Message};
    %             {io,X,X2} ->
    %                 io:format("on_message_delivered IO ~p ~p Pid: ~p~n",[X, X2, self()]),
    %                 Msg = emqttd_message:make(Name, 0, Name, M),
    %                 % io:format("IO ~p~n Message: ~p Pid: ~p~n",[ClientId, X, self()]),
    %                 self() ! {deliver, Msg},
    %                 {ok, M};
    %             {binary,FTP} ->
    %                 io:format("on_message_delivered FTP-X ~p  Pid: ~p~n",[FTP, self()]),
    %                 Msg = emqttd_message:make(Name, 0, Name, FTP),
    %                 self() ! {deliver, Msg},
    %                 {ok, Message#mqtt_message{payload= <<>>}};
    %             Q ->
    %                 io:format("on_message_delivered UNKNOWN ~p  Pid: ~p~n",[Q, self()]),
    %                 {ok, Message}
    %         end;
    %     W ->
    %         io:format("on_message_delivered NO_REPLY ~p  Pid: ~p~n",[W, self()]),
    %         {ok, Message}
    % end.

on_message_acked(ClientId, Username, #mqtt_message{topic = _Topic, payload = Payload}=Message, _Env) ->
    io:format("client(~s/~s) acked: ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    % {ok, Message}.
    
    Name = binary_to_list(ClientId),
    case n2o_proto:info(binary_to_term(Payload),[],?CTX) of
        {reply, {binary, M}, _R, #cx{}} ->
            % io:format("on_message_delivered BINARY ~p~n Message: ~p Pid: ~p~n",[ClientId, binary_to_term(M), self()]),
            case binary_to_term(M) of
                #ftp{status= <<"init">>} ->
                    io:format("on_message_delivered FTP ~p  Pid: ~p~n",[ftp, self()]),
                    Msg = emqttd_message:make(Name, 0, Name, M),
                    self() ! {deliver, Msg},
                    {ok, Message#mqtt_message{payload= <<>>}};
                % {io,<<>>,<<>>} -> {ok,Message};
                {io,X,X2} ->
                    io:format("on_message_delivered IO ~p ~p Pid: ~p~n",[X, X2, self()]),
                    Msg = emqttd_message:make(Name, 0, Name, M),
                    % io:format("IO ~p~n Message: ~p Pid: ~p~n",[ClientId, X, self()]),
                    self() ! {deliver, Msg},
                    {ok, M};
                {binary,FTP} ->
                    io:format("on_message_delivered FTP-X ~p  Pid: ~p~n",[FTP, self()]),
                    Msg = emqttd_message:make(Name, 0, Name, FTP),
                    self() ! {deliver, Msg},
                    {ok, Message#mqtt_message{payload= <<>>}};
                Q ->
                    io:format("on_message_delivered UNKNOWN ~p  Pid: ~p~n",[Q, self()]),
                    {ok, Message}
            end;
        W ->
            io:format("on_message_delivered NO_REPLY ~p  Pid: ~p~n",[W, self()]),
            {ok, Message}
    end.

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
error(Class, Error) -> ?ERRORING:error_page(Class, Error).

% Formatter

format(Term) -> format(Term,?CTX#cx.formatter).
format(Message, Formatter) -> n2o_format:format(Message, Formatter).

% Cache facilities n2o:cache/[1,2,3]

proc(init,#handler{}=Async) ->
    io:format("Proc Init: ~p~n",[init]),
    Timer = timer_restart(ping()),
    {ok,Async#handler{state=Timer}};

proc({timer,ping},#handler{state=Timer}=Async) ->
    case Timer of undefined -> skip; _ -> erlang:cancel_timer(Timer) end,
    io:format("n2o Timer: ~p~n",[ping]),
    n2o:invalidate_cache(),
    {reply,ok,Async#handler{state=timer_restart(ping())}}.

timer_restart(Diff) -> {X,Y,Z} = Diff, erlang:send_after(1000*(Z+60*Y+60*60*X),self(),{timer,ping}).
ping() -> application:get_env(n2o,timer,{0,10,0}).

invalidate_cache() -> ets:foldl(fun(X,_) -> n2o:cache(element(1,X)) end, 0, caching).

ttl() -> application:get_env(n2o,ttl,60*15).
till(Now,TTL) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(Now) + TTL).

cache(Key, undefined) -> ets:delete(caching,Key);
cache(Key, Value) -> ets:insert(caching,{Key,till(calendar:local_time(), ttl()),Value}), Value.
cache(Key, Value, Till) -> ets:insert(caching,{Key,Till,Value}), Value.
cache(Key) ->
    Res = ets:lookup(caching,Key),
    Val = case Res of [] -> undefined; [Value] -> Value; Values -> Values end,
    case Val of undefined -> undefined;
                {_,infinity,X} -> X;
                {_,Expire,X} -> case Expire < calendar:local_time() of
                                  true ->  ets:delete(caching,Key), undefined;
                                  false -> X end end.

% Context Variables and URL Query Strings from ?REQ and ?CTX n2o:q/1 n2o:qc/[1,2]

q(Key) -> Val = get(Key), case Val of undefined -> qc(Key); A -> A end.
qc(Key) -> qc(Key,?CTX).
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

context() -> get(context).
context(Cx) -> put(context,Cx).
context(Cx,Proto) -> lists:keyfind(Proto,1,Cx#cx.state).
context(Cx,Proto,UserCx) ->
   NewCx = Cx#cx{state=n2o:keyset(Proto,1,Cx#cx.state,{Proto,UserCx})},
   n2o:context(NewCx),
   NewCx.

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
    io_lib:format("ERROR:  ~w:~w~n~n",[Class,Error]) ++
    "STACK: " ++
    [ io_lib:format("\t~w:~w/~w:~w\n",
        [ Module,Function,Arity,proplists:get_value(line, Location) ])
    ||  { Module,Function,Arity,Location} <- erlang:get_stacktrace() ].

user() -> case session(<<"user">>) of undefined -> []; E -> nitro:to_list(E) end.
user(User) -> session(<<"user">>,User).

-ifndef(SESSION).
-define(SESSION, (application:get_env(n2o,session,n2o))).
-endif.

session(Key) -> ?SESSION:get_value(Key,undefined).
session(Key, Value) -> ?SESSION:set_value(Key, Value).

set_value(Key, Value) -> erlang:put(Key,Value).
get_value(Key, DefaultValue) -> case erlang:get(Key) of
                                     undefined -> DefaultValue;
                                     Value -> Value end.
