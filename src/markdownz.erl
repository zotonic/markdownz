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
    split_document/1,
    parse_document/1,
    parse_document/2,
    parse/1,
    parse/2,
    parse_bounded/1,
    parse_bounded/2,
    to_html/1,
    to_html/2,
    to_html_bounded/1,
    to_html_bounded/2,
    to_binary/1,
    to_binary/2,
    to_binary_bounded/1,
    to_binary_bounded/2
]).

-type html_element() :: binary()
                      | {'=', binary()}
                      | {binary(), [{binary(), term()}], [html_element()]}.
-type phase() :: block | inline | core.
-type parse_error() :: {error, term(), term()} | {incomplete, binary(), term()}.
-type front_matter() :: undefined | #{format := yaml, source := binary()}.
-type document(Content) :: #{front_matter := front_matter(), content := Content}.
-type config() :: #{
    options := map(),
    rulers := #{phase() := markdownz_ruler:ruler()},
    renderers := #{binary() => fun((html_element(), config()) -> iodata())}
}.

-export_type([html_element/0, phase/0, config/0, front_matter/0, document/1]).

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
        max_nesting => 20,
        linkify => false,
        tables => false,
        strikethrough => false,
        subscript => false,
        superscript => false,
        task_lists => false,
        fenced_divs => false
    });
new(gfm) ->
    new(#{
        html => true,
        linkify => true,
        tables => true,
        strikethrough => true,
        subscript => false,
        superscript => false,
        task_lists => true,
        fenced_divs => false
    });
new(zotonic) ->
    new(#{
        typographer => true,
        smartquotes => false
    });
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
        fenced_divs => true,
        container_types => default_container_types(),
        typographer => false,
        smartquotes => false,
        quotes => <<"“”‘’"/utf8>>,
        xhtml_out => false,
        code_style => zotonic,
        commonmark_render => false,
        max_input_bytes => 1024 * 1024,
        max_nesting => 100,
        parse_timeout => 5000,
        max_parse_heap_words => 8 * 1024 * 1024,
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

default_container_types() ->
    #{
        <<"aside">> => #{
            tag => <<"aside">>,
            remove_class => true
        },
        <<"note">> => #{
            tag => <<"div">>,
            add_class => <<"admonition">>,
            role => <<"note">>,
            default_title => <<"Note">>
        }
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

%% @doc Split optional YAML front matter from a Markdown document.
%%
%% The YAML source is deliberately not decoded. This keeps document metadata
%% generic and lets callers choose their decoder and schema.
-spec split_document(iodata()) ->
    {ok, document(binary())} | parse_error().
split_document(Markdown) ->
    case unicode:characters_to_binary(Markdown) of
        Bin when is_binary(Bin) -> markdownz_document:split(Bin);
        {error, _Encoded, _Rest} = Error -> Error;
        {incomplete, _Encoded, _Rest} = Error -> Error
    end.

%% @doc Parse Markdown content and return it together with optional front matter.
-spec parse_document(iodata()) ->
    {ok, document([html_element()])} | parse_error().
parse_document(Markdown) ->
    parse_document(Markdown, new()).

-spec parse_document(iodata(), config() | map()) ->
    {ok, document([html_element()])} | parse_error().
