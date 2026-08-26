%% @doc Tree transformations run after block and inline parsing.
-module(markdownz_core).

-export([typographer/2, task_lists/2]).

-define(TYPOGRAPHER_LITERAL, <<"markdownz-literal">>).

-spec typographer([markdownz:html_element()], map()) ->
    {[markdownz:html_element()], map()}.
typographer(Tree, #{config := #{options := Options}} = State) ->
    case maps:get(typographer, Options, false) of
        true -> {typographer_nodes(Tree, Options), State};
        false -> {Tree, State}
    end.

typographer_nodes(Nodes, Options) ->
    [typographer_node(Node, Options) || Node <- Nodes].

typographer_node({?TYPOGRAPHER_LITERAL, [], Children}, _Options) ->
    iolist_to_binary(Children);
typographer_node({<<"li">>, Attrs, Children}, Options) ->
    {<<"li">>, Attrs, transform_mixed(Children, Options)};
typographer_node({Tag, Attrs, Children}, Options) ->
    case inline_container(Tag) of
        true ->
            {Tag, Attrs, transform_inline(Children, Options)};
        false ->
            {Tag, Attrs, typographer_nodes(Children, Options)}
    end;
typographer_node(Node, _Options) ->
    Node.

%% Tight list items contain inline nodes directly, possibly interspersed with
%% nested block elements. Keep each inline run independent, as markdown-it's
%% core phase does for separate inline token streams.
transform_mixed([], _Options) ->
    [];
transform_mixed([Node | Rest], Options) when is_tuple(Node) ->
    case block_node(Node) of
        true -> [typographer_node(Node, Options) | transform_mixed(Rest, Options)];
        false -> transform_inline_run([Node | Rest], Options)
    end;
transform_mixed(Nodes, Options) ->
    transform_inline_run(Nodes, Options).

transform_inline_run(Nodes, Options) ->
    {Inline, Rest} = lists:splitwith(
        fun(Node) -> not block_node(Node) end,
        Nodes),
    transform_inline(Inline, Options) ++ transform_mixed(Rest, Options).

block_node({Tag, _Attrs, _Children}) ->
    lists:member(Tag, [
        <<"p">>, <<"h1">>, <<"h2">>, <<"h3">>, <<"h4">>, <<"h5">>,
        <<"h6">>, <<"blockquote">>, <<"pre">>, <<"ul">>, <<"ol">>,
        <<"table">>, <<"hr">>
    ]);
block_node(_) ->
    false.

inline_container(<<"p">>) -> true;
inline_container(<<"h1">>) -> true;
inline_container(<<"h2">>) -> true;
inline_container(<<"h3">>) -> true;
inline_container(<<"h4">>) -> true;
inline_container(<<"h5">>) -> true;
inline_container(<<"h6">>) -> true;
inline_container(<<"th">>) -> true;
inline_container(<<"td">>) -> true;
inline_container(_) -> false.

transform_inline(Nodes, Options) ->
    {Tokens0, _NextId} = collect_nodes(Nodes, 0, false, 0, []),
    Tokens1 = replace_tokens(lists:reverse(Tokens0)),
    Tokens = maybe_smartquotes(Tokens1, Options),
    Texts = maps:from_list([
        {maps:get(id, Token), maps:get(content, Token)}
        || #{kind := text} = Token <- Tokens
    ]),
    {Result, _} = rewrite_nodes(Nodes, Texts, 0),
    Result.

maybe_smartquotes(Tokens, Options) ->
    case maps:get(smartquotes, Options, false) of
        true ->
            Quotes = quote_characters(
                maps:get(quotes, Options, <<"“”‘’"/utf8>>)),
            smartquotes(Tokens, Quotes);
        false ->
            Tokens
    end.

collect_nodes([], _Level, _Protected, Id, Acc) ->
    {Acc, Id};
collect_nodes([Node | Rest], Level, Protected, Id0, Acc0) ->
    {Acc, Id} = collect_node(Node, Level, Protected, Id0, Acc0),
    collect_nodes(Rest, Level, Protected, Id, Acc).

collect_node(Text, Level, Protected, Id, Acc) when is_binary(Text) ->
    Kind = case Protected of true -> context; false -> text end,
    Token = #{id => Id, kind => Kind, level => Level, content => Text},
    {[Token | Acc], Id + 1};
collect_node({?TYPOGRAPHER_LITERAL, [], Children}, Level,
        _Protected, Id, Acc) ->
    Content = plain_text(Children),
    Token = #{kind => context, level => Level, content => Content},
    {[Token | Acc], Id};
collect_node({<<"br">>, _Attrs, _Children}, Level,
        _Protected, Id, Acc) ->
    Token = #{kind => break, level => Level, content => <<>>},
    {[Token | Acc], Id};
collect_node({Tag, _Attrs, Children}, Level, _Protected, Id, Acc)
        when Tag =:= <<"code">>; Tag =:= <<"pre">> ->
    Token = #{kind => context, level => Level, content => plain_text(Children)},
    {[Token | Acc], Id};
collect_node({<<"a">>, Attrs, Children}, Level, Protected, Id, Acc) ->
    IsProtected = Protected orelse is_autolink(Attrs, Children),
    collect_nodes(Children, Level + 1, IsProtected, Id, Acc);
collect_node({_Tag, _Attrs, Children}, Level, Protected, Id, Acc) ->
    collect_nodes(Children, Level + 1, Protected, Id, Acc);
collect_node({'=', Html}, Level, _Protected, Id, Acc) ->
    Token = #{kind => context, level => Level, content => Html},
    {[Token | Acc], Id};
collect_node(_Node, _Level, _Protected, Id, Acc) ->
    {Acc, Id}.

rewrite_nodes([], _Texts, Id) ->
    {[], Id};
rewrite_nodes([Node | Rest], Texts, Id0) ->
    {Replacement, Id1} = rewrite_node(Node, Texts, Id0),
    {Tail, Id} = rewrite_nodes(Rest, Texts, Id1),
    {[Replacement | Tail], Id}.

rewrite_node(Text, Texts, Id) when is_binary(Text) ->
    {maps:get(Id, Texts, Text), Id + 1};
rewrite_node({?TYPOGRAPHER_LITERAL, [], Children}, _Texts, Id) ->
    {iolist_to_binary(Children), Id};
rewrite_node({Tag, _Attrs, _Children} = Node, _Texts, Id)
        when Tag =:= <<"code">>; Tag =:= <<"pre">> ->
    {Node, Id};
rewrite_node({Tag, Attrs, Children}, Texts, Id0) ->
    {NewChildren, Id} = rewrite_nodes(Children, Texts, Id0),
    {{Tag, Attrs, NewChildren}, Id};
rewrite_node(Node, _Texts, Id) ->
    {Node, Id}.

replace_tokens(Tokens) ->
    [case Token of
         #{kind := text, content := Text} ->
             Token#{content := typographic_replacements(Text)};
         _ -> Token
     end || Token <- Tokens].

typographic_replacements(Text0) ->
    Text1 = replace(Text0, <<"(?i:\\(c\\))">>, <<"©"/utf8>>),
    Text2 = replace(Text1, <<"(?i:\\(r\\))">>, <<"®"/utf8>>),
    Text3 = replace(Text2, <<"(?i:\\(tm\\))">>, <<"™"/utf8>>),
    Text4 = replace(Text3, <<"\\+-">>, <<"±"/utf8>>),
    Text5 = replace(Text4, <<"\\.{2,}">>, <<"…"/utf8>>),
    Text6 = replace(Text5, <<"([?!])…"/utf8>>, <<"\\1..">>),
    Text7 = replace(Text6, <<"([?!]){4,}">>, <<"\\1\\1\\1">>),
    Text8 = replace(Text7, <<",{2,}">>, <<",">>),
    Text9 = replace(Text8, <<"(^|[^-])---(?=[^-]|$)">>, <<"\\1—"/utf8>>),
    Text10 = replace(Text9, <<"(^|\\s)--(?=\\s|$)">>, <<"\\1–"/utf8>>),
    replace(Text10, <<"(^|[^-\\s])--(?=[^-\\s]|$)">>, <<"\\1–"/utf8>>).

replace(Text, Pattern, Replacement) ->
    re:replace(Text, Pattern, Replacement,
        [global, unicode, multiline, {return, binary}]).

smartquotes(Tokens, Quotes) ->
    smartquotes(Tokens, [], [], #{}, Quotes).

smartquotes([], _Before, _Stack, Replacements, _Quotes) ->
    apply_quote_replacements([], Replacements);
smartquotes(Tokens, Before, Stack, Replacements, Quotes) ->
    smartquotes_loop(Tokens, Before, Stack, Replacements, Quotes, []).

smartquotes_loop([], _Before, _Stack, Replacements, _Quotes, Acc) ->
    apply_quote_replacements(lists:reverse(Acc), Replacements);
smartquotes_loop([Token | Rest], Before, Stack0, Replacements0, Quotes, Acc) ->
    Level = maps:get(level, Token),
    Stack = prune_quote_stack(Stack0, Level),
    case Token of
        #{kind := text} ->
            {NewStack, Replacements} = process_quotes(
                Token, Before, Rest, Stack, Replacements0, Quotes, 0),
            smartquotes_loop(Rest, [Token | Before], NewStack,
                Replacements, Quotes, [Token | Acc]);
        _ ->
            smartquotes_loop(Rest, [Token | Before], Stack,
                Replacements0, Quotes, [Token | Acc])
    end.

process_quotes(Token, Before, After, Stack0, Replacements0, Quotes, Cursor) ->
    Text = maps:get(content, Token),
    case next_quote(Text, Cursor) of
        nomatch ->
            {Stack0, Replacements0};
        {Position, Quote} ->
            Previous = previous_character(Text, Position, Before),
            Next = next_character(Text, Position + 1, After),
            {CanOpen0, CanClose0} = quote_flanking(Previous, Next),
            IsSingle = Quote =:= $',
            {CanOpen1, CanClose1} = inch_quote(
                Quote, Previous, Next, CanOpen0, CanClose0),
            {CanOpen, CanClose} = middle_quote(
                CanOpen1, CanClose1, Previous, Next),
            Level = maps:get(level, Token),
            Id = maps:get(id, Token),
            case {CanOpen, CanClose,
                    matching_quote(Stack0, IsSingle, Level)} of
                {_, true, {ok, Opener, Stack}} ->
                    {OpenQuote, CloseQuote} = quote_pair(IsSingle, Quotes),
                    Replacements1 = add_quote_replacement(
                        Replacements0, Id, Position, CloseQuote),
                    Replacements = add_quote_replacement(
                        Replacements1,
                        maps:get(id, Opener), maps:get(position, Opener),
                        OpenQuote),
                    process_quotes(Token, Before, After, Stack,
                        Replacements, Quotes, Position + 1);
                {true, _, _} ->
                    Opener = #{
                        id => Id,
                        position => Position,
                        single => IsSingle,
                        level => Level
                    },
                    process_quotes(Token, Before, After, [Opener | Stack0],
                        Replacements0, Quotes, Position + 1);
                {false, _, _} when IsSingle ->
                    Replacements = add_quote_replacement(
                        Replacements0, Id, Position, <<"’"/utf8>>),
                    process_quotes(Token, Before, After, Stack0,
                        Replacements, Quotes, Position + 1);
                _ ->
                    process_quotes(Token, Before, After, Stack0,
                        Replacements0, Quotes, Position + 1)
            end
    end.

next_quote(Text, Cursor) when Cursor >= byte_size(Text) ->
    nomatch;
next_quote(Text, Cursor) ->
    Scope = binary:part(Text, Cursor, byte_size(Text) - Cursor),
    case binary:match(Scope, [<<$'>>, <<$">>]) of
        {Position, 1} ->
            Absolute = Cursor + Position,
            {Absolute, binary:at(Text, Absolute)};
        nomatch -> nomatch
    end.

previous_character(Text, Position, _Before) when Position > 0 ->
    Prefix = binary:part(Text, 0, Position),
    last_codepoint(Prefix);
previous_character(_Text, _Position, Before) ->
    previous_neighbor(Before).

next_character(Text, Position, _After) when Position < byte_size(Text) ->
    first_codepoint(binary:part(Text, Position, byte_size(Text) - Position));
next_character(_Text, _Position, After) ->
    next_neighbor(After).

previous_neighbor([]) -> $\s;
previous_neighbor([#{kind := break} | _]) -> $\s;
previous_neighbor([#{content := <<>>} | Rest]) ->
    previous_neighbor(Rest);
previous_neighbor([#{content := Content} | _]) ->
    last_codepoint(Content).

next_neighbor([]) -> $\s;
next_neighbor([#{kind := break} | _]) -> $\s;
next_neighbor([#{content := <<>>} | Rest]) ->
    next_neighbor(Rest);
next_neighbor([#{content := Content} | _]) ->
    first_codepoint(Content).

quote_flanking(Previous, Next) ->
    PreviousPunctuation = is_punctuation(Previous),
    NextPunctuation = is_punctuation(Next),
    PreviousSpace = is_space(Previous),
    NextSpace = is_space(Next),
    CanOpen = not NextSpace
        andalso (not NextPunctuation
            orelse PreviousSpace
            orelse PreviousPunctuation),
    CanClose = not PreviousSpace
        andalso (not PreviousPunctuation
            orelse NextSpace
            orelse NextPunctuation),
    {CanOpen, CanClose}.

inch_quote($", Previous, $", _CanOpen, _CanClose)
        when Previous >= $0, Previous =< $9 ->
    {false, false};
inch_quote(_Quote, _Previous, _Next, CanOpen, CanClose) ->
    {CanOpen, CanClose}.

middle_quote(true, true, Previous, Next) ->
    {is_punctuation(Previous), is_punctuation(Next)};
middle_quote(CanOpen, CanClose, _Previous, _Next) ->
    {CanOpen, CanClose}.

matching_quote(Stack, IsSingle, Level) ->
    matching_quote(Stack, IsSingle, Level, Stack).

matching_quote([], _IsSingle, _Level, _Original) -> nomatch;
matching_quote([#{level := ItemLevel} | _], _IsSingle, Level, _Original)
        when ItemLevel < Level ->
    nomatch;
matching_quote([#{single := IsSingle, level := Level} = Item | Rest],
        IsSingle, Level, _Original) ->
    {ok, Item, Rest};
matching_quote([_Item | Rest], IsSingle, Level, Original) ->
    matching_quote(Rest, IsSingle, Level, Original).

prune_quote_stack([#{level := ItemLevel} | Rest], Level)
        when ItemLevel > Level ->
    prune_quote_stack(Rest, Level);
prune_quote_stack(Stack, _Level) ->
    Stack.

add_quote_replacement(Replacements, Id, Position, Quote) ->
    Positions = maps:get(Id, Replacements, #{}),
    Replacements#{Id => Positions#{Position => Quote}}.

apply_quote_replacements(Tokens, Replacements) ->
    [case Token of
         #{kind := text, id := Id, content := Text} ->
             Positions = maps:get(Id, Replacements, #{}),
             Token#{content := replace_positions(Text, Positions)};
         _ -> Token
     end || Token <- Tokens].

replace_positions(Text, Positions) when map_size(Positions) =:= 0 -> Text;
replace_positions(Text, Positions) ->
    replace_positions(Text, lists:sort(maps:to_list(Positions)), 0, []).

replace_positions(Text, [], Cursor, Acc) ->
    Tail = binary:part(Text, Cursor, byte_size(Text) - Cursor),
    iolist_to_binary(lists:reverse([Tail | Acc]));
replace_positions(Text, [{Position, Quote} | Rest], Cursor, Acc) ->
    Prefix = binary:part(Text, Cursor, Position - Cursor),
    replace_positions(Text, Rest, Position + 1, [Quote, Prefix | Acc]).

quote_characters({OpenDouble, CloseDouble, OpenSingle, CloseSingle}) ->
    {OpenDouble, CloseDouble, OpenSingle, CloseSingle};
quote_characters([OpenDouble, CloseDouble, OpenSingle, CloseSingle]) ->
    {OpenDouble, CloseDouble, OpenSingle, CloseSingle};
quote_characters(Quotes) when is_binary(Quotes) ->
    case [<<Character/utf8>> || Character <- unicode:characters_to_list(Quotes)] of
        [OpenDouble, CloseDouble, OpenSingle, CloseSingle] ->
            {OpenDouble, CloseDouble, OpenSingle, CloseSingle};
        _ ->
            {<<"“"/utf8>>, <<"”"/utf8>>, <<"‘"/utf8>>, <<"’"/utf8>>}
    end.

quote_pair(true, {_OpenDouble, _CloseDouble, OpenSingle, CloseSingle}) ->
    {OpenSingle, CloseSingle};
quote_pair(false, {OpenDouble, CloseDouble, _OpenSingle, _CloseSingle}) ->
    {OpenDouble, CloseDouble}.

is_space(Character) ->
    lists:member(Character, [$\s, $\t, $\n, $\r, $\f, $\v])
        orelse re:run(<<Character/utf8>>, <<"^[\\p{Z}]$">>,
            [unicode, {capture, none}]) =:= match.

is_punctuation(Character) ->
    re:run(<<Character/utf8>>, <<"^[\\p{P}\\p{S}]$">>,
        [unicode, {capture, none}]) =:= match.

first_codepoint(<<Character/utf8, _/binary>>) -> Character.

last_codepoint(Bin) ->
    [Last | _] = lists:reverse(unicode:characters_to_list(Bin)),
    Last.

plain_text(Nodes) ->
    iolist_to_binary([plain_node(Node) || Node <- Nodes]).

plain_node(Text) when is_binary(Text) -> Text;
plain_node({_Tag, _Attrs, Children}) -> plain_text(Children);
plain_node({'=', Html}) -> Html;
plain_node(_) -> <<>>.

is_autolink(Attrs, Children) ->
    case proplists:get_value(<<"href">>, Attrs) of
        Href when is_binary(Href) ->
            Text = plain_text(Children),
            Human = markdownz_inline:normalize_link_text(Href),
            Text =:= Human
                orelse strip_prefix(Human, <<"mailto:">>) =:= Text
                orelse strip_prefix(Human, <<"http://">>) =:= Text;
        _ -> false
    end.

strip_prefix(Bin, Prefix) ->
    Size = byte_size(Prefix),
    case Bin of
        <<Prefix:Size/binary, Rest/binary>> -> Rest;
        _ -> Bin
    end.

-spec task_lists([markdownz:html_element()], map()) ->
    {[markdownz:html_element()], map()}.
task_lists(Tree, #{config := #{options := Options}} = State) ->
    case maps:get(task_lists, Options, true) of
        true -> {markdownz_zipper:map(fun task_node/1, Tree), State};
        false -> {Tree, State}
    end.

task_node({<<"li">>, Attrs, [{<<"p">>, ParagraphAttrs, Children} | Rest]} = Node) ->
    case task_children(Children) of
        {ok, Checked, NewChildren} ->
            Input = checkbox(Checked),
            {<<"li">>, add_class(<<"task-list-item">>, Attrs),
                [{<<"p">>, ParagraphAttrs, [Input, <<" ">> | NewChildren]} | Rest]};
        false -> Node
    end;
task_node({<<"li">>, Attrs, Children} = Node) ->
    case task_children(Children) of
        {ok, Checked, NewChildren} ->
            {<<"li">>, add_class(<<"task-list-item">>, Attrs),
                [checkbox(Checked), <<" ">> | NewChildren]};
        false -> Node
    end;
task_node({Tag, Attrs, Children}) when Tag =:= <<"ul">>; Tag =:= <<"ol">> ->
    case lists:any(fun is_task_item/1, Children) of
        true -> {Tag, add_class(<<"contains-task-list">>, Attrs), Children};
        false -> {Tag, Attrs, Children}
    end;
task_node(Node) ->
    Node.

task_children([<<$[, Mark, $], $\s, Rest/binary>> | Children])
        when Mark =:= $x; Mark =:= $X; Mark =:= $\s ->
    {ok, Mark =/= $\s, nonempty_text(Rest, Children)};
task_children(_) ->
    false.

nonempty_text(<<>>, Children) -> Children;
nonempty_text(Rest, Children) -> [Rest | Children].

checkbox(true) ->
    {<<"input">>, [
        {<<"class">>, <<"task-list-item-checkbox">>},
        {<<"type">>, <<"checkbox">>},
        {<<"checked">>, true},
        {<<"disabled">>, true}
    ], []};
checkbox(false) ->
    {<<"input">>, [
        {<<"class">>, <<"task-list-item-checkbox">>},
        {<<"type">>, <<"checkbox">>},
        {<<"disabled">>, true}
    ], []}.

is_task_item({<<"li">>, Attrs, _Children}) ->
    has_class(<<"task-list-item">>, Attrs);
is_task_item(_) ->
    false.

add_class(Class, Attrs) ->
    case lists:keytake(<<"class">>, 1, Attrs) of
        {value, {<<"class">>, Existing}, Rest} ->
            [{<<"class">>, <<Existing/binary, " ", Class/binary>>} | Rest];
        false ->
            [{<<"class">>, Class} | Attrs]
    end.

has_class(Class, Attrs) ->
    case lists:keyfind(<<"class">>, 1, Attrs) of
        {_, Classes} -> lists:member(Class, binary:split(Classes, <<" ">>, [global]));
        false -> false
    end.
