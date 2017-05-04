-module(n2o_async).
-description('N2O Async Processes: Erlang/OTP gen_server backend').
-author('Maxim Sokhatsky').
-license('ISC').
-include("n2o.hrl").
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-compile(export_all).

% neo_async API

async(Fun) -> async(async,n2o:temp_id(),Fun).
async(Name, F) -> async(async,Name,F).
async(Class,Name,F) ->
    Key = key(),
    Handler = #handler{module=?MODULE,class=async,group=n2o,
                       name={Name,Key},config={F,?REQ(Key)},state=self()},
    case n2o_async:start(Handler) of
        {error,{already_started,P}} -> init(P,Class,{Name,Key}), {P,{Class,{Name,Key}}};
        {P,X} when is_pid(P)        -> init(P,Class,X),          {P,{Class,X}};
        Else -> Else end.

init(Pid,Class,Name) when is_pid(Pid) -> n2o:cache({Class,Name},Pid,infinity), send(Pid,{parent,self()}).
send(Pid,Message) when is_pid(Pid) -> gen_server:call(Pid,Message);
send(Name,Message) -> send(async,{Name,key()},Message).
send(Class,Name,Message) -> gen_server:call(n2o_async:pid({Class,Name}),Message).

pid({Class,Name}) -> n2o:cache({Class,Name}).
key() -> #cx{session=Key} = get(context), Key.

restart(Name) -> restart(async,{Name,key()}).
restart(Class,Name) ->
    case stop(Class,Name) of #handler{}=Async -> start(Async); Error -> Error end.

flush() -> A=n2o:actions(), n2o:actions([]), get(parent) ! {flush,A}.
flush(Pool) -> A=n2o:actions(), n2o:actions([]), n2o:send(Pool,{flush,A}).

stop(Name) -> stop(async,{Name,key()}).
stop(Class,Name) ->
    case n2o_async:pid({Class,Name}) of
        Pid when is_pid(Pid) ->
            #handler{group=Group} = Async = send(Pid,{get}),
            [ supervisor:F(Group,{Class,Name})||F<-[terminate_child,delete_child]],
            n2o:cache({Class,Name},undefined), Async;
        Data -> {error,{not_pid,Data}} end.

start(#handler{class=Class,name=Name,module=Module,group=Group} = Async) ->
    ChildSpec = {{Class,Name},{?MODULE,start_link,[Async]},transient,5000,worker,[Module]},
    io:format("Async Start Attempt ~p~n",[Async#handler{config=[]}]),
    case supervisor:start_child(Group,ChildSpec) of
         {ok,Pid}   -> {Pid,Async#handler.name};
         {ok,Pid,_} -> {Pid,Async#handler.name};
         Else     -> Else end.

init_context(undefined) -> [];
init_context(Req) ->
    Ctx = n2o:init_context(Req),
    NewCtx = n2o:fold(init, Ctx#cx.handlers, Ctx),
    n2o:actions(NewCtx#cx.actions),
    n2o:cache(crypto:sha(Req),NewCtx),
    NewCtx.

% Generic Async Server

init(#handler{module=Mod,class=Class,name=Name}=Handler) -> n2o:cache({Class,Name},self(),infinity), Mod:proc(init,Handler).
handle_call({get},_,Async)   -> {reply,Async,Async};
handle_call(Message,_,#handler{module=Mod}=Async) -> Mod:proc(Message,Async).
handle_cast(Message,  #handler{module=Mod}=Async) -> Mod:proc(Message,Async).
handle_info(timeout,  #handler{module=Mod}=Async) -> Mod:proc(timeout,Async);
handle_info(Message,  #handler{module=Mod}=Async) -> {noreply,element(3,Mod:proc(Message,Async))}.
start_link(Parameters) -> gen_server:start_link(?MODULE, Parameters, []).
code_change(_,State,_) -> {ok, State}.
terminate(_Reason, #handler{name=Name,group=Group,class=Class}) ->
    spawn(fun() -> supervisor:delete_child(Group,{Class,Name}) end),
    n2o:cache({Class,Name},undefined), ok.

% n2o:async page workers

proc(init,#handler{config={F,Req},state=Parent}=Async) -> put(parent,Parent), try F(init) catch _:_ -> skip end, init_context(Req), {ok,Async};
proc({parent,Parent},Async) -> {reply,put(parent,Parent),Async#handler{state=Parent}};
proc(Message,#handler{config={F,_}}=Async) -> {reply,F(Message),Async}.
