-module(n2o_bert).
-include("n2o.hrl").
-export([format/1]).

format(#ftp{}=FTP) -> term_to_binary(setelement(1,FTP,ftpack));
format(Term)       -> term_to_binary(Term).

