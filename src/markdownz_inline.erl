%% @doc Inline Markdown rules. Rules consume the beginning of a binary and
%% return z_html_parse compatible nodes.
-module(markdownz_inline).

-export([
    default_rules/0,
    parse/2,
    decode_entities/1,
    normalize_destination/1,
    normalize_link_text/1,
    rule_escape/2,
    rule_image/2,
    rule_link/2,
    rule_autolink/2,
    rule_linkify/2,
    rule_code/2,
    rule_strong/2,
    rule_emphasis/2,
    rule_strikethrough/2,
    rule_subscript/2,
    rule_superscript/2,
    rule_newline/2,
    rule_entity/2,
    rule_html/2,
    rule_text/2
]).

-type html_element() :: markdownz:html_element().
-type state() :: map().
-type result() :: nomatch | {ok, [html_element()], binary(), state()}.

-spec default_rules() -> markdownz_ruler:ruler().
default_rules() ->
    markdownz_ruler:new([
        {escape, {?MODULE, rule_escape}},
        {image, {?MODULE, rule_image}},
        {link, {?MODULE, rule_link}},
        {autolink, {?MODULE, rule_autolink}},
        {linkify, {?MODULE, rule_linkify}},
        {code, {?MODULE, rule_code}},
        {strong, {?MODULE, rule_strong}},
        {emphasis, {?MODULE, rule_emphasis}},
        {strikethrough, {?MODULE, rule_strikethrough}},
        {subscript, {?MODULE, rule_subscript}},
        {superscript, {?MODULE, rule_superscript}},
        {newline, {?MODULE, rule_newline}},
        {entity, {?MODULE, rule_entity}},
        {html, {?MODULE, rule_html}},
        {text, {?MODULE, rule_text}}
    ]).

-spec parse(binary(), state()) -> {[html_element()], state()}.
parse(Source, State) ->
    Config = maps:get(config, State),
    #{rulers := #{inline := Ruler}} = Config,
    InitialState = maps:without(
        [markdownz_emphasis_plan, markdownz_inline_offset],
        State#{prev => none}),
    Plan = markdownz_emphasis:plan(Source, InitialState),
    parse_loop(Source, InitialState#{
        markdownz_emphasis_plan => Plan,
        markdownz_inline_offset => 0
    }, markdownz_ruler:rules(Ruler), []).

parse_loop(<<>>, State, _Rules, Acc) ->
    Nodes = merge_text(lists:reverse(Acc)),
    CleanState = maps:without(
        [markdownz_emphasis_plan, markdownz_inline_offset], State),
    {normalize_break_spacing(Nodes), CleanState};
parse_loop(Source, State, Rules, Acc) ->
    case run_rules(Rules, Source, State) of
        {ok, Nodes, Rest, State1} when byte_size(Rest) < byte_size(Source) ->
            State2 = update_previous(Source, Rest, State, State1),
            parse_loop(Rest, State2, Rules, lists:reverse(Nodes, Acc));
        nomatch ->
            %% A custom ruler may disable the fallback text rule.
            <<Char/utf8, Rest/binary>> = Source,
            Offset = maps:get(markdownz_inline_offset, State),
            parse_loop(Rest, State#{
                prev := Char,
                markdownz_inline_offset := Offset + byte_size(<<Char/utf8>>)
            }, Rules, [<<Char/utf8>> | Acc])
    end.

run_rules([], _Source, _State) ->
    nomatch;
