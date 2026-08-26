%% @doc A zipper over a z_html_parse compatible forest.
%%
%% The current level is `{Left, Right}'. Left is stored in reverse order and
%% Right starts with the current node. Parent frames retain the element and its
%% siblings, so moving and replacing nodes does not rebuild unrelated branches.
-module(markdownz_zipper).

-export([
    from_list/1,
    to_list/1,
    current/1,
    replace/2,
    insert/2,
    delete/1,
    previous/1,
    next/1,
    down/1,
    up/1,
    top/1,
    map/2
]).

-type html_node() :: markdownz:html_element().
-type frame() :: {binary(), list(), [html_node()], [html_node()]}.
-type zipper() :: {[frame()], {[html_node()], [html_node()]}}.

-export_type([zipper/0]).

-spec from_list([html_node()]) -> zipper().
from_list(Nodes) ->
    {[], {[], Nodes}}.

-spec to_list(zipper()) -> [html_node()].
to_list({[], {Left, Right}}) ->
    lists:reverse(Left, Right).

-spec current(zipper()) -> html_node().
current({_Thread, {_Left, [Node | _Right]}}) ->
    Node.

-spec replace(html_node(), zipper()) -> zipper().
replace(Node, {Thread, {Left, [_Old | Right]}}) ->
    {Thread, {Left, [Node | Right]}}.

-spec insert(html_node(), zipper()) -> zipper().
insert(Node, {Thread, {Left, Right}}) ->
    {Thread, {Left, [Node | Right]}}.

-spec delete(zipper()) -> zipper().
delete({Thread, {Left, [_Node | Right]}}) ->
    {Thread, {Left, Right}}.

-spec previous(zipper()) -> zipper().
previous({Thread, {[Node | Left], Right}}) ->
    {Thread, {Left, [Node | Right]}}.

-spec next(zipper()) -> zipper().
next({Thread, {Left, [Node | Right]}}) ->
    {Thread, {[Node | Left], Right}}.

-spec down(zipper()) -> zipper().
down({Thread, {Left, [{Tag, Attrs, Children} | Right]}}) ->
    {[{Tag, Attrs, Left, Right} | Thread], {[], Children}}.

-spec up(zipper()) -> zipper().
up({[{Tag, Attrs, ParentLeft, ParentRight} | Thread], {Left, Right}}) ->
    Children = lists:reverse(Left, Right),
    {Thread, {ParentLeft, [{Tag, Attrs, Children} | ParentRight]}}.

-spec top(zipper()) -> zipper().
top({[], _Level} = Zipper) ->
    Zipper;
top(Zipper) ->
    top(up(Zipper)).

%% @doc Bottom-up map. Children are transformed before their parent. This is
%% useful for rules whose parent decoration depends on rewritten descendants.
-spec map(fun((html_node()) -> html_node()), [html_node()]) -> [html_node()].
map(Fun, Nodes) ->
    to_list(top(map_level(Fun, from_list(Nodes)))).

map_level(_Fun, {_Thread, {_Left, []}} = Zipper) ->
    Zipper;
map_level(Fun, Zipper0) ->
    Zipper1 = case current(Zipper0) of
        {_Tag, _Attrs, []} -> Zipper0;
        {_Tag, _Attrs, _Children} -> up(map_level(Fun, down(Zipper0)));
        _Leaf -> Zipper0
    end,
    Zipper2 = replace(Fun(current(Zipper1)), Zipper1),
    map_level(Fun, next(Zipper2)).
