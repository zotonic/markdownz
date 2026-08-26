%% @doc Render z_html_parse compatible trees to HTML iodata.
-module(markdownz_html).

-export([render/2, escape/1, escape_attr/1]).

-type html_element() :: binary()
                      | {'=', binary()}
                      | {binary(), [{binary(), term()}], [html_element()]}.

-spec render([html_element()] | html_element(), map()) -> iodata().
render(Nodes, Config) when is_list(Nodes) ->
    render_nodes(Nodes, Config);
render(Node, Config) ->
    render_node(Node, Config).

render_nodes(Nodes, Config) ->
    join([render_node(Node, Config) || Node <- Nodes], <<"\n">>).

render_node(Text, _Config) when is_binary(Text) ->
    escape(Text);
render_node({'=', Html}, _Config) ->
    Html;
render_node({Tag, Attrs, Children} = Node, Config) ->
    Renderers = maps:get(renderers, Config, #{}),
    case maps:find(Tag, Renderers) of
        {ok, Fun} when is_function(Fun, 2) -> Fun(Node, Config);
        error -> render_element(Tag, Attrs, Children, Config)
    end.

render_element(Tag, Attrs, Children, Config) ->
    Open = [<<"<">>, Tag, render_attrs(Attrs), <<">">>],
    case is_void(Tag) of
        true ->
            case maps:get(xhtml_out, maps:get(options, Config), false) of
                true -> [<<"<">>, Tag, render_attrs(Attrs), <<" />">>];
                false -> Open
            end;
        false ->
            ClosingSpace = closing_space(Tag, Children, Config),
            [Open, render_children(Tag, Children, Config),
             ClosingSpace, <<"</">>, Tag, <<">">>]
    end.

closing_space(
        <<"blockquote">>,
        Children,
        #{options := #{commonmark_render := true}}) ->
    case lists:reverse(Children) of
        [{'=', _} | _] -> <<"\n">>;
        _ -> <<>>
    end;
closing_space(_Tag, _Children, _Config) ->
    <<>>.

render_children(<<"li">>, Children, #{options := #{commonmark_render := true}} = Config) ->
    render_list_item_children(Children, Config);
render_children(_Tag, Children, Config) ->
    [render_node(Child, Config) || Child <- Children].

render_list_item_children([], _Config) ->
    [];
render_list_item_children([First | Rest], Config) ->
    [render_node(First, Config), render_list_item_children(Rest, First, Config)].

render_list_item_children([], _Previous, _Config) ->
    [];
render_list_item_children([Node | Rest], Previous, Config) ->
    Separator = case is_block_node(Previous) orelse is_block_node(Node) of
        true -> <<"\n">>;
        false -> <<>>
    end,
    [Separator, render_node(Node, Config),
     render_list_item_children(Rest, Node, Config)].

is_block_node({Tag, _, _}) ->
    lists:member(Tag, [
        <<"address">>, <<"article">>, <<"aside">>, <<"blockquote">>, <<"div">>,
        <<"dl">>, <<"fieldset">>, <<"figure">>, <<"footer">>, <<"form">>,
        <<"h1">>, <<"h2">>, <<"h3">>, <<"h4">>, <<"h5">>, <<"h6">>,
        <<"header">>, <<"hr">>, <<"main">>, <<"nav">>, <<"ol">>, <<"p">>,
        <<"pre">>, <<"section">>, <<"table">>, <<"ul">>
    ]);
is_block_node({'=', _}) -> true;
is_block_node(_) -> false.

render_attrs([]) ->
    [];
render_attrs([{Name, true} | Rest]) ->
    [<<" ">>, Name, render_attrs(Rest)];
render_attrs([{_Name, false} | Rest]) ->
    render_attrs(Rest);
render_attrs([{Name, Value} | Rest]) ->
    [<<" ">>, Name, <<"=\"">>, escape_attr(to_binary(Value)), <<"\"">>, render_attrs(Rest)].

is_void(<<"area">>) -> true;
is_void(<<"base">>) -> true;
is_void(<<"br">>) -> true;
is_void(<<"col">>) -> true;
is_void(<<"embed">>) -> true;
is_void(<<"hr">>) -> true;
is_void(<<"img">>) -> true;
is_void(<<"input">>) -> true;
is_void(<<"link">>) -> true;
is_void(<<"meta">>) -> true;
is_void(<<"param">>) -> true;
is_void(<<"source">>) -> true;
is_void(<<"track">>) -> true;
is_void(<<"wbr">>) -> true;
is_void(_) -> false.

-spec escape(binary()) -> iodata().
escape(Bin) ->
    escape(Bin, []).

escape(<<>>, Acc) ->
    lists:reverse(Acc);
escape(<<$&, Rest/binary>>, Acc) ->
    escape(Rest, [<<"&amp;">> | Acc]);
escape(<<$<, Rest/binary>>, Acc) ->
    escape(Rest, [<<"&lt;">> | Acc]);
escape(<<$>, Rest/binary>>, Acc) ->
    escape(Rest, [<<"&gt;">> | Acc]);
escape(<<$\", Rest/binary>>, Acc) ->
    escape(Rest, [<<"&quot;">> | Acc]);
escape(<<Char/utf8, Rest/binary>>, Acc) ->
    escape(Rest, [<<Char/utf8>> | Acc]).

-spec escape_attr(binary()) -> iodata().
escape_attr(Bin) ->
    escape_attr(Bin, []).

escape_attr(<<>>, Acc) ->
    lists:reverse(Acc);
escape_attr(<<$&, Rest/binary>>, Acc) ->
    escape_attr(Rest, [<<"&amp;">> | Acc]);
escape_attr(<<$<, Rest/binary>>, Acc) ->
    escape_attr(Rest, [<<"&lt;">> | Acc]);
escape_attr(<<$>, Rest/binary>>, Acc) ->
    escape_attr(Rest, [<<"&gt;">> | Acc]);
escape_attr(<<$\", Rest/binary>>, Acc) ->
    escape_attr(Rest, [<<"&quot;">> | Acc]);
escape_attr(<<Char/utf8, Rest/binary>>, Acc) ->
    escape_attr(Rest, [<<Char/utf8>> | Acc]).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_float(Value) -> float_to_binary(Value, [compact]);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).

join([], _Separator) -> [];
join([One], _Separator) -> One;
join([First | Rest], Separator) -> [First, [[Separator, Item] || Item <- Rest]].
