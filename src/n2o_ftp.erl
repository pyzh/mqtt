-module(n2o_ftp).
-description('N2O File Protocol: FTP').
-license('ISC').
-author('Andrii Zadorozhnii').
-include("n2o.hrl").
-include_lib("kernel/include/file.hrl").
-compile(export_all).

-define(ROOT, application:get_env(n2o,upload,code:priv_dir(n2o))).
-define(NEXT, 256*1024). % 256K chunks for best 25MB/s speed
-define(STOP, 0).

% Callbacks

filename(#ftp{sid=Sid,filename=FileName}) -> filename:join(n2o:to_list(Sid),FileName).

% File Transfer Protocol

info(#ftp{status={event,_}}=FTP, Req, State) ->
    n2o:info(?MODULE,"Event Message: ~p",[FTP#ftp{data= <<>>}]),
    Module=State#cx.module,
    Reply=try Module:event(FTP)
          catch E:R -> Error=n2o:stack(E,R), n2o:error(?MODULE,"Catch: ~p:~p~n~p",Error), Error end,
    {reply,n2o:format({io,neo_nitrogen:render_actions(n2o:actions()),Reply}),
           Req,State};

info(#ftp{id=Link,status= <<"init">>,block=Block,offset=Offset}=FTP,Req,State) ->
    Root=?ROOT,
    RelPath=(application:get_env(n2o,filename,n2o_ftp)):filename(FTP),
    FilePath=filename:join(Root,RelPath),
    ok=filelib:ensure_dir(FilePath),
    FileSize=case file:read_file_info(FilePath) of {ok,Fi} -> Fi#file_info.size; {error,_} -> 0 end,

    n2o:info(?MODULE,"Info Init: ~p Offset: ~p Block: ~p~n",[FilePath,FileSize,Block]),

    Block2=case Block of 0 -> ?STOP; _ -> ?NEXT end,
    Offset2=case FileSize >= Offset of true -> FileSize; false -> 0 end,
    FTP2=FTP#ftp{block=Block2,offset=Offset2,filename=RelPath,data= <<>>},

    n2o_async:stop(file,Link),
    n2o_async:start(#handler{module=?MODULE,class=file,group=neo,state=FTP2,name=Link}),

    {reply,n2o:format(FTP2),Req,State};

info(#ftp{id=Link,status= <<"send">>}=FTP,Req,State) ->
    n2o:info(?MODULE,"Info Send: ~p",[FTP#ftp{data= <<>>}]),
    Reply=try gen_server:call(n2o_async:pid({file,Link}),FTP)
        catch _:_ -> n2o:error(?MODULE,"Info Error call the sync: ~p~n",[FTP#ftp{data= <<>>}]),
            FTP#ftp{data= <<>>,block=?STOP} end,
    n2o:info(?MODULE,"reply ~p",[Reply#ftp{data= <<>>}]),
    {reply,n2o:format(Reply),Req,State};

info(#ftp{status= <<"recv">>}=FTP,Req,State) -> {reply,n2o:format(FTP),Req,State};

info(#ftp{status= <<"relay">>}=FTP,Req,State) -> {reply,n2o:format(FTP),Req, State};

info(Message,Req,State) -> n2o:info(?MODULE, "Info Unknown message: ~p",[Message]),
    {unknown,Message,Req,State}.

% neo Handlers

proc(init,#handler{state=#ftp{sid=Sid}=FTP}=Async) ->
    n2o:info(?MODULE,"Proc Init: ~p",[FTP#ftp{data= <<>>}]),
    n2o:send(Sid,FTP#ftp{data= <<>>,status={event,init}}),
    {ok,Async};

proc(#ftp{id=Link,sid=Sid,data=Data,status= <<"send">>,block=Block}=FTP,
     #handler{state=#ftp{size=TotalSize,offset=Offset,filename=RelPath}}=Async) when Offset+Block >= TotalSize ->
        n2o:info(?MODULE,"Proc Stop ~p, last piece size: ~p", [FTP#ftp{data= <<>>},byte_size(Data)]),
        case file:write_file(filename:join(?ROOT,RelPath),<<Data/binary>>,[append,raw]) of
                {error,Reason} -> {reply,{error,Reason},Async};
                ok ->
            FTP2=FTP#ftp{data= <<>>,block=?STOP},
            n2o:send(Sid,FTP2#ftp{status={event,stop},filename=RelPath}),
                        spawn(fun() -> n2o_async:stop(file,Link) end),
                        {stop,normal,FTP2,Async#handler{state=FTP2}} end;

proc(#ftp{data=Data,block=Block}=FTP,
     #handler{state=#ftp{offset=Offset,filename=RelPath}}=Async) ->
    FTP2=FTP#ftp{status= <<"send">>,offset=Offset+Block },
    n2o:info(?MODULE,"Proc Process ~p",[FTP2#ftp{data= <<>>}]),
    case file:write_file(filename:join(?ROOT,RelPath),<<Data/binary>>,[append,raw]) of
        {error,Reason} -> {reply,{error,Reason},Async};
        ok -> {reply,FTP2#ftp{data= <<>>},Async#handler{state=FTP2#ftp{filename=RelPath}}} end.