parse_document(Markdown, Config) ->
    case split_document(Markdown) of
        {ok, #{front_matter := FrontMatter, content := Content}} ->
            case parse(Content, Config) of
                {ok, Tree} -> {ok, #{front_matter => FrontMatter, content => Tree}};
                Error -> Error
            end;
        Error -> Error
    end.

-spec parse(iodata()) -> {ok, [html_element()]} | parse_error().
parse(Markdown) ->
    parse(Markdown, new()).

-spec parse(iodata(), config() | map()) ->
    {ok, [html_element()]} | parse_error().
parse(Markdown, Config0) ->
    Config = ensure_config(Config0),
    case input_binary(Markdown, Config) of
        {ok, Bin} -> parse_binary(Bin, Config);
        Error -> Error
    end.

%% @doc Parse in a monitored process with timeout and heap-size bounds.
%% These bounds limit resource use; they do not sanitize raw HTML output.
-spec parse_bounded(iodata()) -> {ok, [html_element()]} | parse_error().
parse_bounded(Markdown) ->
    parse_bounded(Markdown, new()).

-spec parse_bounded(iodata(), config() | map()) ->
    {ok, [html_element()]} | parse_error().
parse_bounded(Markdown, Config0) ->
    bounded(Markdown, Config0, parse).

-spec to_html(iodata()) -> iodata().
to_html(Markdown) ->
    to_html(Markdown, new()).

-spec to_html(iodata(), config() | map()) -> iodata().
to_html(Markdown, Config0) ->
    Config = ensure_config(Config0),
    {ok, Tree} = parse(Markdown, Config),
    markdownz_html:render(Tree, Config).

%% @doc Parse and render in a resource-bounded monitored process.
-spec to_html_bounded(iodata()) -> {ok, iodata()} | parse_error().
to_html_bounded(Markdown) ->
    to_html_bounded(Markdown, new()).

-spec to_html_bounded(iodata(), config() | map()) ->
    {ok, iodata()} | parse_error().
to_html_bounded(Markdown, Config0) ->
    bounded(Markdown, Config0, html).

-spec to_binary(iodata()) -> binary().
to_binary(Markdown) ->
    iolist_to_binary(to_html(Markdown)).

-spec to_binary(iodata(), config() | map()) -> binary().
to_binary(Markdown, Config) ->
    iolist_to_binary(to_html(Markdown, Config)).

%% @doc Parse, render, and flatten in a resource-bounded monitored process.
-spec to_binary_bounded(iodata()) -> {ok, binary()} | parse_error().
to_binary_bounded(Markdown) ->
    to_binary_bounded(Markdown, new()).

-spec to_binary_bounded(iodata(), config() | map()) ->
    {ok, binary()} | parse_error().
to_binary_bounded(Markdown, Config0) ->
    bounded(Markdown, Config0, binary).

parse_binary(Bin, Config) ->
    try
        {Tree0, State0} = markdownz_block:parse(Bin, Config),
        {Tree, _State} = run_core(Tree0, State0, Config),
        {ok, Tree}
    catch
        throw:{markdownz_limit, Kind, Details} ->
            {error, Kind, Details}
    end.

input_binary(Markdown, #{options := Options}) ->
    Maximum = maps:get(max_input_bytes, Options, 1024 * 1024),
    case preflight_size(Markdown, Maximum) of
        {error, _Kind, _Details} = Error -> Error;
        ok ->
            case unicode:characters_to_binary(Markdown) of
                Bin when is_binary(Bin) -> check_binary_size(Bin, Maximum);
                {error, _Encoded, _Rest} = Error -> Error;
                {incomplete, _Encoded, _Rest} = Error -> Error
            end
    end.

preflight_size(_Markdown, infinity) ->
    ok;
preflight_size(Markdown, Maximum) ->
    try iolist_size(Markdown) of
        Size when Size > Maximum -> input_size_error(Maximum, Size);
        _Size -> ok
    catch
        error:badarg -> ok
    end.

check_binary_size(Bin, infinity) ->
    {ok, Bin};
check_binary_size(Bin, Maximum) when byte_size(Bin) =< Maximum ->
    {ok, Bin};
check_binary_size(Bin, Maximum) ->
    input_size_error(Maximum, byte_size(Bin)).

input_size_error(Maximum, Actual) ->
    {error, input_too_large, #{limit => Maximum, actual => Actual}}.

bounded(Markdown, Config0, Operation) ->
    Config = ensure_config(Config0),
    case input_binary(Markdown, Config) of
        {ok, Bin} -> run_bounded(Bin, Config, Operation);
        Error -> Error
    end.

run_bounded(Bin, #{options := Options} = Config, Operation) ->
    Parent = self(),
    ReplyRef = make_ref(),
    SpawnOptions = [monitor | heap_option(
        maps:get(max_parse_heap_words, Options, 8 * 1024 * 1024))],
    {Pid, MonitorRef} = spawn_opt(
        fun() ->
            Result = try bounded_operation(Operation, Bin, Config)
            catch
                Class:Reason ->
                    {error, parser_crash, #{
                        class => Class,
                        reason => bounded_crash_reason(Reason)
                    }}
            end,
            Parent ! {ReplyRef, Result}
        end,
        SpawnOptions),
    Timeout = maps:get(parse_timeout, Options, 5000),
    await_bounded(Pid, MonitorRef, ReplyRef, Timeout).

heap_option(infinity) -> [];
heap_option(Maximum) ->
    [{max_heap_size, #{
        size => Maximum,
        kill => true,
        error_logger => false
    }}].

bounded_operation(parse, Bin, Config) ->
    parse_binary(Bin, Config);
bounded_operation(html, Bin, Config) ->
    case parse_binary(Bin, Config) of
        {ok, Tree} -> {ok, markdownz_html:render(Tree, Config)};
        Error -> Error
    end;
bounded_operation(binary, Bin, Config) ->
    case bounded_operation(html, Bin, Config) of
        {ok, Html} -> {ok, iolist_to_binary(Html)};
        Error -> Error
    end.

await_bounded(Pid, MonitorRef, ReplyRef, infinity) ->
    receive_bounded(Pid, MonitorRef, ReplyRef);
await_bounded(Pid, MonitorRef, ReplyRef, Timeout) ->
    receive
        {ReplyRef, Result} ->
            erlang:demonitor(MonitorRef, [flush]),
            Result;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            bounded_down(Reason)
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', MonitorRef, process, Pid, _Reason} -> ok end,
        flush_reply(ReplyRef),
        {error, timeout, #{limit => Timeout}}
    end.

receive_bounded(Pid, MonitorRef, ReplyRef) ->
    receive
        {ReplyRef, Result} ->
            erlang:demonitor(MonitorRef, [flush]),
            Result;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            bounded_down(Reason)
    end.

bounded_down(killed) ->
    {error, resource_limit, #{reason => max_heap_size}};
bounded_down(Reason) ->
    {error, parser_crash, #{reason => Reason}}.

bounded_crash_reason(Reason) when is_atom(Reason) -> Reason;
bounded_crash_reason({Tag, _Details}) when is_atom(Tag) -> Tag;
bounded_crash_reason(_Reason) -> unexpected_error.

flush_reply(ReplyRef) ->
    receive {ReplyRef, _Result} -> ok after 0 -> ok end.

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
