-module(tx_pool_feeder).
-behaviour(gen_server).
-export([start_link/0,init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-export([absorb/1, absorb_unsafe/1]).
-include("../records.hrl").
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, ok, []).
init(ok) -> {ok, []}.
handle_call({absorb, SignedTx}, _From, State) ->
    absorb_internal(SignedTx),
    {reply, ok, State};
handle_call(_, _, S) -> {reply, S, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> io:fwrite("tx_pool_feeder died\n").
code_change(_, S, _) -> {ok, S}.
is_in(_, []) -> false;
is_in(Tx, [STx2 | T]) ->
    Tx2 = testnet_sign:data(STx2),
    (Tx == Tx2) orelse (is_in(Tx, T)).
absorb_internal(SignedTx) ->
    F = tx_pool:get(),
    Txs = F#tx_pool.txs,
    Tx = testnet_sign:data(SignedTx),
    Fee = element(4, Tx),
    Type = element(1, Tx),
    Cost = trees:dict_tree_get(governance, Type),
    {ok, MinimumTxFee} = application:get_env(ae_core, minimum_tx_fee),
    true = Fee > (MinimumTxFee + Cost),
    true = testnet_sign:verify(SignedTx),
    case is_in(testnet_sign:data(SignedTx), Txs) of
        true -> ok;
        false -> 
	    absorb_unsafe(SignedTx)
    end.
grow_dict(Dict, [], _) -> Dict;
grow_dict(Dict, [{orders, Key}|T], Trees) ->
    Dict2 = 
	case dict:find({orders, Key}, Dict) of
	    error ->
		Oracles = trees:oracles(Trees),
		{_, Oracle, _} = oracles:get(Key#key.id, Oracles),
		Orders = case Oracle of
			     empty -> orders:empty_book();
			     _ -> oracles:orders(Oracle)
			 end,
		%Orders = Oracle#oracle.orders,
		{_, Val, _} = orders:get(Key#key.pub, Orders),
		Val2 = case Val of
			   empty -> 0;
			   X -> orders:serialize(X)
			       %oracles:orders(Oracle)
		       end,
		dict:store({orders, Key}, Val2, Dict);
	    {ok, _} -> Dict
	end,
    grow_dict(Dict2, T, Trees);
grow_dict(Dict, [{oracle_bets, Key}|T], Trees) ->
    Dict2 = 
	case dict:find({oracle_bets, Key}, Dict) of
	    error ->
		Accounts = trees:accounts(Trees),
		{_, Account, _} = accounts:get(Key#key.pub, Accounts),
		Orders = Account#acc.bets,
		{_, Val, _} = oracle_bets:get(Key#key.id, Orders),
		Val2 = case Val of
			   empty -> 0;
			   X -> oracle_bets:serialize(X)
		       end,
		dict:store({oracle_bets, Key}, Val2, Dict);
	    {ok, _} -> Dict
	end,
    grow_dict(Dict2, T, Trees);
grow_dict(Dict, [{TreeID, Key}|T], Trees) ->
    Dict2 = 
	case dict:find({TreeID, Key}, Dict) of
	    error ->
		Tree = trees:TreeID(Trees),
		{_, Val, _} = TreeID:get(Key, Tree),
		Val2 = case Val of
			   empty -> 0;
			   X -> TreeID:serialize(X)
		       end,
		Foo = case TreeID of
			  accounts -> {Val2, 0};
			  oracles -> {Val2, 0};
			  _ -> Val2
		      end,
		dict:store({TreeID, Key}, Foo, Dict);
	    {ok, _} -> Dict
	end,
    grow_dict(Dict2, T, Trees).

	    
absorb_unsafe(SignedTx, Trees, Height, Dict) ->
    %This is the most expensive part of absorbing transactions.
    Querys = proofs:txs_to_querys([SignedTx], Trees),
    %Querys is a list like [[TreeID, Key]...]
    %for every query, check if it is in the dict already.
    %If it is already in the dict, then we are done.
    %Otherwise, get a copy from the tree, and store it in the dict.
    Dict2 = grow_dict(Dict, Querys, Trees),

%    Facts = proofs:prove(Querys, Trees),
    %Dict2 = proofs:facts_to_dict(Facts, dict:new()),
%    Dict2 = proofs:facts_to_dict(Facts, Dict),
    NewDict = txs:digest_from_dict([SignedTx], Dict2, Height + 1),%This processes the tx.
    %NewTrees = block:dict_update_trie(Trees, NewDict), 
    %tx_pool:absorb_tx(NewTrees, NewDict, SignedTx).
    tx_pool:absorb_tx(NewDict, SignedTx).
absorb([]) -> ok;%if one tx makes the gen_server die, it doesn't ignore the rest of the txs.
absorb([H|T]) -> absorb(H), absorb(T);
absorb(SignedTx) ->
    gen_server:call(?MODULE, {absorb, SignedTx}).
absorb_unsafe(SignedTx) ->
    F = tx_pool:get(),
    Trees = F#tx_pool.block_trees,
    Height = F#tx_pool.height,
    Dict = F#tx_pool.dict,
    absorb_unsafe(SignedTx, Trees, Height, Dict).
