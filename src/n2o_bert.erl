-module(n2o_bert).
-include("n2o.hrl").
-export([format/1]).

format(#ftp{}=FTP) -> {binary,term_to_binary(setelement(1,FTP,ftpack))};
format(Term)       -> {binary,term_to_binary(Term)}.

