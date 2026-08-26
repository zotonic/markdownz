%% @doc Tree transformations run after block and inline parsing.
-module(markdownz_core).

-export([task_lists/2]).

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