run_rules([#{handler := Handler} | Rest], Source, State) ->
    case call(Handler, Source, State) of
        nomatch -> run_rules(Rest, Source, State);
        Result -> Result
    end.

call(Fun, Source, State) when is_function(Fun, 2) -> Fun(Source, State);
call({Module, Function}, Source, State) -> Module:Function(Source, State).

-spec rule_escape(binary(), state()) -> result().
rule_escape(<<$\\, $\n, Rest/binary>>, State) ->
    {ok, [{<<"br">>, [], []}, <<"\n">>], Rest, State};
rule_escape(<<$\\, Char/utf8, Rest/binary>>, State) ->
    case is_escapable(Char) of
        true -> {ok, [typographer_literal(<<Char/utf8>>, State)], Rest, State};
        false -> nomatch
    end;
rule_escape(_, _) ->
    nomatch.

-spec rule_image(binary(), state()) -> result().
rule_image(<<"![", Rest/binary>>, State) ->
    case take_label(Rest) of
        {ok, Label, AfterLabel} ->
            case link_target(Label, AfterLabel, State) of
                {ok, Destination, Title, Tail} ->
                    case safe_url(Destination, image) of
                        true ->
                            Attrs = add_title([
                                {<<"src">>, Destination},
                                {<<"alt">>, plain_text(Label, State)}
                            ], Title),
                            {ok, [{<<"img">>, Attrs, []}], Tail, State};
                        false -> nomatch
                    end;
                nomatch -> nomatch
            end;
        nomatch -> nomatch
    end;
rule_image(_, _) ->
    nomatch.

-spec rule_link(binary(), state()) -> result().
rule_link(<<$[, Rest/binary>>, State) ->
    case take_label(Rest) of
        {ok, Label, AfterLabel} ->
            case link_target(Label, AfterLabel, State) of
                {ok, Destination, Title, Tail} ->
                    case safe_url(Destination, link) of
                        true ->
                            {Children, _} = parse(Label, State),
                            case contains_link(Children) of
                                true -> nomatch;
                                false ->
                                    Attrs = add_title(
                                        [{<<"href">>, Destination}], Title),
                                    {ok, [{<<"a">>, Attrs, Children}], Tail, State}
                            end;
                        false -> nomatch
                    end;
                nomatch -> nomatch
            end;
        nomatch -> nomatch
    end;
rule_link(_, _) ->
    nomatch.

-spec rule_autolink(binary(), state()) -> result().
rule_autolink(<<$<, _/binary>> = Source, State) ->
    case capture(Source, <<"^<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^ <>]*)>">>) of
        {ok, Whole, Url} ->
            Href = normalize_destination(Url),
            case safe_url(Href, link) of
                true ->
                    Rest = drop_prefix(Source, Whole),
                    Text = normalize_link_text(Url),
                    {ok, [{<<"a">>, [{<<"href">>, Href}], [Text]}], Rest, State};
                false -> nomatch
            end;
        nomatch ->
            case capture(Source, <<"^<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,})>">>) of
                {ok, Whole, Email} ->
                    Rest = drop_prefix(Source, Whole),
                    RawHref = <<"mailto:", Email/binary>>,
                    Href = normalize_destination(RawHref),
                    Text = drop_prefix(normalize_link_text(RawHref), <<"mailto:">>),
                    {ok, [{<<"a">>, [{<<"href">>, Href}], [Text]}], Rest, State};
                nomatch -> nomatch
            end
    end;
rule_autolink(_, _) ->
    nomatch.

-spec rule_linkify(binary(), state()) -> result().
rule_linkify(Source, #{config := #{options := #{linkify := true}}} = State) ->
    case linkify_match(Source) of
        {ok, Whole, Display0, Kind} ->
            Display = trim_url_punctuation(Display0),
            ExtraSize = byte_size(Display0) - byte_size(Display),
            ConsumedSize = byte_size(Whole) - ExtraSize,
            <<_Consumed:ConsumedSize/binary, Rest/binary>> = Source,
            RawHref = linkify_href(Display, Kind),
            Href = normalize_destination(RawHref),
            case safe_url(Href, link) of
                true ->
                    Text = linkify_text(RawHref, Kind, Display),
                    {ok, [{<<"a">>, [{<<"href">>, Href}], [Text]}], Rest, State};
                false -> nomatch
            end;
        nomatch -> nomatch
    end;
rule_linkify(_, _) ->
    nomatch.

linkify_match(Source) ->
    case capture(Source, <<"^(https?://[^\\s<>]+|www\\.[^\\s<>]+|//[^\\s<>]+)">>) of
        {ok, Whole, Display} ->
            {ok, Whole, Display, url};
        nomatch ->
            case capture(Source,
                    <<"^([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
                      "[A-Za-z0-9.-]+\\.[A-Za-z]{2,})">>) of
                {ok, Whole, Display} -> {ok, Whole, Display, email};
                nomatch -> nomatch
            end
    end.

linkify_href(Display, email) ->
    <<"mailto:", Display/binary>>;
linkify_href(<<"www.", _/binary>> = Display, url) ->
    <<"http://", Display/binary>>;
linkify_href(Display, url) ->
    Display.

linkify_text(RawHref, email, _Display) ->
    drop_prefix(normalize_link_text(RawHref), <<"mailto:">>);
linkify_text(<<"http://", _/binary>> = RawHref, url, <<"www.", _/binary>>) ->
    drop_prefix(normalize_link_text(RawHref), <<"http://">>);
linkify_text(RawHref, url, _Display) ->
    normalize_link_text(RawHref).

-spec rule_code(binary(), state()) -> result().
rule_code(<<$`, _/binary>> = Source, State) ->
    {Count, AfterOpen} = count_prefix(Source, $`),
    case find_code_close(AfterOpen, Count, 0) of
        {ok, Position} ->
            <<Content0:Position/binary, _Close:Count/binary, Rest/binary>> = AfterOpen,
            Content1 = binary:replace(Content0, <<"\n">>, <<" ">>, [global]),
            Content = normalize_code_space(Content1),
            {ok, [{<<"code">>, [], [Content]}], Rest, State};
        nomatch -> nomatch
    end;
rule_code(_, _) ->
    nomatch.

find_code_close(Bin, Count, Offset) ->
    SearchSize = byte_size(Bin) - Offset,
    <<_Before:Offset/binary, Search:SearchSize/binary>> = Bin,
    case binary:match(Search, <<$`>>) of
        {Relative, 1} ->
            Position = Offset + Relative,
            <<_Prefix:Position/binary, RunAndRest/binary>> = Bin,
            {RunCount, _Rest} = count_prefix(RunAndRest, $`),
            case RunCount of
                Count -> {ok, Position};
                _ -> find_code_close(Bin, Count, Position + RunCount)
            end;
        nomatch -> nomatch
    end.

-spec rule_strong(binary(), state()) -> result().
rule_strong(<<Marker, Marker, _/binary>> = Source, State)
        when Marker =:= $*; Marker =:= $_ ->
    markdownz_emphasis:resolve(Source, State);
rule_strong(_, _) ->
    nomatch.

-spec rule_emphasis(binary(), state()) -> result().
rule_emphasis(<<Marker, Rest/binary>> = Source, State)
        when Marker =:= $*; Marker =:= $_ ->
    case Rest of
        <<Marker, _/binary>> -> nomatch;
        _ -> markdownz_emphasis:resolve(Source, State)
    end;
rule_emphasis(_, _) ->
    nomatch.

-spec rule_strikethrough(binary(), state()) -> result().
rule_strikethrough(Source, #{config := #{options := Options}} = State) ->
    delimited(Source, <<"~~">>, <<"del">>, State, maps:get(strikethrough, Options, true)).

-spec rule_subscript(binary(), state()) -> result().
rule_subscript(<<$~, Next/utf8, _/binary>> = Source,
               #{config := #{options := Options}} = State) when Next =/= $~ ->
    delimited_no_space(Source, <<"~">>, <<"sub">>, State, maps:get(subscript, Options, true));
rule_subscript(_, _) ->
    nomatch.

-spec rule_superscript(binary(), state()) -> result().
rule_superscript(Source, #{config := #{options := Options}} = State) ->
    delimited_no_space(Source, <<"^">>, <<"sup">>, State, maps:get(superscript, Options, true)).

-spec rule_newline(binary(), state()) -> result().
rule_newline(<<"  \n", Rest/binary>>, State) ->
    {ok, [{<<"br">>, [], []}, <<"\n">>], Rest, State};
rule_newline(<<$\n, Rest/binary>>, #{config := #{options := Options}} = State) ->
    Node = case maps:get(breaks, Options, false) of
        true -> [{<<"br">>, [], []}, <<"\n">>];
        false -> <<"\n">>
    end,
    {ok, case Node of Nodes when is_list(Nodes) -> Nodes; _ -> [Node] end, Rest, State};
rule_newline(_, _) ->
    nomatch.

-spec rule_entity(binary(), state()) -> result().
rule_entity(<<$&, _/binary>> = Source, State) ->
    case re:run(Source, <<"^&#([xX][0-9A-Fa-f]{1,6}|[0-9]{1,7});|^&([A-Za-z][A-Za-z0-9]+);">>,
                [{capture, [0, 1, 2], binary}]) of
        {match, [Whole, Number, <<>>]} ->
            case numeric_entity(Number) of
                {ok, Char} ->
                    Text = typographer_literal(<<Char/utf8>>, State),
                    {ok, [Text], drop_prefix(Source, Whole), State};
                error -> nomatch
            end;
        {match, [Whole, <<>>, Name]} ->
            case named_entity(Name) of
                undefined -> nomatch;
                Value ->
                    Text = typographer_literal(Value, State),
                    {ok, [Text], drop_prefix(Source, Whole), State}
            end;
        nomatch -> nomatch
    end;
rule_entity(_, _) ->
    nomatch.

typographer_literal(Text, State) ->
    case built_in_typographer_enabled(State) of
        true -> {<<"markdownz-literal">>, [], [Text]};
        false -> Text
    end.

built_in_typographer_enabled(#{config := #{
        options := Options,
        rulers := #{core := CoreRuler}
    }}) ->
    maps:get(typographer, Options, false)
        andalso lists:any(
            fun
                (#{name := typographer,
                   handler := {markdownz_core, typographer}}) -> true;
                (_) -> false
            end,
            markdownz_ruler:rules(CoreRuler)).

-spec rule_html(binary(), state()) -> result().
rule_html(<<$<, _/binary>> = Source,
          #{config := #{options := #{html := true}}} = State) ->
    Pattern = <<
        "^(?:"
        "<!---?>|<!--(?:[^-]|-[^-]|--[^>])*-->"
        "|<\\?[\\s\\S]*?\\?>"
        "|<!\\[CDATA\\[[\\s\\S]*?\\]\\]>"
        "|<![A-Z]+(?:\\s+[^>]*)?>"
        "|</[A-Za-z][A-Za-z0-9-]*\\s*>"
        "|<[A-Za-z][A-Za-z0-9-]*"
        "(?:\\s+[A-Za-z_:][A-Za-z0-9_.:-]*"
        "(?:\\s*=\\s*(?:[^\\s\"'=<>\x60]+|'[^']*'|\"[^\"]*\"))?)*"
        "\\s*/?>"
        ")"
    >>,
    case re:run(Source, Pattern, [{capture, [0], binary}, unicode]) of
        {match, [Html]} -> {ok, [{'=', Html}], drop_prefix(Source, Html), State};
        nomatch -> nomatch
    end;
rule_html(_, _) ->
    nomatch.

-spec rule_text(binary(), state()) -> result().
rule_text(<<$`, _/binary>> = Source, State) ->
    {Count, Rest} = count_prefix(Source, $`),
    Marker = binary:copy(<<$`>>, Count),
    {ok, [Marker], Rest, State};
rule_text(<<Char, _/binary>> = Source, State)
        when Char =:= $*; Char =:= $_ ->
    {Count, Rest} = count_prefix(Source, Char),
    Marker = binary:copy(<<Char>>, Count),
    {ok, [Marker], Rest, State};
rule_text(<<Char/utf8, Rest/binary>>, State) ->
    {ok, [<<Char/utf8>>], Rest, State};
rule_text(<<>>, _State) ->
    nomatch.

delimited(_Source, _Marker, _Tag, _State, false) ->
    nomatch;
delimited(Source, Marker, Tag, State, true) ->
    MarkerSize = byte_size(Marker),
    case Source of
        <<Open:MarkerSize/binary, Tail/binary>> when Open =:= Marker ->
            case can_open(Tail, maps:get(prev, State, none), Marker) of
                false -> nomatch;
                true ->
                    case find_close(Tail, Marker) of
                        {ok, Content, Rest} when Content =/= <<>> ->
                            {Children, _} = parse(Content, State),
                            {ok, [{Tag, [], Children}], Rest, State};
                        _ -> nomatch
                    end
            end;
        _ -> nomatch
    end.

delimited_no_space(_Source, _Marker, _Tag, _State, false) ->
    nomatch;
delimited_no_space(Source, Marker, Tag, State, true) ->
    MarkerSize = byte_size(Marker),
    case Source of
        <<Open:MarkerSize/binary, Tail/binary>> when Open =:= Marker ->
            case binary:match(Tail, Marker) of
                {Position, _} when Position > 0 ->
                    <<Content:Position/binary, _Close:MarkerSize/binary, Rest/binary>> = Tail,
                    case has_space(Content) of
                        true -> nomatch;
                        false ->
                            Unescaped = unescape_delimiter(Content, Marker),
                            {ok, [{Tag, [], [Unescaped]}], Rest, State}
                    end;
                _ -> nomatch
            end;
        _ -> nomatch
    end.

find_close(Tail, Marker) ->
    case find_close(Tail, Marker, 0, 0) of
        nomatch -> find_close_simple(Tail, Marker, 0);
        Result -> Result
    end.

find_close_simple(Tail, Marker, Offset) ->
    SearchSize = byte_size(Tail) - Offset,
    <<_Skip:Offset/binary, Search:SearchSize/binary>> = Tail,
    case binary:match(Search, Marker) of
        {Relative, MarkerSize} ->
            Position = Offset + Relative,
            AfterPosition = Position + MarkerSize,
            <<Content:Position/binary, _Close:MarkerSize/binary, Rest/binary>> =
                Tail,
            case is_escaped_delimiter(Content)
                    orelse inside_angle(Content)
                    orelse inside_code_span(Content) of
                true ->
                    NextOffset = case is_escaped_delimiter(Content) of
                        true -> Position + 1;
                        false -> AfterPosition
                    end,
                    find_close_simple(Tail, Marker, NextOffset);
                false ->
                    {FinalContent, FinalRest} =
                        adjust_close_run(Content, Rest, Marker),
                    case inside_link_label(FinalContent, FinalRest)
                            orelse not can_close(
                                FinalContent, FinalRest, Marker) of
                        true -> find_close_simple(Tail, Marker, AfterPosition);
                        false -> {ok, FinalContent, FinalRest}
                    end
            end;
        nomatch -> nomatch
    end.

find_close(Tail, Marker, Offset, Depth) ->
    SearchSize = byte_size(Tail) - Offset,
    <<_Skip:Offset/binary, Search:SearchSize/binary>> = Tail,
    case binary:match(Search, Marker) of
        {Relative, MarkerSize} ->
            Position = Offset + Relative,
            AfterPosition = Position + MarkerSize,
            <<Content:Position/binary, _Close:MarkerSize/binary, Rest/binary>> = Tail,
            <<_BeforeRun:Position/binary, Run/binary>> = Tail,
            <<MarkerChar, _/binary>> = Marker,
            {RunCount, RunRest} = count_prefix(Run, MarkerChar),
            RunAfterPosition = Position + RunCount,
            RunOpen = can_open(
                RunRest, last_codepoint_or_none(Content), Marker),
            RunClose = can_close(Content, RunRest, Marker),
            case is_escaped_delimiter(Content) of
                true ->
                    find_close(Tail, Marker, Position + 1, Depth);
                false when RunCount > MarkerSize, Depth > 0, RunClose ->
                    find_close(Tail, Marker, RunAfterPosition, Depth - 1);
                false when RunCount > MarkerSize, RunOpen, not RunClose ->
                    find_close(Tail, Marker, RunAfterPosition, Depth + 1);
                false when RunCount > MarkerSize, RunOpen, RunClose,
                        Depth =:= 0 ->
                    find_close(Tail, Marker, RunAfterPosition, 1);
                false ->
                    find_close_candidate(
                        Tail, Marker, AfterPosition, Content, Rest, Depth)
            end;
        nomatch -> nomatch
    end.

find_close_candidate(Tail, Marker, AfterPosition, Content, Rest, Depth) ->
    case inside_angle(Content) orelse inside_code_span(Content) of
                true -> find_close(Tail, Marker, AfterPosition, Depth);
                false ->
                    {FinalContent, FinalRest} = adjust_close_run(Content, Rest, Marker),
                    case inside_link_label(FinalContent, FinalRest) of
                        true -> find_close(Tail, Marker, AfterPosition, Depth);
                        false ->
                            Open = can_open(
                                FinalRest,
                                last_codepoint_or_none(FinalContent),
                                Marker),
                            Close = can_close(FinalContent, FinalRest, Marker),
                            case {Depth, Open, Close} of
                                {0, _, true} ->
                                    {ok, FinalContent, FinalRest};
                                {Nested, _, true} when Nested > 0 ->
                                    find_close(
                                        Tail, Marker, AfterPosition, Nested - 1);
                                {Nested, true, false} ->
                                    find_close(
                                        Tail, Marker, AfterPosition, Nested + 1);
                                _ ->
                                    find_close(Tail, Marker, AfterPosition, Depth)
                            end
                    end
    end.

is_escaped_delimiter(Content) ->
    trailing_backslashes(Content, 0) rem 2 =:= 1.

trailing_backslashes(<<>>, Count) -> Count;
trailing_backslashes(Content, Count) ->
    case binary:last(Content) of
        $\\ ->
            Size = byte_size(Content) - 1,
            trailing_backslashes(binary:part(Content, 0, Size), Count + 1);
        _ -> Count
    end.

adjust_close_run(Content, <<Char, Rest/binary>>, <<Char, Char>>) ->
    case binary:match(Content, <<Char>>) of
        nomatch -> {Content, <<Char, Rest/binary>>};
        _ -> {<<Content/binary, Char>>, Rest}
    end;
adjust_close_run(Content, Rest, _Marker) ->
    {Content, Rest}.

inside_angle(Content) ->
    case {last_position(Content, $<), last_position(Content, $>)} of
        {none, _} -> false;
        {{ok, _Open}, none} -> true;
        {{ok, Open}, {ok, Close}} -> Open > Close
    end.

inside_link_label(Content, Rest) ->
    case {last_position(Content, $[), last_position(Content, $])} of
        {none, _} -> false;
        {{ok, Open}, {ok, Close}} when Open =< Close -> false;
        _ ->
            case binary:match(Rest, <<"]">>) of
                {ClosePosition, 1} ->
                    AfterPosition = ClosePosition + 1,
                    <<_ThroughClose:AfterPosition/binary, After/binary>> = Rest,
                    case After of
                        <<$(, _/binary>> -> true;
                        <<$[, _/binary>> -> true;
                        _ -> false
                    end;
                nomatch -> false
            end
    end.

inside_code_span(Content) ->
    inside_code_span(Content, none).

inside_code_span(<<>>, State) ->
    State =/= none;
inside_code_span(<<$`, _/binary>> = Content, State) ->
    {Count, Rest} = count_prefix(Content, $`),
    NextState = case State of
        none -> Count;
        Count -> none;
        _ -> State
    end,
    inside_code_span(Rest, NextState);
inside_code_span(<<_Char/utf8, Rest/binary>>, State) ->
    inside_code_span(Rest, State).

last_position(Bin, Char) ->
    case binary:matches(Bin, <<Char>>) of
        [] -> none;
        Matches -> {Position, _} = lists:last(Matches), {ok, Position}
    end.

can_open(Tail, Previous, Marker) ->
    Next = first_codepoint(Tail),
    {LeftFlanking, RightFlanking} = delimiter_flanking(Previous, Next),
    case Marker of
        <<$_, _/binary>> ->
            LeftFlanking andalso
                (not RightFlanking orelse is_punctuation(Previous));
        _ -> LeftFlanking
    end.

can_close(Content, Rest, Marker) ->
    Previous = last_codepoint_or_none(Content),
    Next = first_codepoint(Rest),
    {LeftFlanking, RightFlanking} = delimiter_flanking(Previous, Next),
    case Marker of
        <<$_, _/binary>> ->
            RightFlanking andalso
                (not LeftFlanking orelse is_punctuation(Next));
        _ -> RightFlanking
    end.

delimiter_flanking(Previous, Next) ->
    Left = not is_space_or_boundary(Next)
        andalso (not is_punctuation(Next)
            orelse is_space_or_boundary(Previous)
            orelse is_punctuation(Previous)),
    Right = not is_space_or_boundary(Previous)
        andalso (not is_punctuation(Previous)
            orelse is_space_or_boundary(Next)
            orelse is_punctuation(Next)),
    {Left, Right}.

first_codepoint(<<Char/utf8, _/binary>>) -> Char;
first_codepoint(<<>>) -> none.

last_codepoint_or_none(<<>>) -> none;
last_codepoint_or_none(Bin) -> last_codepoint(Bin).

is_space_or_boundary(none) -> true;
is_space_or_boundary(Char) ->
    is_space(Char) orelse
        re:run(<<Char/utf8>>, <<"^[\\p{Z}]$">>,
            [unicode, {capture, none}]) =:= match.

is_punctuation(none) -> false;
is_punctuation(Char) ->
    re:run(<<Char/utf8>>, <<"^[\\p{P}\\p{S}]$">>,
        [unicode, {capture, none}]) =:= match.

link_target(Label, <<$(, Tail/binary>> = AfterLabel, State) ->
    case take_link_inside(Tail) of
        {ok, Inside, Rest} ->
            case split_destination_title(trim(Inside)) of
                {ok, Destination0, Title0} ->
                    Destination = normalize_destination(
                        decode_entities(unescape_punctuation(
                            strip_angle(Destination0)))),
                    Title = maybe_unescape(Title0),
                    {ok, Destination, Title, Rest};
                nomatch -> lookup_reference(Label, AfterLabel, State)
            end;
        nomatch -> lookup_reference(Label, AfterLabel, State)
    end;
link_target(Label, AfterLabel, State) ->
    case reference_label(AfterLabel) of
        {<<>>, Rest} -> lookup_reference(Label, Rest, State);
        {Reference, Rest} -> lookup_reference(Reference, Rest, State);
        none -> lookup_reference(Label, AfterLabel, State)
    end.

lookup_reference(Label, Rest, State) ->
    References = maps:get(references, State, #{}),
    Key = normalize_label(Label),
    case maps:find(Key, References) of
        {ok, #{destination := Destination, title := Title}} ->
            {ok, Destination, Title, Rest};
        error -> nomatch
    end.

reference_label(<<$[, Rest/binary>>) ->
    case take_label(Rest) of
        {ok, Label, Tail} -> {Label, Tail};
        nomatch -> none
    end;
reference_label(_) -> none.

take_label(Bin) ->
    take_label(Bin, none, 0, []).

take_label(<<>>, _CodeRun, _Depth, _Acc) ->
    nomatch;
take_label(<<$\\, Char/utf8, Rest/binary>>, CodeRun, Depth, Acc) ->
    take_label(Rest, CodeRun, Depth, [<<$\\, Char/utf8>> | Acc]);
take_label(<<$<, Rest/binary>>, none, Depth, Acc) ->
    case take_angle_fragment(Rest, [<<$<>>]) of
        {ok, Fragment, Tail} ->
            take_label(Tail, none, Depth, [Fragment | Acc]);
        nomatch ->
            take_label(Rest, none, Depth, [<<$<>> | Acc])
    end;
take_label(<<$`, _/binary>> = Bin, CodeRun, Depth, Acc) ->
    {Count, Rest} = count_prefix(Bin, $`),
    Marker = binary:copy(<<$`>>, Count),
    NextCodeRun = case CodeRun of
        none -> Count;
        Count -> none;
        _ -> CodeRun
    end,
    take_label(Rest, NextCodeRun, Depth, [Marker | Acc]);
take_label(<<$], Rest/binary>>, none, 0, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc)), Rest};
take_label(<<$], Rest/binary>>, none, Depth, Acc) ->
    take_label(Rest, none, Depth - 1, [<<$]>> | Acc]);
take_label(<<$[, Rest/binary>>, none, Depth, Acc) ->
    take_label(Rest, none, Depth + 1, [<<$[>> | Acc]);
take_label(<<Char/utf8, Rest/binary>>, CodeRun, Depth, Acc) ->
    take_label(Rest, CodeRun, Depth, [<<Char/utf8>> | Acc]).

take_angle_fragment(<<$>, Rest/binary>>, Acc) ->
    {ok, iolist_to_binary(lists:reverse([<<62>> | Acc])), Rest};
take_angle_fragment(<<Char/utf8, Rest/binary>>, Acc) ->
    take_angle_fragment(Rest, [<<Char/utf8>> | Acc]);
take_angle_fragment(<<>>, _Acc) ->
    nomatch.

take_until_unescaped(Bin, Stop) ->
    take_until_unescaped(Bin, Stop, []).

take_until_unescaped(<<>>, _Stop, _Acc) -> nomatch;
take_until_unescaped(<<$\\, Char/utf8, Rest/binary>>, Stop, Acc) ->
    take_until_unescaped(Rest, Stop, [<<$\\, Char/utf8>> | Acc]);
take_until_unescaped(<<Stop, Rest/binary>>, Stop, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc)), Rest};
take_until_unescaped(<<Char/utf8, Rest/binary>>, Stop, Acc) ->
    take_until_unescaped(Rest, Stop, [<<Char/utf8>> | Acc]).

split_destination_title(Inside) ->
    case take_destination(trim(Inside)) of
        {ok, Destination, Rest} ->
            case take_link_title(string:trim(Rest, leading, " \t\r\n")) of
                {ok, Title} -> {ok, Destination, Title};
                nomatch -> nomatch
            end;
        nomatch -> nomatch
    end.

take_destination(<<>>) ->
    {ok, <<>>, <<>>};
take_destination(<<$<, Rest/binary>>) ->
    take_angle_destination(Rest, []);
take_destination(Bin) ->
    take_plain_destination(Bin, []).

take_angle_destination(<<$>, Rest/binary>>, Acc) ->
    Destination = iolist_to_binary(lists:reverse(Acc)),
    {ok, <<$<, Destination/binary, 62>>, Rest};
take_angle_destination(<<$\\, _/binary>>, _Acc) ->
    nomatch;
take_angle_destination(<<Char/utf8, Rest/binary>>, Acc)
        when Char =/= $<, Char =/= $\n ->
    take_angle_destination(Rest, [<<Char/utf8>> | Acc]);
take_angle_destination(_, _Acc) ->
    nomatch.

take_plain_destination(<<Char/utf8, _/binary>> = Rest, Acc)
        when Char =:= $\s; Char =:= $\t; Char =:= $\r; Char =:= $\n ->
    {ok, iolist_to_binary(lists:reverse(Acc)), Rest};
take_plain_destination(<<Char/utf8, Rest/binary>>, Acc) ->
    take_plain_destination(Rest, [<<Char/utf8>> | Acc]);
take_plain_destination(<<>>, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc)), <<>>}.

