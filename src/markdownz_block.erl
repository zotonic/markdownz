%% @doc Block-level Markdown parser.
-module(markdownz_block).

-export([
    default_rules/0,
    parse/2,
    parse_lines/2,
    rule_fence/2,
    rule_indented_code/2,
    rule_heading/2,
    rule_table/2,
    rule_hr/2,
    rule_blockquote/2,
    rule_list/2,
    rule_html/2,
    rule_paragraph/2
]).

-type html_element() :: markdownz:html_element().
-type state() :: map().
-type lines() :: [binary()].
-type result() :: nomatch | {ok, [html_element()], lines(), state()}.

-spec default_rules() -> markdownz_ruler:ruler().
default_rules() ->
    markdownz_ruler:new([
        {fence, {?MODULE, rule_fence}},
        {indented_code, {?MODULE, rule_indented_code}},
        {heading, {?MODULE, rule_heading}},
        {table, {?MODULE, rule_table}},
        {hr, {?MODULE, rule_hr}},
        {blockquote, {?MODULE, rule_blockquote}},
        {list, {?MODULE, rule_list}},
        {html, {?MODULE, rule_html}},
        {paragraph, {?MODULE, rule_paragraph}}
    ]).

-spec parse(binary(), markdownz:config()) -> {[html_element()], state()}.
parse(Source, Config) ->
    Normalized = normalize(Source),
    Lines0 = [normalize_line(Line) || Line <- binary:split(Normalized, <<"\n">>, [global])],
    {Lines, References} = extract_references(Lines0, #{}, [], none, boundary),
    State = #{config => Config, references => References, depth => 0},
    parse_lines(Lines, State).

-spec parse_lines(lines(), state()) -> {[html_element()], state()}.
parse_lines(Lines, State) ->
    Config = maps:get(config, State),
    #{rulers := #{block := Ruler}} = Config,
    parse_loop(Lines, State, markdownz_ruler:rules(Ruler), []).

parse_loop([], State, _Rules, Acc) ->
    {lists:reverse(Acc), State};
parse_loop([Line | Rest] = Lines, State, Rules, Acc) ->
    case is_blank_line(Line) of
        true -> parse_loop(drop_blank(Rest), State, Rules, Acc);
        false -> parse_nonblank(Lines, State, Rules, Acc)
    end.

parse_nonblank(Lines, State, Rules, Acc) ->
    case run_rules(Rules, Lines, State) of
        {ok, _Nodes, Lines, _State1} ->
            error(block_rule_did_not_consume_input);
        {ok, Nodes, Rest, State1} ->
            parse_loop(Rest, State1, Rules, lists:reverse(Nodes, Acc));
        nomatch ->
            %% A configuration without a fallback paragraph rule stays total.
            [Line | Rest] = Lines,
            {Children, State1} = inline(Line, State),
            parse_loop(Rest, State1, Rules, [{<<"p">>, [], Children} | Acc])
    end.

run_rules([], _Lines, _State) ->
    nomatch;
run_rules([#{handler := Handler} | Rules], Lines, State) ->
    case call(Handler, Lines, State) of
        nomatch -> run_rules(Rules, Lines, State);
        Result -> Result
    end.

call(Fun, Lines, State) when is_function(Fun, 2) -> Fun(Lines, State);
call({Module, Function}, Lines, State) -> Module:Function(Lines, State).

-spec rule_fence(lines(), state()) -> result().
rule_fence([Line | Rest], State) ->
    case fence_open(Line) of
        {ok, Char, Count, Indent, Info0} ->
            {CodeLines, Tail} = take_fence(Rest, Char, Count, Indent, []),
            Info = markdownz_inline:decode_entities(
                unescape_punctuation(first_word(trim(Info0)))),
            Content = code_content(CodeLines),
            Options = maps:get(options, maps:get(config, State)),
            {PreAttrs, CodeAttrs} = code_attrs(Info, Options),
            Node = {<<"pre">>, PreAttrs, [{<<"code">>, CodeAttrs, [Content]}]},
            {ok, [Node], Tail, State};
        nomatch -> nomatch
    end;
rule_fence([], _) ->
    nomatch.

-spec rule_indented_code(lines(), state()) -> result().
rule_indented_code([<<"    ", First/binary>> | Rest], State) ->
    {CodeLines, Tail} = take_indented(Rest, [First]),
    Node = {<<"pre">>, [], [{<<"code">>, [], [code_content(CodeLines)]}]},
    {ok, [Node], Tail, State};
rule_indented_code(_, _) ->
    nomatch.

-spec rule_heading(lines(), state()) -> result().
rule_heading(Lines, State) ->
    case rule_atx_heading(Lines, State) of
        nomatch -> rule_setext_heading(Lines, State);
        Result -> Result
    end.

rule_setext_heading([First | Rest], State) ->
    case can_start_setext(First, State) of
        true -> find_setext_heading(Rest, State, [normalize_paragraph_first(First)]);
        false -> nomatch
    end;
rule_setext_heading([], _State) ->
    nomatch.

find_setext_heading([Line | Rest], State, Acc) ->
    case setext_level(Line) of
        Level when Level =:= 1; Level =:= 2 ->
            Content0 = join_lines(lists:reverse(Acc)),
            Content = string:trim(Content0, trailing, " \t"),
            {Children, State1} = inline(Content, State),
            {ok, [{heading_tag(Level), [], Children}], Rest, State1};
        false ->
            case is_blank_line(Line) orelse interrupts_paragraph(Line, State) of
                true -> nomatch;
                false ->
                    find_setext_heading(
                        Rest,
                        State,
                        [normalize_paragraph_continuation(Line) | Acc])
            end
    end;
find_setext_heading([], _State, _Acc) ->
    nomatch.

can_start_setext(<<"    ", _/binary>>, _State) ->
    false;
can_start_setext(Line, State) ->
    Line =/= <<>>
        andalso fence_open(Line) =:= nomatch
        andalso list_marker(Line) =:= nomatch
        andalso quote_line(Line) =:= nomatch
        andalso not is_atx(Line)
        andalso not is_hr(Line)
        andalso not is_html_start(Line, State).

rule_atx_heading([Line | Rest], State) ->
    case re:run(Line, <<"^ {0,3}(#{1,6})(?:[ \\t]+|$)(.*)$">>,
                [{capture, [1, 2], binary}]) of
        {match, [Hashes, Text0]} ->
            Level = byte_size(Hashes),
            Text = trim_closing_hashes(Text0),
            {Children, State1} = inline(Text, State),
            {ok, [{heading_tag(Level), [], Children}], Rest, State1};
        nomatch -> nomatch
    end;
rule_atx_heading([], _) ->
    nomatch.

-spec rule_table(lines(), state()) -> result().
rule_table([Header, Delimiter | Rest],
           #{config := #{options := Options}} = State) ->
    case maps:get(tables, Options, true) of
        false -> nomatch;
        true ->
            HeaderCells = split_table_row(Header),
            DelimiterCells = split_table_row(Delimiter),
            case table_alignments(DelimiterCells) of
                {ok, Alignments}
                        when length(HeaderCells) > 0,
                             length(HeaderCells) =:= length(Alignments) ->
                    {Rows, Tail} = take_table_rows(Rest, length(HeaderCells), []),
                    {HeadNodes, State1} = table_cells(<<"th">>, HeaderCells, Alignments, State),
                    {BodyRows, State2} = table_rows(Rows, Alignments, State1, []),
                    Attrs = table_attrs(Options),
                    Children0 = [
                        {<<"thead">>, [], [{<<"tr">>, [], HeadNodes}]}
                    ],
                    Children = case BodyRows of
                        [] -> Children0;
                        _ -> Children0 ++ [{<<"tbody">>, [], BodyRows}]
                    end,
                    {ok, [{<<"table">>, Attrs, Children}], Tail, State2};
                _ -> nomatch
            end
    end;
rule_table(_, _) ->
    nomatch.

-spec rule_hr(lines(), state()) -> result().
rule_hr([Line | Rest], State) ->
    case is_hr(Line) of
        true -> {ok, [{<<"hr">>, [], []}], Rest, State};
        false -> nomatch
    end;
rule_hr([], _) ->
    nomatch.

-spec rule_blockquote(lines(), state()) -> result().
rule_blockquote([Line | _] = Lines, State) ->
    case quote_line(Line) of
        {ok, _} ->
            {QuoteLines, Rest} = take_quote(Lines, []),
            Depth = maps:get(depth, State, 0),
            {Children, State1} = parse_lines(QuoteLines, State#{depth := Depth + 1}),
            {ok, [{<<"blockquote">>, [], Children}], Rest, State1#{depth := Depth}};
        nomatch -> nomatch
    end;
rule_blockquote([], _) ->
    nomatch.

-spec rule_list(lines(), state()) -> result().
rule_list([Line | _] = Lines, State) ->
    case list_marker(Line) of
        {ok, Marker} ->
            {Items0, Rest, Loose, State1} = take_list(Lines, Marker, State, [], false),
            Items = case Loose of
                true -> Items0;
                false -> [tighten_item(Item) || Item <- Items0]
            end,
            Tag = maps:get(tag, Marker),
            Attrs = list_attrs(Marker),
            {ok, [{Tag, Attrs, Items}], Rest, State1};
        nomatch -> nomatch
    end;
rule_list([], _) ->
    nomatch.

-spec rule_html(lines(), state()) -> result().
rule_html([Line | Rest], #{config := #{options := #{html := true}}} = State) ->
    case html_block_kind(Line) of
        blank ->
            {HtmlLines, Tail} = take_until_blank(Rest, [Line]),
            Html = join_lines(HtmlLines),
            {ok, [{'=', Html}], Tail, State};
        {until, EndMarker} ->
            {HtmlLines, Tail} = take_until_html_end([Line | Rest], EndMarker, []),
            Html = join_lines(HtmlLines),
            {ok, [{'=', Html}], Tail, State};
        false -> nomatch
    end;
rule_html(_, _) ->
    nomatch.

-spec rule_paragraph(lines(), state()) -> result().
rule_paragraph([Line | Rest], State) ->
    {ParagraphLines, Tail} = take_paragraph(
        Rest,
        State,
        [normalize_paragraph_first(Line)]),
    Content = string:trim(join_lines(ParagraphLines), trailing, " \t"),
    {Children, State1} = inline(Content, State),
    {ok, [{<<"p">>, [], Children}], Tail, State1};
rule_paragraph([], _) ->
    nomatch.

inline(Content, State) ->
    markdownz_inline:parse(Content, State).

normalize(Source) ->
    Source1 = binary:replace(Source, <<"\r\n">>, <<"\n">>, [global]),
    Source2 = binary:replace(Source1, <<"\r">>, <<"\n">>, [global]),
    binary:replace(Source2, <<0>>, <<16#ef, 16#bf, 16#bd>>, [global]).

extract_references([], References, Acc, _Fence, _Position) ->
    {lists:reverse(Acc), References};
extract_references([Line | Rest], References, Acc, {Char, Count} = Fence, _Position) ->
    NextFence = case is_fence_close(Line, Char, Count) of
        true -> none;
        false -> Fence
    end,
    extract_references(Rest, References, [Line | Acc], NextFence, boundary);
extract_references([Line | Rest] = Lines, References, Acc, none, Position) ->
    case fence_open(Line) of
        {ok, Char, Count, _Indent, _Info} ->
            extract_references(Rest, References, [Line | Acc], {Char, Count}, boundary);
        nomatch ->
            extract_reference_lines(Lines, References, Acc, Position)
    end.

extract_reference_lines([Line | Rest] = Lines, References, Acc, boundary) ->
    case is_blank_line(Line) of
        true ->
            extract_references(Rest, References, [Line | Acc], none, boundary);
        false ->
            case reference_definition(Lines) of
                {ok, Label, Destination, Title, Tail} ->
                    References1 = put_reference(Label, Destination, Title, References),
                    extract_references(Tail, References1, Acc, none, boundary);
                nomatch ->
                    extract_quote_reference(Line, Rest, References, Acc)
            end
    end;
extract_reference_lines([Line | Rest], References, Acc, paragraph) ->
    Position = case is_blank_line(Line) of true -> boundary; false -> paragraph end,
    extract_references(Rest, References, [Line | Acc], none, Position).

extract_quote_reference(Line, Rest, References, Acc) ->
    case quote_line(Line) of
        {ok, Content} ->
            case reference_definition([Content]) of
                {ok, Label, Destination, Title, []} ->
                    References1 = put_reference(Label, Destination, Title, References),
                    extract_references(Rest, References1, [<<">">> | Acc], none, boundary);
                nomatch ->
                    Position = reference_position_after(Line),
                    extract_references(Rest, References, [Line | Acc], none, Position)
            end;
        nomatch ->
            Position = reference_position_after(Line),
            extract_references(Rest, References, [Line | Acc], none, Position)
    end.

put_reference(Label, Destination0, Title0, References) ->
    Key = normalize_label(Label),
    case Key =:= <<>> orelse maps:is_key(Key, References) of
        true -> References;
        false ->
            Destination = markdownz_inline:normalize_destination(
                markdownz_inline:decode_entities(
                    unescape_punctuation(Destination0))),
            Title = case Title0 of
                undefined -> undefined;
                _ -> markdownz_inline:decode_entities(
                    unescape_punctuation(Title0))
            end,
            References#{Key => #{destination => Destination, title => Title}}
    end.

reference_definition(Lines) ->
    reference_definition(Lines, [], nomatch).

reference_definition([], _Taken, Best) ->
    Best;
reference_definition([Line | Rest], Taken, Best) ->
    case is_blank_line(Line) of
        true -> Best;
        false ->
            Taken1 = [Line | Taken],
            Candidate = join_lines(lists:reverse(Taken1)),
            Best1 = case match_reference_definition(Candidate) of
                {ok, Label, Destination, Title} ->
                    {ok, Label, Destination, Title, Rest};
                nomatch -> Best
            end,
            reference_definition(Rest, Taken1, Best1)
    end.

match_reference_definition(Candidate) ->
    Pattern = <<
        "^ {0,3}\\[((?:\\\\.|[^]]){1,999})\\]:[ \\t]*"
        "(?:\\n[ \\t]*)?(<[^<>\\n]*>|[^\\s<>]+)"
        "(?:(?:[ \\t]+(?:\\n[ \\t]*)?|\\n[ \\t]*)(?:"
        "\"((?:\\\\.|[^\"])*)\"|'((?:\\\\.|[^'])*)'|"
        "\\(((?:\\\\.|[^)])*)\\)))?[ \\t]*$"
    >>,
    case re:run(Candidate, Pattern, [{capture, [1, 2, 3, 4, 5], binary}]) of
        {match, [Label, Destination0, Double, Single, Paren]} ->
            case {normalize_label(Label), valid_reference_label(Label)} of
                {<<>>, _} -> nomatch;
                {_, false} -> nomatch;
                {_, true} ->
                    Destination = strip_reference_angle(Destination0),
                    Title = first_defined([Double, Single, Paren]),
                    {ok, Label, Destination, Title}
            end;
        nomatch -> nomatch
    end.

valid_reference_label(<<>>) -> true;
valid_reference_label(<<$\\, _Char/utf8, Rest/binary>>) ->
    valid_reference_label(Rest);
valid_reference_label(<<Char/utf8, _/binary>>)
        when Char =:= $[; Char =:= $] ->
    false;
valid_reference_label(<<_Char/utf8, Rest/binary>>) ->
    valid_reference_label(Rest).

strip_reference_angle(<<$<, Rest/binary>>) ->
    binary:part(Rest, 0, byte_size(Rest) - 1);
strip_reference_angle(Destination) ->
    Destination.

first_defined([<<>> | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value;
first_defined([]) -> undefined.

reference_position_after(Line) ->
    case is_atx(Line)
            orelse is_hr(Line)
            orelse quote_line(Line) =/= nomatch
            orelse list_marker(Line) =/= nomatch
            orelse html_block_start(Line) of
        true -> boundary;
        false -> paragraph
    end.

fence_open(Line) ->
    {Indent, Trimmed} = count_prefix(Line, $\s),
    case Indent =< 3 of
        true ->
            case Trimmed of
                <<Char, _/binary>> when Char =:= $`; Char =:= $~ ->
                    {Count, Rest} = count_prefix(Trimmed, Char),
                    ValidInfo = Char =/= $` orelse binary:match(Rest, <<"`">>) =:= nomatch,
                    case Count >= 3 andalso ValidInfo of
                        true -> {ok, Char, Count, Indent, trim(Rest)};
                        false -> nomatch
                    end;
                _ -> nomatch
            end;
        false -> nomatch
    end.

take_fence([], _Char, _Count, _Indent, Acc) ->
    {drop_eof_sentinel(lists:reverse(Acc)), []};
take_fence([Line | Rest], Char, Count, Indent, Acc) ->
    case is_fence_close(Line, Char, Count) of
        true -> {lists:reverse(Acc), Rest};
        false ->
            ContentLine = strip_up_to_indent(Line, Indent),
            take_fence(Rest, Char, Count, Indent, [ContentLine | Acc])
    end.

drop_eof_sentinel(Lines) ->
    case lists:reverse(Lines) of
        [<<>> | Rest] -> lists:reverse(Rest);
        _ -> Lines
    end.

strip_up_to_indent(Line, 0) -> Line;
strip_up_to_indent(<<$\s, Rest/binary>>, Count) when Count > 0 ->
    strip_up_to_indent(Rest, Count - 1);
strip_up_to_indent(Line, _Count) -> Line.

is_fence_close(Line, Char, Count) ->
    Trimmed = trim_indent(Line, 3),
    {CloseCount, Tail} = count_prefix(Trimmed, Char),
    CloseCount >= Count andalso trim(Tail) =:= <<>>.

take_indented([<<"    ", Line/binary>> | Rest], Acc) ->
    take_indented(Rest, [Line | Acc]);
take_indented([Line | Rest] = Lines, Acc) ->
    case is_blank_line(Line) of
        true -> take_indented(Rest, [<<>> | Acc]);
        false -> {drop_trailing_blank(lists:reverse(Acc)), Lines}
    end;
take_indented([], Acc) ->
    {drop_trailing_blank(lists:reverse(Acc)), []}.

setext_level(Line) ->
    {Indent, Rest} = count_prefix(Line, $\s),
    case Indent =< 3 of
        true ->
            Marker = trim(Rest),
            case Marker of
                <<$=, _/binary>> ->
                    case all_char(Marker, $=) of true -> 1; false -> false end;
                <<$-, _/binary>> ->
                    case all_char(Marker, $-) of true -> 2; false -> false end;
                _ -> false
            end;
        false -> false
    end.

heading_tag(1) -> <<"h1">>;
heading_tag(2) -> <<"h2">>;
heading_tag(3) -> <<"h3">>;
heading_tag(4) -> <<"h4">>;
heading_tag(5) -> <<"h5">>;
heading_tag(6) -> <<"h6">>.

trim_closing_hashes(Text) ->
    Trimmed = trim(Text),
    case Trimmed of
        <<$#, _/binary>> ->
            case all_char(Trimmed, $#) of
                true -> <<>>;
                false -> trim_hash_suffix(Trimmed)
            end;
        _ -> trim_hash_suffix(Trimmed)
    end.

trim_hash_suffix(Text) ->
    re:replace(Text, <<"[ \\t]+#+[ \\t]*$">>, <<>>, [{return, binary}]).

table_alignments(Cells) ->
    table_alignments(Cells, []).

table_alignments([], Acc) ->
    {ok, lists:reverse(Acc)};
table_alignments([Cell0 | Rest], Acc) ->
    Cell = trim(Cell0),
    case re:run(Cell, <<"^(:)?-{3,}(:)?$">>, [{capture, [1, 2], binary}]) of
        {match, [<<":">>, <<":">>]} -> table_alignments(Rest, [center | Acc]);
        {match, [<<":">>, <<>>]} -> table_alignments(Rest, [left | Acc]);
        {match, [<<>>, <<":">>]} -> table_alignments(Rest, [right | Acc]);
        {match, [<<>>, <<>>]} -> table_alignments(Rest, [none | Acc]);
        nomatch -> error
    end.

take_table_rows([], _ColumnCount, Acc) ->
    {lists:reverse(Acc), []};
take_table_rows([Line | Rest] = Lines, ColumnCount, Acc) ->
    case is_blank_line(Line) of
        true -> {lists:reverse(Acc), Lines};
        false ->
            case binary:match(Line, <<"|">>) of
                nomatch -> {lists:reverse(Acc), Lines};
                _ ->
                    Cells0 = split_table_row(Line),
                    Cells = fit_cells(Cells0, ColumnCount),
                    take_table_rows(Rest, ColumnCount, [Cells | Acc])
            end
    end.

table_rows([], _Alignments, State, Acc) ->
    {lists:reverse(Acc), State};
table_rows([Cells | Rest], Alignments, State, Acc) ->
    {CellNodes, State1} = table_cells(<<"td">>, Cells, Alignments, State),
    table_rows(Rest, Alignments, State1, [{<<"tr">>, [], CellNodes} | Acc]).

table_cells(Tag, Cells, Alignments, State) ->
    table_cells(Tag, Cells, Alignments, State, []).

table_cells(_Tag, [], [], State, Acc) ->
    {lists:reverse(Acc), State};
table_cells(Tag, [Cell | Cells], [Alignment | Alignments], State, Acc) ->
    {Children, State1} = inline(trim(Cell), State),
    Attrs = alignment_attr(Alignment),
    table_cells(Tag, Cells, Alignments, State1, [{Tag, Attrs, Children} | Acc]).

alignment_attr(none) -> [];
alignment_attr(Alignment) -> [{<<"align">>, atom_to_binary(Alignment)}].

table_attrs(Options) ->
    optional_attr(<<"role">>, maps:get(table_role, Options, undefined),
        optional_attr(<<"class">>, maps:get(table_class, Options, undefined), [])).

optional_attr(_Name, undefined, Attrs) -> Attrs;
optional_attr(_Name, <<>>, Attrs) -> Attrs;
optional_attr(Name, Value, Attrs) -> [{Name, Value} | Attrs].

split_table_row(Line) ->
    Trimmed = trim(Line),
    Cells0 = split_pipes(Trimmed, [], [], false),
    drop_edge_empty(Cells0).

split_pipes(<<>>, Current, Acc, _Escaped) ->
    lists:reverse([iolist_to_binary(lists:reverse(Current)) | Acc]);
split_pipes(<<$\\, $|, Rest/binary>>, Current, Acc, _Escaped) ->
    split_pipes(Rest, [<<"|">> | Current], Acc, false);
split_pipes(<<$|, Rest/binary>>, Current, Acc, false) ->
    Cell = iolist_to_binary(lists:reverse(Current)),
    split_pipes(Rest, [], [Cell | Acc], false);
split_pipes(<<Char/utf8, Rest/binary>>, Current, Acc, _Escaped) ->
    split_pipes(Rest, [<<Char/utf8>> | Current], Acc, false).

drop_edge_empty(Cells0) ->
    Cells1 = case Cells0 of [<<>> | Rest] -> Rest; _ -> Cells0 end,
    case lists:reverse(Cells1) of
        [<<>> | RestRev] -> lists:reverse(RestRev);
        _ -> Cells1
    end.

fit_cells(Cells, Count) when length(Cells) =:= Count -> Cells;
fit_cells(Cells, Count) when length(Cells) > Count -> lists:sublist(Cells, Count);
fit_cells(Cells, Count) -> Cells ++ lists:duplicate(Count - length(Cells), <<>>).

quote_line(Line) ->
    case re:run(Line, <<"^( {0,3})>(.*)$">>, [{capture, [1, 2], binary}]) of
        {match, [Indent, AfterMarker]} ->
            Expanded = expand_leading_whitespace(
                AfterMarker, byte_size(Indent) + 1),
            Content = case Expanded of
                <<$\s, Rest/binary>> -> Rest;
                _ -> Expanded
            end,
            {ok, Content};
        nomatch -> nomatch
    end.

take_quote([Line | Rest], Acc) ->
    case quote_line(Line) of
        {ok, Content} -> take_quote(Rest, [Content | Acc]);
        nomatch ->
            case can_lazy_quote(Line, Acc) of
                true -> take_quote(Rest, [escape_lazy_setext(Line) | Acc]);
                false -> {lists:reverse(Acc), [Line | Rest]}
            end
    end;
take_quote([], Acc) ->
    {lists:reverse(Acc), []}.

can_lazy_quote(_Line, []) -> false;
can_lazy_quote(Line, [Previous | _] = Acc) ->
    Previous =/= <<>>
        andalso not is_indented_line(Previous)
        andalso not quote_fence_open(Acc)
        andalso not is_blank_line(Line)
        andalso not is_atx(Line)
        andalso not is_hr(Line)
        andalso fence_open(Line) =:= nomatch
        andalso list_marker(Line) =:= nomatch
        andalso not html_block_start(Line).

is_indented_line(<<"    ", _/binary>>) -> true;
is_indented_line(_) -> false.

quote_fence_open(Lines) ->
    quote_fence_open(lists:reverse(Lines), none).

quote_fence_open([], Fence) -> Fence =/= none;
quote_fence_open([Line | Rest], none) ->
    case fence_open(Line) of
        {ok, Char, Count, _Indent, _Info} ->
            quote_fence_open(Rest, {Char, Count});
        nomatch -> quote_fence_open(Rest, none)
    end;
quote_fence_open([Line | Rest], {Char, Count} = Fence) ->
    case is_fence_close(Line, Char, Count) of
        true -> quote_fence_open(Rest, none);
        false -> quote_fence_open(Rest, Fence)
    end.

escape_lazy_setext(Line) ->
    case setext_level(Line) of
        Level when Level =:= 1; Level =:= 2 ->
            <<$\\, (trim(Line))/binary>>;
        false -> Line
    end.

list_marker(Line) ->
    case re:run(Line, <<"^( {0,3})([*+-])(.*)$">>,
                [{capture, [1, 2, 3], binary}]) of
        {match, [Indent, Bullet, AfterMarker]} ->
            make_list_marker(
                unordered, 1, Bullet, byte_size(Indent), 1, AfterMarker);
        nomatch ->
            case re:run(Line, <<"^( {0,3})([0-9]{1,9})([.)])(.*)$">>,
                        [{capture, [1, 2, 3, 4], binary}]) of
                {match, [Indent, Number, Delimiter, AfterMarker]} ->
                    make_list_marker(
                        ordered,
                        binary_to_integer(Number),
                        Delimiter,
                        byte_size(Indent),
                        byte_size(Number) + 1,
                        AfterMarker);
                nomatch -> nomatch
            end
    end.

make_list_marker(Type, Start, Style, Leading, MarkerWidth, AfterMarker) ->
    case list_padding(AfterMarker, Leading + MarkerWidth) of
        {ok, Padding, Content} ->
            Tag = case Type of unordered -> <<"ul">>; ordered -> <<"ol">> end,
            {ok, #{type => Type, tag => Tag, start => Start,
                   style => Style,
                   leading => Leading,
                   indent => Leading + MarkerWidth + Padding,
                   content => Content}};
        nomatch -> nomatch
    end.

list_padding(AfterMarker, Column) ->
    {Width, Rest} = whitespace_width(AfterMarker, Column, 0),
    case {Width, Rest} of
        {0, <<>>} -> {ok, 1, <<>>};
        {0, _} -> nomatch;
        {_, <<>>} -> {ok, 1, <<>>};
        {N, _} when N =< 4 -> {ok, N, Rest};
        {N, _} -> {ok, 1, <<(binary:copy(<<$\s>>, N - 1))/binary, Rest/binary>>}
    end.

whitespace_width(<<$\s, Rest/binary>>, Column, Width) ->
    whitespace_width(Rest, Column + 1, Width + 1);
whitespace_width(<<$\t, Rest/binary>>, Column, Width) ->
    Spaces = 4 - (Column rem 4),
    whitespace_width(Rest, Column + Spaces, Width + Spaces);
whitespace_width(Rest, _Column, Width) ->
    {Width, Rest}.

expand_leading_whitespace(Bin, Column) ->
    {Width, Rest} = whitespace_width(Bin, Column, 0),
    <<(binary:copy(<<$\s>>, Width))/binary, Rest/binary>>.

take_list([Line | Rest], FirstMarker, State, Acc, Loose0) ->
    case is_hr(Line) of
        true ->
            {lists:reverse(Acc), [Line | Rest], Loose0, State};
        false ->
            take_list_marker(Line, Rest, FirstMarker, State, Acc, Loose0)
    end;
take_list([], _FirstMarker, State, Acc, Loose) ->
    {lists:reverse(Acc), [], Loose, State}.

take_list_marker(Line, Rest, FirstMarker, State, Acc, Loose0) ->
    case list_marker(Line) of
        {ok, Marker} ->
            SameList = maps:get(type, Marker) =:= maps:get(type, FirstMarker)
                andalso maps:get(style, Marker) =:= maps:get(style, FirstMarker),
            case SameList of
                true ->
                    Indent = maps:get(indent, Marker),
                    Leading = maps:get(leading, Marker),
                    Content = maps:get(content, Marker),
                    {Continuation, Tail, LooseItem} =
                        take_list_item_lines(Content, Rest, Leading, Indent),
                    ItemLines = [maps:get(content, Marker) | Continuation],
                    {Children, State1} = parse_lines(drop_trailing_blank(ItemLines), State),
                    Item = {<<"li">>, [], Children},
                    take_list(Tail, FirstMarker, State1, [Item | Acc], Loose0 orelse LooseItem);
                false ->
                    {lists:reverse(Acc), [Line | Rest], Loose0, State}
            end;
        nomatch ->
            {lists:reverse(Acc), [Line | Rest], Loose0, State}
    end.

take_list_item_lines(<<>>, [Line | More] = Rest, Leading, Indent) ->
    case is_blank_line(Line) of
        true ->
            case next_nonblank(More) of
                {ok, Next} ->
                    case list_marker(Next) of
                        {ok, _} -> {[], drop_blank(Rest), true};
                        nomatch -> {[], Rest, false}
                    end;
                none -> {[], Rest, false}
            end;
        false -> take_item_lines(Rest, Leading, Indent, [], none)
    end;
take_list_item_lines(Content, Rest, Leading, Indent) ->
    Fence = case fence_open(Content) of
        {ok, Char, Count, _FenceIndent, _Info} -> {Char, Count};
        nomatch -> none
    end,
    take_item_lines(Rest, Leading, Indent, [], Fence).

take_item_lines([], _Leading, _Indent, Acc, _Fence) ->
    {lists:reverse(Acc), [], false};
take_item_lines([Line | Rest], Leading, Indent, Acc, {Char, Count} = Fence) ->
    Content = case strip_indent(Line, Indent) of
        {ok, Stripped} -> Stripped;
        nomatch -> Line
    end,
    NextFence = case is_fence_close(Content, Char, Count) of
        true -> none;
        false -> Fence
    end,
    take_item_lines(Rest, Leading, Indent, [Content | Acc], NextFence);
take_item_lines([Line | Rest] = Lines, Leading, Indent, Acc, none) ->
    case is_blank_line(Line) of
        true ->
            case blank_disposition(Rest, Leading, Indent) of
                next_item ->
                    {lists:reverse(Acc), drop_blank(Rest), true};
                {continuation, LeadingSpaces} ->
                    {More, Tail, NestedLoose} =
                        take_item_lines(Rest, Leading, Indent, [<<>> | Acc], none),
                    DirectLoose = Acc =:= [] orelse LeadingSpaces =:= Indent,
                    {More, Tail, DirectLoose orelse NestedLoose};
                stop ->
                    {lists:reverse(Acc), Lines, false}
            end;
        false -> take_nonblank_item_line(Lines, Leading, Indent, Acc)
    end.

take_nonblank_item_line([Line | Rest] = Lines, Leading, Indent, Acc) ->
    case list_marker(Line) of
        {ok, #{leading := Leading}} -> {lists:reverse(Acc), Lines, false};
        nomatch -> append_item_continuation(Line, Rest, Lines, Leading, Indent, Acc);
        {ok, _Nested} -> append_item_continuation(Line, Rest, Lines, Leading, Indent, Acc)
    end.

append_item_continuation(Line, Rest, Lines, Leading, Indent, Acc) ->
    case strip_indent(Line, Indent) of
        {ok, Content} ->
            Fence = case fence_open(Content) of
                {ok, Char, Count, _FenceIndent, _Info} -> {Char, Count};
                nomatch -> none
            end,
            take_item_lines(Rest, Leading, Indent, [Content | Acc], Fence);
        nomatch ->
            case can_lazy_list_continuation(Line) of
                true ->
                    Content0 = normalize_paragraph_continuation(Line),
                    Content = escape_lazy_block_marker(Content0),
                    take_item_lines(Rest, Leading, Indent, [Content | Acc], none);
                false -> {lists:reverse(Acc), Lines, false}
            end
    end.

escape_lazy_block_marker(Content) ->
    case list_marker(Content) of
        {ok, _} -> <<$\\, Content/binary>>;
        nomatch -> Content
    end.

can_lazy_list_continuation(Line) ->
    not is_atx(Line)
        andalso not is_hr(Line)
        andalso fence_open(Line) =:= nomatch
        andalso list_marker(Line) =:= nomatch
        andalso not html_block_start(Line).

blank_disposition([], _Leading, _Indent) -> stop;
blank_disposition([Line | Rest], Leading, Indent) ->
    case is_blank_line(Line) of
        true -> blank_disposition(Rest, Leading, Indent);
        false ->
            case {list_marker(Line), strip_indent(Line, Indent)} of
                {{ok, _}, _} -> next_item;
                {_, {ok, _}} ->
                    {LeadingSpaces, _} = count_prefix(Line, $\s),
                    {continuation, LeadingSpaces};
                _ -> stop
            end
    end.

next_nonblank([Line | Rest]) ->
    case is_blank_line(Line) of
        true -> next_nonblank(Rest);
        false -> {ok, Line}
    end;
next_nonblank([]) -> none.

strip_indent(Line, Count) when byte_size(Line) >= Count ->
    case Line of
        <<Spaces:Count/binary, Rest/binary>> ->
            case all_char(Spaces, $\s) of
                true -> {ok, Rest};
                false -> nomatch
            end
    end;
strip_indent(_Line, _Count) ->
    nomatch.

tighten_item({<<"li">>, Attrs, Children}) ->
    {<<"li">>, Attrs, lists:append([
        case Child of
            {<<"p">>, [], ParagraphChildren} -> ParagraphChildren;
            _ -> [Child]
        end
        || Child <- Children
    ])}.

list_attrs(#{type := ordered, start := Start}) when Start =/= 1 ->
    [{<<"start">>, Start}];
list_attrs(_) ->
    [].

take_until_blank([Line | Rest] = Lines, Acc) ->
    case is_blank_line(Line) of
        true -> {lists:reverse(Acc), Lines};
        false -> take_until_blank(Rest, [Line | Acc])
    end;
take_until_blank([], Acc) ->
    {lists:reverse(Acc), []}.

take_paragraph([Line | Rest] = Lines, State, Acc) ->
    case is_blank_line(Line) orelse interrupts_paragraph(Line, State) of
        true -> {lists:reverse(Acc), Lines};
        false -> take_paragraph(
            Rest,
            State,
            [normalize_paragraph_continuation(Line) | Acc])
    end;
take_paragraph([], _State, Acc) ->
    {lists:reverse(Acc), []}.

interrupts_paragraph(Line, State) ->
    fence_open(Line) =/= nomatch
        orelse list_interrupts_paragraph(Line)
        orelse quote_line(Line) =/= nomatch
        orelse is_atx(Line)
        orelse is_hr(Line)
        orelse html_interrupts_paragraph(Line, State).

list_interrupts_paragraph(Line) ->
    case list_marker(Line) of
        {ok, #{content := <<>>}} -> false;
        {ok, #{type := ordered, start := Start}} -> Start =:= 1;
        {ok, _} -> true;
        nomatch -> false
    end.

is_atx(Line) ->
    re:run(Line, <<"^ {0,3}#{1,6}(?:[ \\t]+|$)">>, [{capture, none}]) =:= match.

is_hr(Line) ->
    {Indent, Rest} = count_prefix(Line, $\s),
    case Indent =< 3 of
        true ->
            Compact = compact_whitespace(trim(Rest)),
            case Compact of
                <<Char, _/binary>> when Char =:= $*; Char =:= $-; Char =:= $_ ->
                    byte_size(Compact) >= 3 andalso all_char(Compact, Char);
                _ -> false
            end;
        false -> false
    end.

is_html_start(Line, #{config := #{options := #{html := true}}}) ->
    html_block_start(Line);
is_html_start(_Line, _State) -> false.

html_interrupts_paragraph(Line, #{config := #{options := #{html := true}}}) ->
    html_special_start(Line) orelse html_block_tag_start(Line);
html_interrupts_paragraph(_Line, _State) -> false.

html_block_start(Line) ->
    html_block_kind(Line) =/= false.

html_block_kind(Line) ->
    Lower = string:lowercase(trim_indent(Line, 3)),
    case html_until_marker(Lower) of
        false ->
            case is_complete_html_tag(Line) of
                true -> blank;
                false ->
                    case html_block_tag_start(Line) of
                        true -> blank;
                        false -> false
                    end
            end;
        EndMarker -> {until, EndMarker}
    end.

html_until_marker(<<"<script", _/binary>>) -> <<"</script>">>;
html_until_marker(<<"<pre", _/binary>>) -> <<"</pre>">>;
html_until_marker(<<"<style", _/binary>>) -> <<"</style>">>;
html_until_marker(<<"<textarea", _/binary>>) -> <<"</textarea>">>;
html_until_marker(<<"<!--", _/binary>>) -> <<"-->">>;
html_until_marker(<<"<?", _/binary>>) -> <<"?>">>;
html_until_marker(<<"<![cdata[", _/binary>>) -> <<"]]>">>;
html_until_marker(<<"<!", Next, _/binary>>) when Next >= $a, Next =< $z -> <<">">>;
html_until_marker(_) -> false.

take_until_html_end([], _EndMarker, Acc) ->
    {drop_eof_sentinel(lists:reverse(Acc)), []};
take_until_html_end([Line | Rest], EndMarker, Acc) ->
    Acc1 = [Line | Acc],
    Lower = string:lowercase(Line),
    case binary:match(Lower, EndMarker) of
        nomatch -> take_until_html_end(Rest, EndMarker, Acc1);
        _ -> {lists:reverse(Acc1), Rest}
    end.

html_special_start(Line) ->
    re:run(Line, <<"^ {0,3}(?:<!--|<\\?|<![A-Z]|<!\\[CDATA\\[)">>,
        [{capture, none}]) =:= match.

html_block_tag_start(Line) ->
            case re:run(Line, <<"^ {0,3}</?([A-Za-z][A-Za-z0-9-]*)(?:[ \\t>/]|$)">>,
                        [{capture, [1], binary}]) of
                {match, [Tag]} -> is_block_tag(string:lowercase(Tag));
                nomatch -> false
            end.

is_complete_html_tag(Line) ->
    Pattern = <<
        "^ {0,3}(?:"
        "</[A-Za-z][A-Za-z0-9-]*\\s*>"
        "|<[A-Za-z][A-Za-z0-9-]*"
        "(?:\\s+[A-Za-z_:][A-Za-z0-9_.:-]*"
        "(?:\\s*=\\s*(?:[^\\s\"'=<>\x60]+|'[^']*'|\"[^\"]*\"))?)*"
        "\\s*/?>"
        ")[ \\t]*$"
    >>,
    re:run(Line, Pattern, [unicode, {capture, none}]) =:= match.

is_block_tag(Tag) ->
    lists:member(Tag, [
        <<"address">>, <<"article">>, <<"aside">>, <<"base">>, <<"basefont">>,
        <<"blockquote">>, <<"body">>, <<"caption">>, <<"center">>, <<"col">>,
        <<"colgroup">>, <<"dd">>, <<"details">>, <<"dialog">>, <<"dir">>,
        <<"div">>, <<"dl">>, <<"dt">>, <<"fieldset">>, <<"figcaption">>,
        <<"figure">>, <<"footer">>, <<"form">>, <<"frame">>, <<"frameset">>,
        <<"h1">>, <<"h2">>, <<"h3">>, <<"h4">>, <<"h5">>, <<"h6">>,
        <<"head">>, <<"header">>, <<"hr">>, <<"html">>, <<"iframe">>,
        <<"legend">>, <<"li">>, <<"link">>, <<"main">>, <<"menu">>,
        <<"menuitem">>, <<"nav">>, <<"noframes">>, <<"ol">>, <<"optgroup">>,
        <<"option">>, <<"p">>, <<"param">>, <<"search">>, <<"section">>,
        <<"summary">>, <<"table">>, <<"tbody">>, <<"td">>, <<"tfoot">>,
        <<"th">>, <<"thead">>, <<"title">>, <<"tr">>, <<"track">>, <<"ul">>
    ]).

code_attrs(<<>>, _Options) -> {[], []};
code_attrs(Language, #{code_style := commonmark}) ->
    {[], [{<<"class">>, <<"language-", Language/binary>>}]};
code_attrs(Language, _Options) ->
    {
        [{<<"lang">>, Language}, {<<"class">>, <<"notranslate">>}],
        [{<<"class">>, <<"notranslate language-", Language/binary>>}]
    }.

code_content([]) -> <<>>;
code_content(Lines) -> <<(join_lines(Lines))/binary, "\n">>.

first_word(<<>>) -> <<>>;
first_word(Info) -> hd(binary:split(Info, [<<" ">>, <<"\t">>], [global, trim_all])).

join_lines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

drop_blank([Line | Rest] = Lines) ->
    case is_blank_line(Line) of
        true -> drop_blank(Rest);
        false -> Lines
    end;
drop_blank([]) -> [].

drop_trailing_blank(Lines) ->
    lists:reverse(drop_blank(lists:reverse(Lines))).

trim_indent(Bin, Maximum) -> trim_indent(Bin, Maximum, 0).
trim_indent(<<$\s, Rest/binary>>, Maximum, Count) when Count < Maximum ->
    trim_indent(Rest, Maximum, Count + 1);
trim_indent(Rest, _Maximum, _Count) -> Rest.

count_prefix(Bin, Char) -> count_prefix(Bin, Char, 0).
count_prefix(<<Char, Rest/binary>>, Char, Count) -> count_prefix(Rest, Char, Count + 1);
count_prefix(Rest, _Char, Count) -> {Count, Rest}.

all_char(<<>>, _Char) -> true;
all_char(<<Char, Rest/binary>>, Char) -> all_char(Rest, Char);
all_char(_, _) -> false.

normalize_label(Label) ->
    Collapsed = re:replace(trim(Label), <<"\\s+">>, <<" ">>,
        [global, {return, binary}, unicode]),
    string:casefold(Collapsed).

trim(Bin) -> string:trim(Bin, both, " \t\r\n").

normalize_line(Line) ->
    expand_indent(Line).

is_blank_line(Line) ->
    trim(Line) =:= <<>>.

normalize_paragraph_first(Line) ->
    trim_indent(Line, 3).

normalize_paragraph_continuation(Line) ->
    string:trim(Line, leading, " ").

compact_whitespace(Bin) ->
    NoSpaces = binary:replace(Bin, <<" ">>, <<>>, [global]),
    binary:replace(NoSpaces, <<"\t">>, <<>>, [global]).

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

is_escapable(Char) ->
    binary:match(<<"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~">>, <<Char>>) =/= nomatch.

expand_indent(Bin) ->
    expand_indent(Bin, 0, []).

expand_indent(<<$\s, Rest/binary>>, Column, Acc) ->
    expand_indent(Rest, Column + 1, [<<$\s>> | Acc]);
expand_indent(<<$\t, Rest/binary>>, Column, Acc) ->
    Spaces = 4 - (Column rem 4),
    expand_indent(Rest, Column + Spaces, [binary:copy(<<$\s>>, Spaces) | Acc]);
expand_indent(Rest, _Column, Acc) ->
    iolist_to_binary(lists:reverse(Acc, [Rest])).
