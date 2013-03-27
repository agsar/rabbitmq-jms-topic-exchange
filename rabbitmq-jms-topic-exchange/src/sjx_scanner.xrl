%% -----------------------------------------------------------------------------
%% Copyright (c) 2002-2012 Tim Watson (watson.timothy@gmail.com)
%% Copyright (c) 2012-2013 Steve Powell (Zteve.Powell@gmail.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -----------------------------------------------------------------------------
%% @doc this is the rule definitions file for the JMS Selector scanner.
%% -----------------------------------------------------------------------------
Definitions.

COMMA   = [,]
PARENS  = [\(\)]
L       = [A-Za-z_\$]
D       = [0-9]
F       = [-+]?[0-9]+\.[0-9]+([Ee][-+]?[0-9]+)?
F2      = [-+]?[0-9]+(\.([Ee][-+]?[0-9]+)?|[Ee][-+]?[0-9]+)
F3      = {D}+(f|F|d|D)
HEX     = 0x[0-9a-fA-F]+
WS      = ([\000-\s])
S       = ({COMMA}|{PARENS})
CMP     = (>=|<=|<>|[=><])
IDENT   = {L}({L}|{D})*
APLUS   = [-+]
AMULT   = [*/]
STRING  = '([^']|'')*'

%'
% COMMENT = /\*([^\*]|\*[^/])*\*/       % Do not (need to) support comments
% WS      = ([\000-\s]|%.*)             % Do not (need to) support line comments

% All keywords are case insensitive
LIKE    = [Ll][Ii][Kk][Ee]
NOT     = [Nn][Oo][Tt]
IN      = [Ii][Nn]
AND     = [Aa][Nn][Dd]
OR      = [Oo][Rr]
IS      = [Ii][Ss]
NULL    = [Nn][Uu][Ll][Ll]
BETWEEN = [Bb][Ee][Tt][Ww][Ee][Ee][Nn]
ESCAPE  = [Ee][Ss][Cc][Aa][Pp][Ee]
TRUE    = [Tt][Rr][Uu][Ee]
FALSE   = [Ff][Aa][Ll][Ss][Ee]

Rules.

{LIKE}                  : {token, {op_like,             TokenLine, like}}.
{NOT}{WS}{LIKE}         : {token, {op_like,             TokenLine, not_like}}.
{IN}                    : {token, {op_in,               TokenLine, in}}.
{NOT}{WS}{IN}           : {token, {op_in,               TokenLine, not_in}}.
{AND}                   : {token, {op_and,              TokenLine, conjunction}}.
{OR}                    : {token, {op_or,               TokenLine, disjunction}}.
{NOT}                   : {token, {op_not,              TokenLine, negation}}.
{IS}{WS}{NULL}          : {token, {op_null,             TokenLine, is_null}}.
{IS}{WS}{NOT}{WS}{NULL} : {token, {op_null,             TokenLine, not_null}}.
{BETWEEN}               : {token, {op_between,          TokenLine, between}}.
{NOT}{WS}{BETWEEN}      : {token, {op_between,          TokenLine, not_between}}.
{ESCAPE}                : {token, {escape,              TokenLine, escape}}.
{TRUE}                  : {token, {true,                TokenLine}}.
{FALSE}                 : {token, {false,               TokenLine}}.
{CMP}                   : {token, {op_cmp,              TokenLine, atomize(TokenChars)}}.
{APLUS}                 : {token, {op_plus,             TokenLine, atomize(TokenChars)}}.
{AMULT}                 : {token, {op_mult,             TokenLine, atomize(TokenChars)}}.
{IDENT}                 : {token, {ident,               TokenLine, TokenChars}}.
{STRING}                : {token, {lit_string,          TokenLine, stripquotes(TokenChars,TokenLen)}}.
{S}                     : {token, {atomize(TokenChars), TokenLine}}.
{F}                     : {token, {lit_flt,             TokenLine, list_to_float(TokenChars)}}.
{F2}                    : {token, {lit_flt,             TokenLine, to_float(TokenChars)}}.
{F3}                    : {token, {lit_flt,             TokenLine, to_float(TokenChars)}}.
{D}+                    : {token, {lit_int,             TokenLine, list_to_integer(TokenChars)}}.
{HEX}                   : {token, {lit_hex,             TokenLine, list_to_integer(lists:nthtail(2,TokenChars),16)}}.
{WS}+                   : skip_token.

% {COMMENT}               : skip_token.             % Do not (need to) support comments

Erlang code.
%% -----------------------------------------------------------------------------
%% Copyright (c) 2002-2012 Tim Watson (watson.timothy@gmail.com)
%% Copyright (c) 2012-2013 Steve Powell (Zteve.Powell@gmail.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -----------------------------------------------------------------------------
%%
%% NB: This file was generated by leex - DO NOT MODIFY BY HAND.
%%

stripquotes(Cs, L) -> undouble(lists:sublist(Cs, 2, L-2), []).

undouble([],           Acc) -> lists:reverse(Acc);
undouble([$', $'| Cs], Acc) -> undouble(Cs, [$'| Acc]);
undouble([Ch| Cs],     Acc) -> undouble(Cs, [Ch|Acc]).

to_float(List) -> list_to_float(insertPointNought(List, [])).

insertPointNought([], Acc) -> lists:reverse(Acc);
insertPointNought([$f], Acc) -> lists:reverse(Acc) ++ [$., $0];
insertPointNought([$F], Acc) -> lists:reverse(Acc) ++ [$., $0];
insertPointNought([$d], Acc) -> lists:reverse(Acc) ++ [$., $0];
insertPointNought([$D], Acc) -> lists:reverse(Acc) ++ [$., $0];
insertPointNought([$.| Cs], Acc) -> lists:reverse(Acc) ++ [$., $0| Cs];
insertPointNought([$e| Cs], Acc) -> lists:reverse(Acc) ++ [$., $0, $e| Cs];
insertPointNought([$E| Cs], Acc) -> lists:reverse(Acc) ++ [$., $0, $e| Cs];
insertPointNought([Ch| Cs], Acc) -> insertPointNought(Cs, [Ch| Acc]).

atomize(TokenChars) ->
    list_to_atom(TokenChars).