take_link_title(<<>>) ->
    {ok, undefined};
take_link_title(<<$\", Rest/binary>>) ->
    complete_title(Rest, $\");
take_link_title(<<$', Rest/binary>>) ->
    complete_title(Rest, $');
take_link_title(<<$(, Rest/binary>>) ->
    complete_title(Rest, $));
take_link_title(_) ->
    nomatch.

complete_title(Bin, Close) ->
    case take_until_unescaped(Bin, Close) of
        {ok, Title, <<>>} -> {ok, Title};
        _ -> nomatch
    end.

take_link_inside(Bin) ->
    take_link_inside(Bin, normal, 0, []).

take_link_inside(<<>>, _Mode, _Depth, _Acc) ->
    nomatch;
take_link_inside(<<$\\, Char/utf8, Rest/binary>>, Mode, Depth, Acc) ->
    take_link_inside(Rest, Mode, Depth, [<<$\\, Char/utf8>> | Acc]);
take_link_inside(<<$<, Rest/binary>>, normal, Depth, Acc) ->
    take_link_inside(Rest, angle, Depth, [<<$<>> | Acc]);
take_link_inside(<<$>, Rest/binary>>, angle, Depth, Acc) ->
    take_link_inside(Rest, normal, Depth, [<<$>>> | Acc]);
take_link_inside(<<$(, Rest/binary>>, normal, Depth, Acc) ->
    take_link_inside(Rest, normal, Depth + 1, [<<$(>> | Acc]);
take_link_inside(<<$), Rest/binary>>, normal, 0, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc)), Rest};
take_link_inside(<<$), Rest/binary>>, normal, Depth, Acc) ->
    take_link_inside(Rest, normal, Depth - 1, [<<$)>> | Acc]);
take_link_inside(<<Char/utf8, Rest/binary>>, Mode, Depth, Acc) ->
    take_link_inside(Rest, Mode, Depth, [<<Char/utf8>> | Acc]).

contains_link([{<<"a">>, _, _} | _]) -> true;
contains_link([{_Tag, _, Children} | Rest]) ->
    contains_link(Children) orelse contains_link(Rest);
contains_link([_ | Rest]) -> contains_link(Rest);
contains_link([]) -> false.

add_title(Attrs, undefined) -> Attrs;
add_title(Attrs, Title) -> Attrs ++ [{<<"title">>, Title}].

plain_text(Label, State) ->
    {Nodes, _} = parse(Label, State),
    iolist_to_binary(plain_nodes(Nodes)).

plain_nodes(Nodes) ->
    [case Node of
         Text when is_binary(Text) -> Text;
         {<<"img">>, Attrs, _Children} ->
             proplists:get_value(<<"alt">>, Attrs, <<>>);
         {_Tag, _Attrs, Children} -> plain_nodes(Children);
         {'=', Html} -> Html
     end || Node <- Nodes].

safe_url(Url, Kind) ->
    Lower = string:lowercase(trim(Url)),
    case re:run(Lower, <<"^(javascript|vbscript|file):">>, [{capture, none}]) of
        match -> false;
        nomatch ->
            case {Kind, re:run(Lower, <<"^data:">>, [{capture, none}])} of
                {link, match} -> false;
                {image, match} ->
                    re:run(Lower, <<"^data:image/(gif|png|jpeg|webp);">>, [{capture, none}]) =:= match;
                _ -> true
            end
    end.

capture(Source, Pattern) ->
    case re:run(Source, Pattern, [{capture, [0, 1], binary}]) of
        {match, [Whole, Captured]} -> {ok, Whole, Captured};
        nomatch -> nomatch
    end.

numeric_entity(<<Prefix, Hex/binary>>) when Prefix =:= $x; Prefix =:= $X -> entity_integer(Hex, 16);
numeric_entity(Decimal) -> entity_integer(Decimal, 10).

entity_integer(Bin, Base) ->
    try binary_to_integer(Bin, Base) of
        Char when Char > 0, Char =< 16#10ffff, not (Char >= 16#d800 andalso Char =< 16#dfff) ->
            {ok, Char};
        _ -> {ok, 16#fffd}
    catch
        error:badarg -> error
    end.

named_entity(Name) ->
    Module = z_html_charref,
    case code:ensure_loaded(Module) of
        {module, Module} -> entity_to_binary(call_optional(Module, charref, [Name]));
        _ -> builtin_entity(Name)
    end.

%% Keep z_stdlib optional: consumers using it get its complete entity table,
%% while standalone users retain the built-in CommonMark entities below.
call_optional(Module, Function, Arguments) ->
    erlang:apply(Module, Function, Arguments).

builtin_entity(<<"amp">>) -> <<"&">>;
builtin_entity(<<"lt">>) -> <<"<">>;
builtin_entity(<<"gt">>) -> <<">">>;
builtin_entity(<<"quot">>) -> <<"\"">>;
builtin_entity(<<"apos">>) -> <<"'">>;
builtin_entity(<<"nbsp">>) -> <<16#c2, 16#a0>>;
builtin_entity(<<"copy">>) -> <<16#c2, 16#a9>>;
builtin_entity(<<"reg">>) -> <<16#c2, 16#ae>>;
builtin_entity(<<"AElig">>) -> <<198/utf8>>;
builtin_entity(<<"Dcaron">>) -> <<270/utf8>>;
builtin_entity(<<"ouml">>) -> <<246/utf8>>;
builtin_entity(<<"auml">>) -> <<228/utf8>>;
builtin_entity(<<"frac34">>) -> <<190/utf8>>;
builtin_entity(<<"HilbertSpace">>) -> <<8459/utf8>>;
builtin_entity(<<"DifferentialD">>) -> <<8518/utf8>>;
builtin_entity(<<"ClockwiseContourIntegral">>) -> <<8754/utf8>>;
builtin_entity(<<"ngE">>) -> <<8807/utf8, 824/utf8>>;
builtin_entity(_) -> undefined.

entity_to_binary(undefined) -> undefined;
entity_to_binary(Char) when is_integer(Char) -> <<Char/utf8>>;
entity_to_binary(Chars) when is_list(Chars) -> unicode:characters_to_binary(Chars).

normalize_code_space(<<$\s, Middle/binary>> = Content) when byte_size(Middle) > 0 ->
    case binary:last(Middle) =:= $\s andalso has_non_space(Content) of
        true -> binary:part(Middle, 0, byte_size(Middle) - 1);
        false -> Content
    end;
normalize_code_space(Content) -> Content.

has_non_space(Bin) ->
    re:run(Bin, <<"[^ ]">>, [{capture, none}]) =:= match.

trim_url_punctuation(Bin) ->
    case Bin of
        <<Rest:(byte_size(Bin)-1)/binary, Last>> when Last =:= $.; Last =:= $,; Last =:= $:; Last =:= $; ->
            trim_url_punctuation(Rest);
        _ -> Bin
    end.

strip_angle(<<$<, Rest/binary>>) when byte_size(Rest) > 0 ->
    case binary:last(Rest) of
        $> -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<$<, Rest/binary>>
    end;
strip_angle(Bin) -> Bin.

unescape_delimiter(Content, Marker) ->
    Escaped = <<$\\, Marker/binary>>,
    binary:replace(Content, Escaped, Marker, [global]).

maybe_unescape(undefined) -> undefined;
maybe_unescape(Value) -> decode_entities(unescape_punctuation(Value)).

-spec decode_entities(binary()) -> binary().
decode_entities(Bin) ->
    decode_entities(Bin, []).

decode_entities(<<>>, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
decode_entities(<<$&, _/binary>> = Bin, Acc) ->
    case re:run(Bin, <<"^&#([xX][0-9A-Fa-f]{1,6}|[0-9]{1,7});|^&([A-Za-z][A-Za-z0-9]+);">>,
                [{capture, [0, 1, 2], binary}]) of
        {match, [Whole, Number, <<>>]} ->
            case numeric_entity(Number) of
                {ok, Char} ->
                    decode_entities(drop_prefix(Bin, Whole), [<<Char/utf8>> | Acc]);
                error ->
                    <<Char, Rest/binary>> = Bin,
                    decode_entities(Rest, [<<Char>> | Acc])
            end;
        {match, [Whole, <<>>, Name]} ->
            case named_entity(Name) of
                undefined ->
                    <<Char, Rest/binary>> = Bin,
                    decode_entities(Rest, [<<Char>> | Acc]);
                Value ->
                    decode_entities(drop_prefix(Bin, Whole), [Value | Acc])
            end;
        nomatch ->
            <<Char, Rest/binary>> = Bin,
            decode_entities(Rest, [<<Char>> | Acc])
    end;
decode_entities(<<Char/utf8, Rest/binary>>, Acc) ->
    decode_entities(Rest, [<<Char/utf8>> | Acc]).

-spec normalize_destination(binary()) -> binary().
normalize_destination(Destination) ->
    markdownz_url:normalize(Destination).

-spec normalize_link_text(binary()) -> binary().
normalize_link_text(Url) ->
    markdownz_url:normalize_text(Url).

unescape_punctuation(Bin) ->
    unescape_punctuation(Bin, []).

unescape_punctuation(<<>>, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
unescape_punctuation(<<$\\, Char, Rest/binary>>, Acc) ->
    case is_escapable(Char) of
        true -> unescape_punctuation(Rest, [<<Char>> | Acc]);
        false -> unescape_punctuation(Rest, [<<$\\, Char>> | Acc])
    end;
unescape_punctuation(<<Char/utf8, Rest/binary>>, Acc) ->
    unescape_punctuation(Rest, [<<Char/utf8>> | Acc]).

normalize_label(Label) ->
    Collapsed = re:replace(trim(Label), <<"\\s+">>, <<" ">>,
        [global, {return, binary}, unicode]),
    string:casefold(Collapsed).

trim(Bin) -> string:trim(Bin, both, " \t\r\n").

has_space(Bin) ->
    re:run(Bin, <<"\\s">>, [{capture, none}]) =:= match.

drop_prefix(Source, Prefix) ->
    PrefixSize = byte_size(Prefix),
    <<_Prefix:PrefixSize/binary, Rest/binary>> = Source,
    Rest.

count_prefix(Bin, Char) -> count_prefix(Bin, Char, 0).
count_prefix(<<Char, Rest/binary>>, Char, Count) -> count_prefix(Rest, Char, Count + 1);
count_prefix(Rest, _Char, Count) -> {Count, Rest}.

update_previous(Source, Rest, PreviousState, State) ->
    ConsumedSize = byte_size(Source) - byte_size(Rest),
    <<Consumed:ConsumedSize/binary, _/binary>> = Source,
    Offset = maps:get(markdownz_inline_offset, PreviousState),
    Plan = maps:get(markdownz_emphasis_plan, PreviousState),
    State#{
        prev := last_codepoint(Consumed),
        markdownz_inline_offset => Offset + ConsumedSize,
        markdownz_emphasis_plan => Plan
    }.

last_codepoint(Bin) ->
    [Last | _] = lists:reverse(unicode:characters_to_list(Bin)),
    Last.

merge_text(Nodes) ->
    lists:reverse(merge_text(Nodes, [])).

merge_text([], Acc) -> Acc;
merge_text([Text | Rest], [Previous | Acc]) when is_binary(Text), is_binary(Previous) ->
    merge_text(Rest, [<<Previous/binary, Text/binary>> | Acc]);
merge_text([Node | Rest], Acc) ->
    merge_text(Rest, [Node | Acc]).

normalize_break_spacing(Nodes) ->
    lists:reverse(normalize_break_spacing(Nodes, [])).

normalize_break_spacing(
        [{<<"br">>, _, _} = Break | Rest],
        [Text | Acc]) when is_binary(Text) ->
    Trimmed = string:trim(Text, trailing, " "),
    normalize_break_spacing(Rest, [Break, Trimmed | Acc]);
normalize_break_spacing([Node | Rest], Acc) ->
    Normalized = case Node of
        Text when is_binary(Text) ->
            re:replace(Text, <<" +\\n">>, <<"\n">>,
                [global, {return, binary}]);
        _ -> Node
    end,
    normalize_break_spacing(Rest, [Normalized | Acc]);
normalize_break_spacing([], Acc) ->
    Acc.

is_escapable(Char) ->
    binary:match(<<"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~">>, <<Char>>) =/= nomatch.

is_space($\s) -> true;
is_space($\t) -> true;
is_space($\n) -> true;
is_space($\r) -> true;
is_space(_) -> false.
