%% Erlang terms as JSON for the gateway and MQTT: maps stay maps (keys as strings), tuples become arrays, atoms
%% strings (true, false and null stay JSON's), binaries strings.
-module(gh_json).
-export([encode/1, term/1]).

-spec encode(term()) -> binary().
encode(T) -> iolist_to_binary(json:encode(term(T))).

-spec term(term()) -> term().
term(M) when is_map(M) -> maps:from_list([{key(K), term(V)} || {K, V} <- maps:to_list(M)]);
term(L) when is_list(L) -> [term(X) || X <- L];
term(T) when is_tuple(T) -> [term(X) || X <- tuple_to_list(T)];
term(A) when is_atom(A), A =/= true, A =/= false, A =/= null -> atom_to_binary(A);
term(P) when is_pid(P); is_reference(P); is_port(P); is_function(P) -> list_to_binary(io_lib:format("~p", [P]));
term(X) -> X.

key({A, B}) -> <<(key(A))/binary, "_", (key(B))/binary>>;
key(A) when is_atom(A) -> atom_to_binary(A);
key(B) when is_binary(B) -> B;
key(I) when is_integer(I) -> integer_to_binary(I);
key(L) when is_list(L) -> unicode:characters_to_binary(L).
