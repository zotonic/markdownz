%% @doc Extensible Markdown parser with z_html_parse compatible output.
-module(markdownz).

-export([
    new/0,
    new/1,
    use/2,
    use/3,
    add_rule/5,
    replace_rule/4,
    enable/3,
    disable/3,
    set_renderer/3,
    parse/1,
    parse/2,
    to_html/1,
    to_html/2,
    to_binary/1,
    to_binary/2
]).

-type html_element() :: binary()
                      | {'=', binary()}
                      | {binary(), [{binary(), term()}], [html_element()]}.
-type phase() :: block | inline | core.
-type parse_error() :: {error, binary(), term()} | {incomplete, binary(), term()}.
-type config() :: #{
    options := map(),
    rulers := #{phase() := markdownz_ruler:ruler()},
    renderers := #{binary() => fun((html_element(), config()) -> iodata())}
}.

-export_type([html_element/0, phase/0, config/0]).

-spec new() -> config().
new() ->
    new(#{}).

-spec new(default | commonmark | gfm | zotonic | map()) -> config().
new(default) ->
    new(#{});
new(commonmark) ->
    new(#{
        html => true,
        xhtml_out => true,
        code_style => commonmark,
        commonmark_render => true,
        linkify => false,
        tables => false,
        strikethrough => false,
        subscript => false,
        superscript => false,
        task_lists => false
    });
new(gfm) ->
    new(#{
        html => true,
        linkify => true,
        tables => true,
        strikethrough => true,
        subscript => false,
        superscript => false,
        task_lists => true
    });
new(zotonic) ->
    new(#{});
new(Options) ->
    Defaults = #{
        html => false,
        breaks => false,
        linkify => true,
        tables => true,
        strikethrough => true,
        subscript => true,
        superscript => true,
        task_lists => true,
        typographer => false,
        quotes => <<"“”‘’"/utf8>>,
        xhtml_out => false,
        code_style => zotonic,
        commonmark_render => false,
        table_class => <<"table">>,
        table_role => <<"table">>
    },
    #{
        options => maps:merge(Defaults, Options),
        rulers => #{
            block => markdownz_block:default_rules(),
            inline => markdownz_inline:default_rules(),
            core => markdownz_ruler:new([
                {typographer, {markdownz_core, typographer}},
                {task_lists, {markdownz_core, task_lists}}
            ])
        },
        renderers => #{}
    }.

-spec use(config(), module()) -> config().
use(Config, Plugin) ->
    use(Config, Plugin, #{}).

-spec use(config(), module(), map()) -> config().
use(Config, Plugin, Options) ->
    Plugin:init(Config, Options).

-spec add_rule(config(), phase(), before | 'after', atom(), {atom(), markdownz_ruler:handler()}) -> config().
add_rule(Config, Phase, Where, Anchor, {Name, Handler}) ->
    update_ruler(Config, Phase,
        fun(Ruler) ->
            case Where of
                before -> markdownz_ruler:before(Anchor, Name, Handler, Ruler);
                'after' -> markdownz_ruler:'after'(Anchor, Name, Handler, Ruler)
            end
        end).

-spec replace_rule(config(), phase(), atom(), markdownz_ruler:handler()) -> config().
replace_rule(Config, Phase, Name, Handler) ->
    update_ruler(Config, Phase, fun(Ruler) -> markdownz_ruler:replace(Name, Handler, Ruler) end).

-spec enable(config(), phase(), atom() | [atom()]) -> config().
enable(Config, Phase, Names) ->
    update_ruler(Config, Phase, fun(Ruler) -> markdownz_ruler:enable(Names, Ruler) end).

-spec disable(config(), phase(), atom() | [atom()]) -> config().
disable(Config, Phase, Names) ->
    update_ruler(Config, Phase, fun(Ruler) -> markdownz_ruler:disable(Names, Ruler) end).

-spec set_renderer(config(), binary(), fun((html_element(), config()) -> iodata())) -> config().
set_renderer(#{renderers := Renderers} = Config, Tag, Fun) ->
    Config#{renderers := Renderers#{Tag => Fun}}.

-spec parse(iodata()) -> {ok, [html_element()]} | parse_error().
parse(Markdown) ->
    parse(Markdown, new()).

-spec parse(iodata(), config() | map()) ->
    {ok, [html_element()]} | parse_error().
parse(Markdown, Config0) ->
    Config = ensure_config(Config0),
    case unicode:characters_to_binary(Markdown) of
        Bin when is_binary(Bin) ->
            {Tree0, State0} = markdownz_block:parse(Bin, Config),
            {Tree, _State} = run_core(Tree0, State0, Config),
            {ok, Tree};
        {error, _Encoded, _Rest} = Error -> Error;
        {incomplete, _Encoded, _Rest} = Error -> Error
    end.

-spec to_html(iodata()) -> iodata().
to_html(Markdown) ->
    to_html(Markdown, new()).

-spec to_html(iodata(), config() | map()) -> iodata().
to_html(Markdown, Config0) ->
    Config = ensure_config(Config0),
    {ok, Tree} = parse(Markdown, Config),
    markdownz_html:render(Tree, Config).

-spec to_binary(iodata()) -> binary().
to_binary(Markdown) ->
    iolist_to_binary(to_html(Markdown)).

-spec to_binary(iodata(), config() | map()) -> binary().
to_binary(Markdown, Config) ->
    iolist_to_binary(to_html(Markdown, Config)).

ensure_config(#{rulers := _, options := _} = Config) -> Config;
ensure_config(Options) when is_map(Options) -> new(Options).

update_ruler(#{rulers := Rulers} = Config, Phase, Fun) ->
    Ruler = maps:get(Phase, Rulers),
    Config#{rulers := Rulers#{Phase := Fun(Ruler)}}.

run_core(Tree, State, #{rulers := #{core := Ruler}}) ->
    lists:foldl(
        fun(#{handler := Handler}, {Nodes, AccState}) ->
            call(Handler, Nodes, AccState)
        end,
        {Tree, State},
        markdownz_ruler:rules(Ruler)).

call(Fun, Value, State) when is_function(Fun, 2) -> Fun(Value, State);
call({Module, Function}, Value, State) -> Module:Function(Value, State).
