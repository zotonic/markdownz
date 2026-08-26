%% @doc Ordered, immutable rule lists used by the Markdown parser.
-module(markdownz_ruler).

-export([
    new/1,
    rules/1,
    before/4,
    'after'/4,
    replace/3,
    enable/2,
    disable/2
]).

-type handler() :: fun() | {module(), atom()}.
-type rule() :: #{name := atom(), enabled := boolean(), handler := handler()}.
-type ruler() :: [rule()].

-export_type([handler/0, rule/0, ruler/0]).

-spec new([{atom(), handler()}]) -> ruler().
new(Rules) ->
    [#{name => Name, enabled => true, handler => Handler} || {Name, Handler} <- Rules].

-spec rules(ruler()) -> [rule()].
rules(Ruler) ->
    [Rule || #{enabled := true} = Rule <- Ruler].

-spec before(atom(), atom(), handler(), ruler()) -> ruler().
before(Anchor, Name, Handler, Ruler) ->
    insert(Anchor, #{name => Name, enabled => true, handler => Handler}, before, Ruler).

-spec 'after'(atom(), atom(), handler(), ruler()) -> ruler().
'after'(Anchor, Name, Handler, Ruler) ->
    insert(Anchor, #{name => Name, enabled => true, handler => Handler}, 'after', Ruler).

-spec replace(atom(), handler(), ruler()) -> ruler().
replace(Name, Handler, Ruler) ->
    update(Name, fun(Rule) -> Rule#{handler := Handler} end, Ruler).

-spec enable(atom() | [atom()], ruler()) -> ruler().
enable(Names, Ruler) ->
    set_enabled(Names, true, Ruler).

-spec disable(atom() | [atom()], ruler()) -> ruler().
disable(Names, Ruler) ->
    set_enabled(Names, false, Ruler).

insert(Anchor, Rule, Where, Ruler) ->
    case lists:any(fun(#{name := Name}) -> Name =:= maps:get(name, Rule) end, Ruler) of
        true -> error({rule_exists, maps:get(name, Rule)});
        false -> insert_1(Anchor, Rule, Where, Ruler, [])
    end.

insert_1(Anchor, Rule, before, [#{name := Anchor} = Current | Rest], Acc) ->
    lists:reverse(Acc, [Rule, Current | Rest]);
insert_1(Anchor, Rule, 'after', [#{name := Anchor} = Current | Rest], Acc) ->
    lists:reverse(Acc, [Current, Rule | Rest]);
insert_1(Anchor, Rule, Where, [Current | Rest], Acc) ->
    insert_1(Anchor, Rule, Where, Rest, [Current | Acc]);
insert_1(Anchor, _Rule, _Where, [], _Acc) ->
    error({unknown_rule, Anchor}).

set_enabled(Names, Enabled, Ruler) when is_atom(Names) ->
    set_enabled([Names], Enabled, Ruler);
set_enabled(Names, Enabled, Ruler) ->
    lists:foldl(
        fun(Name, Acc) -> update(Name, fun(Rule) -> Rule#{enabled := Enabled} end, Acc) end,
        Ruler,
        Names).

update(Name, Fun, Ruler) ->
    case lists:any(fun(#{name := RuleName}) -> RuleName =:= Name end, Ruler) of
        true ->
            [case Rule of
                 #{name := Name} -> Fun(Rule);
                 _ -> Rule
             end || Rule <- Ruler];
        false ->
            error({unknown_rule, Name})
    end.
