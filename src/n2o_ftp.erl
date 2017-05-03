-module(n2o_ftp).
-description('N2O File Protocol: FTP').
-license('ISC').
-author('Andrii Zadorozhnii').
-include("n2o.hrl").
-include_lib("kernel/include/file.hrl").
-compile(export_all).

-define(ROOT, application:get_env(n2o,upload,code:priv_dir(n2o))).
-define(NEXT, 25*1024). % 256K chunks for best 25MB/s speed
-define(STOP, 0).

% Callbacks

filename(#ftp{sid=Sid,filename=FileName}) -> filename:join(nitro:to_list(Sid),FileName).

% File Transfer Protocol

format(X) -> n2o:format(X,bert).

info(#ftp{status={event,_}}=FTP, Req, State) ->
    io:format("Event Message: ~p~n",[FTP#ftp{data= <<>>}]),
    Module=State#cx.module,
    Reply=try Module:event(FTP)
          catch E:R -> Error=n2o:stack(E,R),
                       io:format("Catch: ~p:~p~n~p~n",Error), Error end,
    {reply,format({io,n2o_nitro:render_actions(n2o:actions()),Reply}),
           Req,State};

info(#ftp{id=Link,status= <<"init">>,block=Block,offset=Offset}=FTP,Req,State) when Block =:= 1 ->
    Root=?ROOT,
    RelPath=(application:get_env(n2o,filename,n2o_ftp)):filename(FTP),
    FilePath=filename:join(Root,RelPath),
    ok=filelib:ensure_dir(FilePath),
    FileSize=case file:read_file_info(FilePath) of {ok,Fi} -> Fi#file_info.size; {error,_} -> 0 end,

    io:format("Info Init: ~p Offset: ~p Block: ~p~n",[FilePath,FileSize,Block]),

    Block2=case Block of 0 -> ?STOP; _ -> ?NEXT end,
    Offset2=case FileSize >= Offset of true -> FileSize; false -> 0 end,
    FTP2=FTP#ftp{block=Block2,offset=Offset2,filename=RelPath,data= <<>>},

    n2o_async:stop(file,Link),
    n2o_async:start(#handler{module=?MODULE,class=file,group=n2o,state=FTP2,name=Link}),

    io:format("Info Init FTP: ~p~n",[FTP]),
    io:format("Info Init FTP2: ~p~n",[FTP2]),
    
    {reply,format(FTP2),Req,State};

info(#ftp{id=Link,status= <<"send">>}=FTP,Req,State) ->
    io:format("Info Send: ~p~n",[FTP#ftp{data= <<>>}]),
    Reply=try gen_server:call(n2o_async:pid({file,Link}),FTP)
        catch _:_ -> io:format("Info Error call the sync: ~p~n",[FTP#ftp{data= <<>>}]),
            FTP#ftp{data= <<>>,block=?STOP} end,
    % io:format("Info reply ~p~n",[Reply#ftp{data= <<>>}]),
    {reply,format(Reply),Req,State};

info(#ftp{status= <<"recv">>}=FTP,Req,State) -> {reply,format(FTP),Req,State};

info(#ftp{status= <<"relay">>}=FTP,Req,State) -> {reply,format(FTP),Req, State};

info(Message,Req,State) -> {unknown,Message,Req,State}.

% n2o Handlers

% -include("emqttd.hrl").

% send(Pool, Message) -> gproc:send({p,l,Pool},Message).
% reg(Pool) -> reg(Pool,undefined).
% reg(Pool, Value) ->
%     case get({pool,Pool}) of
%          undefined -> gproc:reg({p,l,Pool},Value), put({pool,Pool},Pool);
%          _Defined -> skip end.
% unreg(Pool) ->
%     case get({pool,Pool}) of
%          undefined -> skip;
%          _Defined -> gproc:unreg({p,l,Pool}), erase({pool,Pool}) end.

proc(init,#handler{state=#ftp{sid=Sid}=FTP}=Async) ->
    io:format("Proc Init: ~p~n",[FTP#ftp{data= <<>>}]),
    % n2o:send(Sid,FTP#ftp{data= <<>>,status={event,init}}),
    % Msg = emqttd_message:make(Sid, 0, Sid, term_to_binary(FTP#ftp{data= <<>>,status={event,init}})),
    % self() ! {deliver, Msg},
        
    {ok,Async};
    
% proc({deliver,#mqtt_message{payload = Payload}=M}, #handler{}=H) ->
%     io:format("Proc deliver: ~p~n",[M]),
%     proc(binary_to_term(Payload), H);

proc(#ftp{id=Link,sid=Sid,data=Data,status= <<"send">>,block=Block}=FTP,
     #handler{state=#ftp{size=TotalSize,offset=Offset,filename=RelPath}}=Async) when Offset+Block >= TotalSize ->
        io:format("Proc Stop ~p, last piece size: ~p~n", [FTP#ftp{data= <<>>},byte_size(Data)]),
        case file:write_file(filename:join(?ROOT,RelPath),<<Data/binary>>,[append,raw]) of
            {error,Reason} -> {reply,{error,Reason},Async};
            ok ->
                FTP2=FTP#ftp{data= <<>>,block=?STOP},
                % n2o:send(Sid,FTP2#ftp{status={event,stop},filename=RelPath}),
                
                % Msg = emqttd_message:make(Sid, 0, Sid, term_to_binary(FTP2#ftp{status={event,stop},filename=RelPath})),
                % self() ! {deliver, Msg},
                
                spawn(fun() -> n2o_async:stop(file,Link) end),
                {stop,normal,FTP2,Async#handler{state=FTP2}} end;

proc(#ftp{data=Data,block=Block}=FTP,#handler{state=#ftp{offset=Offset,filename=RelPath}}=Async) ->
    FTP2=FTP#ftp{status= <<"send">>,offset=Offset+Block },
    X=file:write_file(filename:join(?ROOT,RelPath),<<Data/binary>>,[append,raw]),
    io:format("Proc Process WRITE ~p ~p ~p~n",[X,filename:join(?ROOT,RelPath),size(Data)]),
    io:format("Proc Process ~p ~p~n",[X,FTP2#ftp{data= <<>>}]),
    case X of
        {error,Reason} -> {reply,{error,Reason},Async};
        ok -> {reply,format(FTP2#ftp{data= <<>>}),Async#handler{state=FTP2#ftp{filename=RelPath}}} end.
